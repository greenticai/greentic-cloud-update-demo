import { badRequest } from "./errors";

/** Port of `routes::validate_identity` — non-empty, <=128 chars, `[a-zA-Z0-9._-]`. */
export function validateIdentity(value: string, field: string): string {
  if (value.length === 0) throw badRequest(`${field} must not be empty`);
  if (value.length > 128) throw badRequest(`${field} exceeds 128 characters`);
  if (!/^[A-Za-z0-9._-]+$/.test(value)) {
    throw badRequest(
      `${field} contains invalid characters (allowed: a-zA-Z0-9._-)`,
    );
  }
  return value;
}

export function nowRfc3339(): string {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

export function decodeBase64(b64: string, field: string): Uint8Array {
  let binary: string;
  try {
    binary = atob(b64);
  } catch (e) {
    throw badRequest(`${field} decode error: ${e}`);
  }
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

export function encodeBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary);
}

export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes as BufferSource);
  return [...new Uint8Array(digest)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

export function randomHex(bytes: number): string {
  const buf = new Uint8Array(bytes);
  crypto.getRandomValues(buf);
  return [...buf].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * Length-independent equality. The Rust server compares upload credentials with
 * `!=` and calls a constant-time compare a follow-up; on an internet-facing
 * server that follow-up is not optional, so we do it here.
 */
export function constantTimeEqual(a: string, b: string): boolean {
  const ab = new TextEncoder().encode(a);
  const bb = new TextEncoder().encode(b);
  // Compare a fixed-width digest so the loop count never depends on the secret.
  let diff = ab.length ^ bb.length;
  const n = Math.max(ab.length, bb.length);
  for (let i = 0; i < n; i++) diff |= (ab[i] ?? 0) ^ (bb[i] ?? 0);
  return diff === 0;
}
