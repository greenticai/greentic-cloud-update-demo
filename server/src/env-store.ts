import { DurableObject } from "cloudflare:workers";
import {
  AppError,
  conflict,
  json,
  notFound,
  octets,
  unauthorized,
} from "./errors";
import {
  constantTimeEqual,
  decodeBase64,
  encodeBase64,
  nowRfc3339,
  sha256Hex,
} from "./util";
import type { Env } from "./index";

/** 64 KB. A signed env-manifest plan is ~1-2 KB; the runtime's own ceiling is 16 MB. */
const MAX_PLAN_BYTES = 64 * 1024;
/** 64 KB — matches the runtime's `MAX_PLAN_SIG_BYTES`. */
const MAX_SIG_BYTES = 64 * 1024;
/** Demo environments evaporate a day after they are created. */
const DEMO_TTL_MS = 24 * 60 * 60 * 1000;
/** Keep the audit log bounded; a demo run writes ~4 entries. */
const MAX_AUDIT_ENTRIES = 50;
/** Schema id every pushed plan-notification carries; receivers ignore others. */
const UPDATE_EVENT_SCHEMA_V1 = "greentic.update-event.v1";
/**
 * `: keepalive` comment cadence on an idle stream. The client recycles a stream
 * connection at 900s and asserts — at compile time — that its recycle interval
 * stays far above this, so 20s keeps a NAT or proxy from idling the socket
 * without ever cutting a frame. See greentic-update `stream.rs`.
 */
const KEEPALIVE_MS = 20_000;

/** One shared encoder for every SSE frame written by this object. */
const ENC = new TextEncoder();

interface EnvironmentRecord {
  id: string;
  tenant: string;
  env: string;
  metadata?: unknown;
  registered_at: string;
}

interface StoredPlan {
  plan_b64: string;
  envelope_b64: string;
  sequence: number;
  plan_sha256: string;
  uploaded_at: string;
}

interface AuditEntry {
  seq: number;
  at: string;
  action: string;
  subject: string;
  detail?: unknown;
}

interface PlanUploadRequest {
  plan_bytes_b64: string;
  envelope_bytes_b64: string;
  sequence: number;
  plan_sha256: string;
  tenant?: string;
  env?: string;
}

/** One open `/updates/stream` subscriber. */
interface StreamConn {
  writer: WritableStreamDefaultWriter<Uint8Array>;
  closed: boolean;
  /** Aborts the current keepalive sleep the instant the connection is dropped. */
  abort: AbortController;
}

/**
 * One Durable Object per environment id.
 *
 * The plan store's headline guarantee is a strictly monotonic sequence: two
 * operators publishing concurrently must not silently fork the channel — the
 * loser gets a 409. That is a read-modify-write, so it is only a guarantee if
 * the writes are serialized. A Durable Object gives exactly that; KV would make
 * the check racy and the guarantee a lie.
 */
export class EnvPlanStore extends DurableObject<Env> {
  /**
   * Live SSE subscribers, one entry per open `/updates/stream` connection.
   *
   * In-memory, not persisted, and that is correct: an open stream keeps this
   * Durable Object pinned in memory, so the set survives between a subscriber's
   * connect and the `uploadPlan` that broadcasts to it. If the object is ever
   * evicted (only possible with no open streams) there is nothing to broadcast
   * to anyway, and the client reconnects and catches up from `latest_plan`.
   */
  private readonly connections = new Set<StreamConn>();

  /** Create the demo namespace and mint its upload credential. Idempotent. */
  async createDemoSession(): Promise<{ upload_token: string }> {
    const existing = await this.ctx.storage.get<string>("upload_token");
    if (existing) return { upload_token: existing };

    const token = crypto.randomUUID().replace(/-/g, "");
    await this.ctx.storage.put("upload_token", token);
    await this.ctx.storage.setAlarm(Date.now() + DEMO_TTL_MS);
    return { upload_token: token };
  }

  /** TTL expiry: the whole environment — plan, credential, audit — is dropped. */
  async alarm(): Promise<void> {
    await this.ctx.storage.deleteAll();
  }

