// Mirrors `greentic-updates-server`'s `AppError` wire shape exactly:
//   { "error": "<kind>: <message>", "code": "<snake_kind>" }
// The deployer and the runtime both surface `error` verbatim, so the prefixes
// ("not found: ", "conflict: ") are part of the contract, not decoration.

export type ErrKind =
  "bad_request" | "not_found" | "conflict" | "unauthorized" | "internal";

const STATUS: Record<ErrKind, number> = {
  bad_request: 400,
  not_found: 404,
  conflict: 409,
  unauthorized: 401,
  internal: 500,
};

const PREFIX: Record<ErrKind, string> = {
  bad_request: "bad request",
  not_found: "not found",
  conflict: "conflict",
  unauthorized: "unauthorized",
  internal: "internal",
};

export class AppError extends Error {
  constructor(
    readonly kind: ErrKind,
    message: string,
  ) {
    super(`${PREFIX[kind]}: ${message}`);
  }

  toResponse(): Response {
    return json({ error: this.message, code: this.kind }, STATUS[this.kind]);
  }
}

export const badRequest = (m: string) => new AppError("bad_request", m);
export const notFound = (m: string) => new AppError("not_found", m);
export const conflict = (m: string) => new AppError("conflict", m);
export const unauthorized = (m: string) => new AppError("unauthorized", m);

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export function octets(bytes: Uint8Array): Response {
  // Hand the Response a standalone ArrayBuffer rather than the view: the plan
  // and the DSSE envelope are served as opaque bytes and must not be re-encoded.
  const buf = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(buf).set(bytes);
  return new Response(buf, {
    headers: { "content-type": "application/octet-stream" },
  });
}
