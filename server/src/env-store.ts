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
}