  async fetch(request: Request): Promise<Response> {
    try {
      return await this.route(request);
    } catch (e) {
      if (e instanceof AppError) return e.toResponse();
      throw e;
    }
  }

  private async route(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const id = url.searchParams.get("id")!;
    const op = url.searchParams.get("op")!;

    switch (op) {
      case "upload":
        return this.uploadPlan(request, id);
      case "plan":
        return this.getPlanBytes(id, (p) => p.plan_b64, "plan");
      case "plan.sig":
        return this.getPlanBytes(id, (p) => p.envelope_b64, "plan signature");
      case "meta":
        return this.getMeta(id);
      case "stream":
        return this.streamPlan(request, id);
      case "env":
        return json(await this.requireEnvironment(id));
      case "audit":
        return json((await this.ctx.storage.get<AuditEntry[]>("audit")) ?? []);
      default:
        throw notFound(`unknown operation: ${op}`);
    }
  }

  // -- reads ---------------------------------------------------------------

  private async requireEnvironment(id: string): Promise<EnvironmentRecord> {
    const rec = await this.ctx.storage.get<EnvironmentRecord>("environment");
    if (!rec) throw notFound(`environment not found: ${id}`);
    return rec;
  }

  private async getPlanBytes(
    id: string,
    pick: (p: StoredPlan) => string,
    what: string,
  ): Promise<Response> {
    await this.requireEnvironment(id);
    const plan = await this.ctx.storage.get<StoredPlan>("latest_plan");
    if (!plan) throw notFound(`no ${what} for environment: ${id}`);
    return octets(decodeBase64(pick(plan), what));
  }

  private async getMeta(id: string): Promise<Response> {
    await this.requireEnvironment(id);
    const plan = await this.ctx.storage.get<StoredPlan>("latest_plan");
    if (!plan) throw notFound(`no plan metadata for environment: ${id}`);
    return json({
      sequence: plan.sequence,
      plan_sha256: plan.plan_sha256,
      uploaded_at: plan.uploaded_at,
    });
  }

  // -- write ---------------------------------------------------------------

  private async uploadPlan(request: Request, id: string): Promise<Response> {
    // 1. Credential gate, first — before anything is parsed or stored.
    await this.checkUploadCredential(request);

    const body = (await request.json()) as PlanUploadRequest;

    // 2. Decode and size-check before the environment is auto-created, so a bad
    //    payload never leaves an orphaned record behind.
    const planBytes = decodeBase64(body.plan_bytes_b64, "plan_bytes_b64");
    const envelopeBytes = decodeBase64(
      body.envelope_bytes_b64,
      "envelope_bytes_b64",
    );
    if (planBytes.byteLength > MAX_PLAN_BYTES) {
      throw new AppError("bad_request", `plan exceeds ${MAX_PLAN_BYTES} bytes`);
    }
    if (envelopeBytes.byteLength > MAX_SIG_BYTES) {
      throw new AppError(
        "bad_request",
        `envelope exceeds ${MAX_SIG_BYTES} bytes`,
      );
    }

    // 3. Integrity: the digest the publisher claims must be the digest we hold.
    const computed = await sha256Hex(planBytes);
    if (computed !== body.plan_sha256) {
      throw new AppError(
        "bad_request",
        `sha256 mismatch: computed ${computed}, provided ${body.plan_sha256}`,
      );
    }

    // 4. Auto-create the environment on first upload, behind the credential.
    const created =
      !(await this.ctx.storage.get<EnvironmentRecord>("environment"));
    if (created) {
      const tenant = body.tenant ?? "default";
      const env = body.env ?? id;
      await this.ctx.storage.put<EnvironmentRecord>("environment", {
        id,
        tenant,
        env,
        registered_at: nowRfc3339(),
      });
      await this.appendAudit("environment_auto_registered", id, {
        tenant,
        env,
        via: "plan_upload",
      });
    }

    // 5. Monotonic sequence. Serialized by the Durable Object, so the
    //    read-modify-write below cannot interleave with a concurrent publisher.
    const current = await this.ctx.storage.get<StoredPlan>("latest_plan");
    const planB64 = encodeBase64(planBytes);
    const envelopeB64 = encodeBase64(envelopeBytes);
    if (current) {
      if (body.sequence === current.sequence) {
        // Idempotent replay (a retry after a lost response) is a success no-op.
        // Different content at a published sequence is a real fork.
        const same =
          current.plan_sha256 === body.plan_sha256 &&
          current.envelope_b64 === envelopeB64;
        if (!same) {
          throw conflict(
            `plan sequence ${body.sequence} already published with different content`,
          );
        }
        return json({ status: "stored", sequence: body.sequence }, 201);
      }
      if (body.sequence < current.sequence) {
        throw conflict(
          `non-monotonic plan sequence ${body.sequence} < current ${current.sequence}`,
        );
      }
    }

    await this.ctx.storage.put<StoredPlan>("latest_plan", {
      plan_b64: planB64,
      envelope_b64: envelopeB64,
      sequence: body.sequence,
      plan_sha256: body.plan_sha256,
      uploaded_at: nowRfc3339(),
    });
    await this.appendAudit("plan_upload", id, {
      sequence: body.sequence,
      sha256: body.plan_sha256,
    });

    // Push the new head to every open stream. A hint only — it carries the
    // sequence and digest `/meta` already exposes, never plan bytes, so a
    // spoofed or replayed event costs a subscriber one wasted verified fetch,
    // never a bad apply. Sent AFTER the durable store above, so the fetch it
    // triggers can never observe a torn read. The idempotent-replay path
    // returned earlier and never reaches here — an unchanged head is not news.
    await this.broadcast(id, body.sequence, body.plan_sha256);

    return json({ status: "stored", sequence: body.sequence }, 201);
  }

