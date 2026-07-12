import { AppError, json, notFound } from "./errors";
import { randomHex, validateIdentity } from "./util";
import { EnvPlanStore } from "./env-store";
import { RateLimiter } from "./rate-limiter";

export { EnvPlanStore, RateLimiter };

export interface Env {
  ENVS: DurableObjectNamespace<EnvPlanStore>;
  LIMITER: DurableObjectNamespace<RateLimiter>;
  /** Optional server-wide upload credential, for self-hosted (non-demo) use. */
  PLAN_UPLOAD_TOKEN?: string;
}

/** New demo namespaces per IP per hour. Bounds abuse of the public instance. */
const SESSIONS_PER_HOUR = 20;

/**
 * The Greentic plan store, as a Cloudflare Worker.
 *
 * A port of `greentic-updates-server`'s plan-store routes. It holds signed bytes
 * and answers GETs; it never holds a signing key and cannot mint or alter a plan.
 * Reads are anonymous by design — the trust anchor is the DSSE signature the
 * runtime verifies against its own trust root, not the transport.
 *
 * Three deliberate divergences from the Rust original, all because this instance
 * is public and shared rather than single-tenant:
 *   - no `GET /v1/environments` (listing every environment leaks other people's ids)
 *   - the audit log is per-environment (`/v1/environments/{id}/audit`), not global
 *   - no Cert-CA routes (`/v1/ca`, `/v1/enroll`, `/v1/revoke`, `/v1/crl`); plan
 *     reads are anonymous, so the demo never enrolls
 */
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      return await route(request, env);
    } catch (e) {
      if (e instanceof AppError) return e.toResponse();
      console.error("unhandled", e);
      return json({ error: "internal server error", code: "internal" }, 500);
    }
  },
} satisfies ExportedHandler<Env>;

async function route(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const path = url.pathname;

  if (path === "/healthz") return new Response("ok");

  if (path === "/v1/demo/session" && request.method === "POST") {
    return createDemoSession(request, env);
  }

  // /v1/environments/{id}[/plan | /plan.sig | /plan/meta | /audit]
  const m = /^\/v1\/environments\/([^/]+)(\/.*)?$/.exec(path);
  if (m) {
    const id = validateIdentity(decodeURIComponent(m[1]), "id");
    const rest = m[2] ?? "";
    const stub = env.ENVS.get(env.ENVS.idFromName(id));

    const doUrl = (op: string) =>
      `https://do/?id=${encodeURIComponent(id)}&op=${op}`;

    // Reads: forward the credential header, never the body. Passing the inbound
    // Request through would hand the DO a stream the error paths never drain,
    // which workerd reports as "read from request stream after response sent".
    const get = (op: string) => stub.fetch(doUrl(op), { method: "GET" });

    if (rest === "/plan" && request.method === "POST") {
      const body = await readBoundedBody(request);
      return stub.fetch(doUrl("upload"), {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-api-key": request.headers.get("x-api-key") ?? "",
        },
        body,
      });
    }
    if (rest === "/plan" && request.method === "GET") return get("plan");
    if (rest === "/plan.sig" && request.method === "GET")
      return get("plan.sig");
    if (rest === "/plan/meta" && request.method === "GET") return get("meta");
    if (rest === "/audit" && request.method === "GET") return get("audit");
    if (rest === "" && request.method === "GET") return get("env");
  }

  throw notFound(`no route for ${request.method} ${path}`);
}

/**
 * A plan is ~1-2 KB and the store caps the decoded plan and envelope at 64 KB
 * each; base64 of both plus the JSON scaffolding fits well inside 512 KB. Refuse
 * anything larger before buffering it, so an upload cannot be used to make the
 * Worker allocate arbitrary memory.
 */
const MAX_UPLOAD_BODY_BYTES = 512 * 1024;

async function readBoundedBody(request: Request): Promise<string> {
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (declared > MAX_UPLOAD_BODY_BYTES) {
    throw new AppError(
      "bad_request",
      `upload body exceeds ${MAX_UPLOAD_BODY_BYTES} bytes`,
    );
  }
  const body = await request.text();
  if (body.length > MAX_UPLOAD_BODY_BYTES) {
    throw new AppError(
      "bad_request",
      `upload body exceeds ${MAX_UPLOAD_BODY_BYTES} bytes`,
    );
  }
  return body;
}

/**
 * Mint an ephemeral environment id and its own upload credential.
 *
 * This is what lets anyone run the demo against the shared public instance with
 * no Cloudflare account and no secret checked into the repo: each run gets an
 * unguessable namespace and a token scoped to it. A publisher who guesses
 * someone else's id still cannot move their runtime — the plan would have to be
 * signed by a key that runtime's trust root already carries.
 */
async function createDemoSession(
  request: Request,
  env: Env,
): Promise<Response> {
  const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
  const limiter = env.LIMITER.get(env.LIMITER.idFromName(ip));
  const allowed = await limiter.take(SESSIONS_PER_HOUR);
  if (!allowed) {
    throw new AppError(
      "conflict",
      `rate limit: more than ${SESSIONS_PER_HOUR} demo sessions in an hour`,
    );
  }

  const id = `demo-${randomHex(8)}`;
  const stub = env.ENVS.get(env.ENVS.idFromName(id));
  const { upload_token } = await stub.createDemoSession();

  const origin = new URL(request.url).origin;
  return json(
    {
      env_id: id,
      upload_token,
      plan_endpoint: `${origin}/v1/environments/${id}/plan`,
      expires_in_secs: 24 * 60 * 60,
    },
    201,
  );
}
