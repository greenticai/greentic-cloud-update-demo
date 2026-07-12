import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

/**
 * The plan store's contract, exercised against real workerd + real Durable
 * Object storage. The monotonic-sequence rules are the reason this server
 * exists, so they are tested as behaviour, not as implementation detail.
 */

const BASE = "https://plan.test";

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", bytes as BufferSource);
  return [...new Uint8Array(d)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function b64(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

const bytes = (s: string) => new TextEncoder().encode(s);

async function newSession(): Promise<{ env_id: string; upload_token: string }> {
  const res = await SELF.fetch(`${BASE}/v1/demo/session`, { method: "POST" });
  expect(res.status).toBe(201);
  return res.json();
}

async function upload(
  envId: string,
  token: string | null,
  opts: {
    plan: Uint8Array;
    sig: Uint8Array;
    sequence: number;
    sha?: string;
  },
): Promise<Response> {
  const headers: Record<string, string> = {
    "content-type": "application/json",
  };
  if (token !== null) headers["x-api-key"] = token;
  return SELF.fetch(`${BASE}/v1/environments/${envId}/plan`, {
    method: "POST",
    headers,
    body: JSON.stringify({
      plan_bytes_b64: b64(opts.plan),
      envelope_bytes_b64: b64(opts.sig),
      sequence: opts.sequence,
      plan_sha256: opts.sha ?? (await sha256Hex(opts.plan)),
    }),
  });
}

describe("health + session", () => {
  it("serves /healthz", async () => {
    const res = await SELF.fetch(`${BASE}/healthz`);
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("ok");
  });

  it("mints an unguessable env id and its own upload credential", async () => {
    const a = await newSession();
    const b = await newSession();
    expect(a.env_id).toMatch(/^demo-[0-9a-f]{16}$/);
    expect(a.env_id).not.toBe(b.env_id);
    expect(a.upload_token).not.toBe(b.upload_token);
  });
});

describe("upload credential", () => {
  it("rejects a missing X-Api-Key", async () => {
    const { env_id } = await newSession();
    const res = await upload(env_id, null, {
      plan: bytes("p"),
      sig: bytes("s"),
      sequence: 1,
    });
    expect(res.status).toBe(401);
    expect(await res.json()).toMatchObject({ code: "unauthorized" });
  });

  it("rejects another session's token", async () => {
    const a = await newSession();
    const b = await newSession();
    const res = await upload(a.env_id, b.upload_token, {
      plan: bytes("p"),
      sig: bytes("s"),
      sequence: 1,
    });
    expect(res.status).toBe(401);
  });

  it("leaves no environment behind when the credential fails", async () => {
    const { env_id } = await newSession();
    await upload(env_id, "wrong", {
      plan: bytes("p"),
      sig: bytes("s"),
      sequence: 1,
    });
    const res = await SELF.fetch(`${BASE}/v1/environments/${env_id}`);
    expect(res.status).toBe(404);
  });
});

describe("integrity", () => {
  it("rejects a payload whose sha256 does not match the claim", async () => {
    const { env_id, upload_token } = await newSession();
    const res = await upload(env_id, upload_token, {
      plan: bytes("actual"),
      sig: bytes("s"),
      sequence: 1,
      sha: "0".repeat(64),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: string };
    expect(body.error).toContain("sha256 mismatch");
  });

  it("does not auto-create the environment on a bad payload", async () => {
    const { env_id, upload_token } = await newSession();
    await upload(env_id, upload_token, {
      plan: bytes("actual"),
      sig: bytes("s"),
      sequence: 1,
      sha: "0".repeat(64),
    });
    expect((await SELF.fetch(`${BASE}/v1/environments/${env_id}`)).status).toBe(
      404,
    );
  });
});

describe("plan round-trip", () => {
  it("serves back the exact bytes that were signed, anonymously", async () => {
    const { env_id, upload_token } = await newSession();
    // Bytes that are not valid UTF-8 — the store must be byte-transparent.
    const plan = new Uint8Array([0x00, 0xff, 0xfe, 0x01, 0x80]);
    const sig = new Uint8Array([0xde, 0xad, 0xbe, 0xef]);
    expect(
      (await upload(env_id, upload_token, { plan, sig, sequence: 1 })).status,
    ).toBe(201);

    // No credential on the reads: the trust anchor is the signature, not the transport.
    const planRes = await SELF.fetch(`${BASE}/v1/environments/${env_id}/plan`);
    expect(planRes.status).toBe(200);
    expect(new Uint8Array(await planRes.arrayBuffer())).toEqual(plan);

    const sigRes = await SELF.fetch(
      `${BASE}/v1/environments/${env_id}/plan.sig`,
    );
    expect(new Uint8Array(await sigRes.arrayBuffer())).toEqual(sig);

    const meta = (await (
      await SELF.fetch(`${BASE}/v1/environments/${env_id}/plan/meta`)
    ).json()) as { sequence: number; plan_sha256: string };
    expect(meta.sequence).toBe(1);
    expect(meta.plan_sha256).toBe(await sha256Hex(plan));
  });

  it("404s meta for an environment with no plan yet (first publish)", async () => {
    const { env_id } = await newSession();
    const res = await SELF.fetch(`${BASE}/v1/environments/${env_id}/plan/meta`);
    expect(res.status).toBe(404);
  });
});

describe("monotonic sequence", () => {
  it("advances on a higher sequence", async () => {
    const { env_id, upload_token } = await newSession();
    await upload(env_id, upload_token, {
      plan: bytes("v1"),
      sig: bytes("s1"),
      sequence: 1,
    });
    expect(
      (
        await upload(env_id, upload_token, {
          plan: bytes("v2"),
          sig: bytes("s2"),
          sequence: 2,
        })
      ).status,
    ).toBe(201);

    const meta = (await (
      await SELF.fetch(`${BASE}/v1/environments/${env_id}/plan/meta`)
    ).json()) as { sequence: number };
    expect(meta.sequence).toBe(2);
  });

  it("refuses a downgrade with 409", async () => {
    const { env_id, upload_token } = await newSession();
    await upload(env_id, upload_token, {
      plan: bytes("v2"),
      sig: bytes("s2"),
      sequence: 2,
    });
    const res = await upload(env_id, upload_token, {
      plan: bytes("v1"),
      sig: bytes("s1"),
      sequence: 1,
    });
    expect(res.status).toBe(409);
    const body = (await res.json()) as { error: string };
    expect(body.error).toContain("non-monotonic");
  });

  it("treats an identical re-upload as an idempotent no-op", async () => {
    const { env_id, upload_token } = await newSession();
    const args = { plan: bytes("v1"), sig: bytes("s1"), sequence: 1 };
    expect((await upload(env_id, upload_token, args)).status).toBe(201);
    expect((await upload(env_id, upload_token, args)).status).toBe(201);
  });

  it("refuses different content at an already-published sequence", async () => {
    const { env_id, upload_token } = await newSession();
    await upload(env_id, upload_token, {
      plan: bytes("v1"),
      sig: bytes("s1"),
      sequence: 1,
    });
    const res = await upload(env_id, upload_token, {
      plan: bytes("v1-forked"),
      sig: bytes("s1"),
      sequence: 1,
    });
    expect(res.status).toBe(409);
    const body = (await res.json()) as { error: string };
    expect(body.error).toContain("already published with different content");
  });

  it("serializes concurrent publishers — exactly one wins the same sequence", async () => {
    const { env_id, upload_token } = await newSession();
    const results = await Promise.all(
      Array.from({ length: 8 }, (_, i) =>
        upload(env_id, upload_token, {
          plan: bytes(`racer-${i}`),
          sig: bytes(`sig-${i}`),
          sequence: 1,
        }),
      ),
    );
    const created = results.filter((r) => r.status === 201);
    const conflicted = results.filter((r) => r.status === 409);
    expect(created).toHaveLength(1);
    expect(conflicted).toHaveLength(7);
  });
});

describe("shared-instance hardening", () => {
  it("rejects an id with path-traversal characters", async () => {
    const res = await SELF.fetch(
      `${BASE}/v1/environments/${encodeURIComponent("../etc")}/plan/meta`,
    );
    expect(res.status).toBe(400);
    expect(await res.json()).toMatchObject({ code: "bad_request" });
  });

  it("does not expose a list of every environment", async () => {
    const res = await SELF.fetch(`${BASE}/v1/environments`);
    expect(res.status).toBe(404);
  });

  it("keeps the audit log per-environment", async () => {
    const { env_id, upload_token } = await newSession();
    await upload(env_id, upload_token, {
      plan: bytes("v1"),
      sig: bytes("s1"),
      sequence: 1,
    });
    const log = (await (
      await SELF.fetch(`${BASE}/v1/environments/${env_id}/audit`)
    ).json()) as Array<{ action: string }>;
    expect(log.map((e) => e.action)).toEqual([
      "environment_auto_registered",
      "plan_upload",
    ]);
    expect((await SELF.fetch(`${BASE}/v1/audit`)).status).toBe(404);
  });
});