  /**
   * Deny-by-default. Two credentials are accepted:
   *   - the per-environment token minted by `POST /v1/demo/session` (public demo)
   *   - the server-wide `PLAN_UPLOAD_TOKEN` secret (self-hosted, matches the
   *     Rust server's behaviour)
   * With neither configured, uploads are disabled outright.
   */
  private async checkUploadCredential(request: Request): Promise<void> {
    const provided = request.headers.get("x-api-key") ?? "";
    const envToken = await this.ctx.storage.get<string>("upload_token");
    const serverToken = (this.env.PLAN_UPLOAD_TOKEN ?? "").trim();

    const candidates = [envToken, serverToken].filter(
      (t): t is string => !!t && t.length > 0,
    );
    if (candidates.length === 0) {
      throw unauthorized(
        "plan upload is disabled: no upload credential configured",
      );
    }
    if (
      provided.length === 0 ||
      !candidates.some((c) => constantTimeEqual(provided, c))
    ) {
      throw unauthorized("invalid or missing X-Api-Key");
    }
  }

  private async appendAudit(
    action: string,
    subject: string,
    detail?: unknown,
  ): Promise<void> {
    const log = (await this.ctx.storage.get<AuditEntry[]>("audit")) ?? [];
    log.push({
      seq: log.length + 1,
      at: nowRfc3339(),
      action,
      subject,
      detail,
    });
    await this.ctx.storage.put("audit", log.slice(-MAX_AUDIT_ENTRIES));
  }

  // -- push (SSE) ----------------------------------------------------------

  /**
   * Open a Server-Sent Events stream of plan notifications for this environment.
   *
   * The runtime connects here (deriving the URL from its `plan_endpoint` by
   * swapping the trailing `/plan` for `/updates/stream`) and reacts to each
   * `plan` event by running its normal verified fetch. The event is a HINT: it
   * carries the sequence and digest the poll `/meta` already exposes, never plan
   * bytes.
   *
   * The environment need not exist yet — the demo subscribes at boot, before the
   * first plan is published — so an empty environment simply streams keepalives
   * until a plan arrives. This mirrors the poll path, which 404s `/plan` for an
   * empty environment but never refuses to be polled.
   */
  private streamPlan(request: Request, id: string): Response {
    const lastEventId = parseLastEventId(request.headers.get("Last-Event-ID"));

    const { readable, writable } = new TransformStream<
      Uint8Array,
      Uint8Array
    >();
    const conn: StreamConn = {
      writer: writable.getWriter(),
      closed: false,
      abort: new AbortController(),
    };

    // Subscribe BEFORE the catch-up read, never after: a plan published in the
    // window between reading `latest_plan` and joining `connections` would
    // otherwise reach neither, and the subscriber would idle until the next
    // unrelated publish. Registering first hands that plan to the broadcast; the
    // worst case is the subscriber seeing it twice, which is harmless — the
    // event is a hint and the fetch it triggers is idempotent.
    this.connections.add(conn);
    void this.runConnection(conn, id, lastEventId);

    return new Response(readable, {
      status: 200,
      headers: {
        "content-type": "text/event-stream",
        // A proxy that buffers or transforms an SSE body defeats the whole point.
        "cache-control": "no-cache, no-transform",
      },
    });
  }

