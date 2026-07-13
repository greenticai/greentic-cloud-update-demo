// The publishing console's crypto, in the browser.
//
// This is the whole point of the demo: the page holds an Ed25519 key it
// generated itself, signs update plans with it, and uploads only bytes. The
// plan server never sees the private key and cannot mint a plan. Your runtime
// accepts what the page publishes for exactly one reason — you added the page's
// PUBLIC key to your environment's trust root.
//
// Byte-for-byte compatible with `greentic-update`'s `build_update_plan`:
//   plan bytes   = pretty JSON (2-space), field order as in the Rust struct
//   statement    = in-toto v1, COMPACT JSON, digest = sha256(plan bytes)
//   PAE          = "DSSEv1 <len> <type> <len> <payload>"  (spaces + decimal —
//                  NOT the null-byte PAE from the DSSE spec)
//   key_id       = hex(sha256(raw 32-byte public key)[..16])

const PAYLOAD_TYPE = "application/vnd.in-toto+json";
const PREDICATE_TYPE = "greentic.update-plan-predicate.v1";

const enc = new TextEncoder();

const hex = (buf) =>
  [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");

const b64 = (bytes) => {
  let s = "";
  for (const b of new Uint8Array(bytes)) s += String.fromCharCode(b);
  return btoa(s);
};

const sha256 = (bytes) => crypto.subtle.digest("SHA-256", bytes);

/** Crockford base32 ULID: 48-bit ms timestamp + 80 bits of randomness. */
function ulid() {
  const A = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
  const rnd = crypto.getRandomValues(new Uint8Array(10));
  let n = BigInt(Date.now());
  for (const b of rnd) n = (n << 8n) | BigInt(b);
  let out = "";
  for (let i = 0; i < 26; i++) {
    out = A[Number(n & 31n)] + out;
    n >>= 5n;
  }
  return out;
}

/** RFC3339 with nanosecond precision, which is what the Rust side emits. */
const nowRfc3339 = () =>
  new Date().toISOString().replace(/\.(\d{3})Z$/, ".$1000000Z");

/** Ed25519 SPKI DER = fixed 12-byte prefix + the raw 32-byte key. */
function spkiPem(rawPub) {
  const prefix = [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00];
  const der = new Uint8Array([...prefix, ...new Uint8Array(rawPub)]);
  return `-----BEGIN PUBLIC KEY-----\n${b64(der)}\n-----END PUBLIC KEY-----\n`;
}

export async function generateKey() {
  const kp = await crypto.subtle.generateKey({ name: "Ed25519" }, true, [
    "sign",
    "verify",
  ]);
  const rawPub = await crypto.subtle.exportKey("raw", kp.publicKey);
  const keyId = hex(await sha256(rawPub)).slice(0, 32);
  return {
    privateKey: kp.privateKey,
    publicKey: kp.publicKey,
    keyId,
    publicKeyPem: spkiPem(rawPub),
  };
}

/** Persist across reloads so the trust root you configured stays valid. */
export async function loadOrCreateKey(store = localStorage) {
  const saved = store.getItem("greentic.demo.key");
  if (saved) {
    const { jwk, keyId, publicKeyPem } = JSON.parse(saved);
    const privateKey = await crypto.subtle.importKey(
      "jwk",
      jwk,
      { name: "Ed25519" },
      true,
      ["sign"],
    );
    return { privateKey, keyId, publicKeyPem };
  }
  const k = await generateKey();
  const jwk = await crypto.subtle.exportKey("jwk", k.privateKey);
  store.setItem(
    "greentic.demo.key",
    JSON.stringify({ jwk, keyId: k.keyId, publicKeyPem: k.publicKeyPem }),
  );
  return k;
}

function pae(payloadType, payload) {
  const t = enc.encode(payloadType);
  const head = enc.encode(
    `DSSEv1 ${t.length} ${payloadType} ${payload.length} `,
  );
  return new Uint8Array([...head, ...payload]);
}

/**
 * Build the plan document and its DSSE envelope.
 *
 * `target` is a greentic.env-manifest.v1. Any `updates` block is stripped first:
 * a signed plan that could re-point the channel it arrived on would be a
 * self-perpetuating takeover primitive, so the CLI refuses to sign one and so
 * do we.
 */
export async function buildSignedPlan({ key, envId, sequence, target }) {
  const clean = { ...target };
  delete clean.updates;

  const planId = ulid();
  const nonce = ulid();
  const createdAt = nowRfc3339();

  // Field order matches the Rust struct; `binaries` is omitted when empty.
  const plan = {
    schema: "greentic.update-plan.v1",
    plan_id: planId,
    env_id: envId,
    sequence,
    created_at: createdAt,
    nonce,
    target: clean,
    artifacts: [],
    compat: {},
    rollback: { policy: "auto", health_timeout_s: 120, on_fail: "restore" },
  };
  const planBytes = enc.encode(JSON.stringify(plan, null, 2));
  const planSha256 = hex(await sha256(planBytes));

  const statement = {
    _type: "https://in-toto.io/Statement/v1",
    subject: [
      { name: `update-plan/${planId}`, digest: { sha256: planSha256 } },
    ],
    predicateType: PREDICATE_TYPE,
    // The verifier cross-checks every one of these against the plan document.
    predicate: {
      created_at: createdAt,
      env_id: envId,
      nonce,
      plan_id: planId,
      schema: PREDICATE_TYPE,
      sequence,
    },
  };
  const payload = enc.encode(JSON.stringify(statement));

  const sig = await crypto.subtle.sign(
    { name: "Ed25519" },
    key.privateKey,
    pae(PAYLOAD_TYPE, payload),
  );

  const envelope = {
    payloadType: PAYLOAD_TYPE,
    payload: b64(payload),
    signatures: [{ keyid: key.keyId, sig: b64(sig) }],
  };
  const envelopeBytes = enc.encode(JSON.stringify(envelope, null, 2));

  return { planBytes, envelopeBytes, planSha256, planId, sequence };
}

/** The server's current sequence, or 0 when nothing has been published yet. */
export async function currentSequence(planEndpoint) {
  const res = await fetch(`${planEndpoint}/meta`);
  if (res.status === 404) return 0;
  if (!res.ok) throw new Error(`plan server: HTTP ${res.status}`);
  return (await res.json()).sequence;
}

/**
 * Sign locally, upload bytes. The sequence comes from the server, so two
 * publishers cannot silently fork the channel — the loser gets a 409.
 */
export async function publish({ key, planEndpoint, uploadToken, envId, target }) {
  const sequence = (await currentSequence(planEndpoint)) + 1;
  const { planBytes, envelopeBytes, planSha256 } = await buildSignedPlan({
    key,
    envId,
    sequence,
    target,
  });

  const res = await fetch(planEndpoint, {
    method: "POST",
    headers: { "content-type": "application/json", "x-api-key": uploadToken },
    body: JSON.stringify({
      plan_bytes_b64: b64(planBytes),
      envelope_bytes_b64: b64(envelopeBytes),
      sequence,
      plan_sha256: planSha256,
    }),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(body.error || `upload failed: HTTP ${res.status}`);
  }
  return { sequence, planSha256 };
}

/** The env-manifest the plan carries. bundlesDir is a path on the USER's machine. */
export function manifestFor(version, bundlesDir, digest, envId = "local") {
  return {
    schema: "greentic.env-manifest.v1",
    environment: { id: envId },
    bundles: [
      {
        bundle_id: "updatedemo",
        bundle_path: `${bundlesDir.replace(/\/+$/, "")}/${version}.gtbundle`,
        bundle_digest: `sha256:${digest}`,
      },
    ],
  };
}