  /**
   * Catch a subscriber up to the current head, then keep the connection warm.
   *
   * Catch-up hands a fresh subscriber (no `Last-Event-ID`) the current head so
   * it converges without waiting for the next publish, and a resuming one the
   * head only if it is newer than what it last saw. The event is a hint, so the
   * newest plan is all that matters: a subscriber that missed sequences 2..4
   * still converges to 5 in a single fetch — which is why there is no
   * per-sequence history to replay here, only `latest_plan`.
   */
  private async runConnection(
    conn: StreamConn,
    id: string,
    lastEventId: number | undefined,
  ): Promise<void> {
    const head = await this.ctx.storage.get<StoredPlan>("latest_plan");
    if (head && (lastEventId === undefined || head.sequence > lastEventId)) {
      await this.send(conn, id, head.sequence, head.plan_sha256);
    }
    while (!conn.closed) {
      // Wake early if the client vanishes: `writer.closed` rejects the moment
      // the readable half is cancelled, so a dropped subscriber is reaped in
      // milliseconds instead of parking a timer for the full keepalive window.
      await Promise.race([
        sleep(KEEPALIVE_MS, conn.abort.signal),
        conn.writer.closed.catch(() => {}),
      ]);
      if (conn.closed) break;
      if (!(await this.write(conn, ": keepalive\n\n"))) break;
    }
  }

  /** Broadcast a new head to every open stream. */
  private async broadcast(
    id: string,
    sequence: number,
    planSha256: string,
  ): Promise<void> {
    // Snapshot the set: `send` drops dead connections, which mutates it.
    for (const conn of [...this.connections]) {
      await this.send(conn, id, sequence, planSha256);
    }
  }

  /** Write one `plan` event; `id:` carries the sequence for `Last-Event-ID`. */
  private async send(
    conn: StreamConn,
    id: string,
    sequence: number,
    planSha256: string,
  ): Promise<void> {
    const data = JSON.stringify({
      schema: UPDATE_EVENT_SCHEMA_V1,
      env_id: id,
      sequence,
      plan_sha256: planSha256,
    });
    await this.write(conn, `id: ${sequence}\nevent: plan\ndata: ${data}\n\n`);
  }

  /** Write raw SSE text; on failure the client is gone, so drop the connection. */
  private async write(conn: StreamConn, text: string): Promise<boolean> {
    if (conn.closed) return false;
    try {
      await conn.writer.write(ENC.encode(text));
      return true;
    } catch {
      this.dropConnection(conn);
      return false;
    }
  }

  private dropConnection(conn: StreamConn): void {
    if (conn.closed) return;
    conn.closed = true;
    this.connections.delete(conn);
    conn.abort.abort();
    void conn.writer.close().catch(() => {});
  }
}

/** Parse a `Last-Event-ID` header into a resume sequence, ignoring garbage. */
function parseLastEventId(raw: string | null): number | undefined {
  if (!raw) return undefined;
  const n = Number(raw);
  return Number.isSafeInteger(n) && n >= 0 ? n : undefined;
}

/** A cancellable sleep: resolves after `ms`, or the moment `signal` aborts. */
function sleep(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    if (signal.aborted) return resolve();
    const timer = setTimeout(resolve, ms);
    signal.addEventListener(
      "abort",
      () => {
        clearTimeout(timer);
        resolve();
      },
      { once: true },
    );
  });
}
