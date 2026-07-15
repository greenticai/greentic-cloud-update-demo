import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

/**
 * The SSE push channel, exercised against real workerd + real Durable Object
 * storage. The runtime derives this endpoint from its `plan_endpoint` (trailing
 * `/plan` → `/updates/stream`) and treats each `plan` event as a hint: it
 * carries the sequence and digest, never plan bytes, and the runtime reacts by
 * running its own verified fetch. These tests assert that contract — an event is
 * delivered on upload, a fresh subscriber is caught up to the head, and a
 * resuming one is not re-sent what it already saw.
 */

const BASE = "https://plan.test";

async function sha256Hex(b: Uint8Array): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", b as BufferSource);
  return [...new Uint8Array(d)]
    .map((x) => x.toString(16).padStart(2, "0"))
    .join("");
}

function b64(bytes: Uint8Array): string {
  let s = "";
  for (const x of bytes) s += String.fromCharCode(x);
  return btoa(s);
}

const bytes = (s: string) => new TextEncoder().encode(s);

async function newSession(): Promise<{ env_id: string; upload_token: string }> {
  const res = await SELF.fetch(`${BASE}/v1/demo/session`, { method: "POST" });
  expect(res.status).toBe(201);
  return res.json();
}

async function publish(
  envId: string,
  token: string,
  plan: Uint8Array,
  sequence: number,
): Promise<Response> {
  return SELF.fetch(`${BASE}/v1/environments/${envId}/plan`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-api-key": token },
    body: JSON.stringify({
      plan_bytes_b64: b64(plan),
      envelope_bytes_b64: b64(bytes("sig")),
      sequence,
      plan_sha256: await sha256Hex(plan),
    }),
  });
}

function openStream(envId: string, lastEventId?: number): Promise<Response> {
  const headers: Record<string, string> = { accept: "text/event-stream" };
  if (lastEventId !== undefined) headers["Last-Event-ID"] = String(lastEventId);
  return SELF.fetch(`${BASE}/v1/environments/${envId}/updates/stream`, {
    headers,
  });
}

interface PlanEvent {
  schema: string;
  env_id: string;
  sequence: number;
  plan_sha256: string;
}

/** Parse one SSE frame; return the decoded `plan` event, or null for anything else. */
function parsePlanFrame(frame: string): PlanEvent | null {
  let event = "";
  const data: string[] = [];
  for (const line of frame.split("\n")) {
    if (line.startsWith("event:")) event = line.slice(6).trimStart();
    else if (line.startsWith("data:"))
      data.push(line.slice(5).replace(/^ /, ""));
  }
  if (event !== "plan") return null;
  try {
    return JSON.parse(data.join("\n")) as PlanEvent;
  } catch {
    return null;
  }
}

/** Read the stream until `want` `plan` events are seen, then cancel. */
async function readPlanEvents(
  res: Response,
  want: number,
  timeoutMs = 5000,
): Promise<PlanEvent[]> {
  const reader = res.body!.getReader();
  const decoder = new TextDecoder();
  const events: PlanEvent[] = [];
  let buf = "";
  const timeout = new Promise<never>((_, reject) =>
    setTimeout(
      () => reject(new Error("timed out waiting for plan events")),
      timeoutMs,
    ),
  );
  try {
    while (events.length < want) {
      const { value, done } = await Promise.race([reader.read(), timeout]);
      if (done) break;
      buf += decoder.decode(value, { stream: true });
      let i: number;
      while ((i = buf.indexOf("\n\n")) !== -1) {
        const evt = parsePlanFrame(buf.slice(0, i));
        buf = buf.slice(i + 2);
        if (evt) events.push(evt);
      }
    }
  } finally {
    await reader.cancel().catch(() => {});
  }
  return events;
}

describe("SSE stream — headers", () => {
  it("answers text/event-stream, even before any plan exists", async () => {
    const { env_id } = await newSession();
    const res = await openStream(env_id);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("text/event-stream");
    await res.body!.cancel();
  });
});

describe("SSE stream — push on upload", () => {
  it("delivers a plan event to a live subscriber when a plan is published", async () => {
    const { env_id, upload_token } = await newSession();
    const stream = await openStream(env_id); // subscribe before the publish
    const plan = bytes("v2-content");
    expect((await publish(env_id, upload_token, plan, 1)).status).toBe(201);

    const [evt] = await readPlanEvents(stream, 1);
    expect(evt).toMatchObject({
      schema: "greentic.update-event.v1",
      env_id,
      sequence: 1,
      plan_sha256: await sha256Hex(plan),
    });
  });

  it("does not push on an idempotent re-upload — an unchanged head is not news", async () => {
    const { env_id, upload_token } = await newSession();
    const plan = bytes("v1");
    await publish(env_id, upload_token, plan, 1); // seq 1 is now the head
    const stream = await openStream(env_id, 1); // resuming: already saw seq 1

    // Re-upload the identical seq 1 (idempotent no-op), then publish seq 2. If the
    // no-op had broadcast, the first event would be seq 1; it must be seq 2.
    expect((await publish(env_id, upload_token, plan, 1)).status).toBe(201);
    await publish(env_id, upload_token, bytes("v2"), 2);

    const [evt] = await readPlanEvents(stream, 1);
    expect(evt.sequence).toBe(2);
  });
});

describe("SSE stream — catch-up", () => {
  it("catches a fresh subscriber up to the current head", async () => {
    const { env_id, upload_token } = await newSession();
    const plan = bytes("already-published");
    await publish(env_id, upload_token, plan, 1);

    // Subscribe AFTER the plan exists: catch-up must hand it over immediately,
    // without waiting for the next publish.
    const [evt] = await readPlanEvents(await openStream(env_id), 1);
    expect(evt).toMatchObject({
      sequence: 1,
      plan_sha256: await sha256Hex(plan),
    });
  });

  it("does not replay a head the resuming subscriber has already seen", async () => {
    const { env_id, upload_token } = await newSession();
    await publish(env_id, upload_token, bytes("v1"), 1);

    // Last-Event-ID says "I have seq 1" — catch-up must send nothing for it. The
    // next event the subscriber sees must be the newer seq 2.
    const stream = await openStream(env_id, 1);
    await publish(env_id, upload_token, bytes("v2"), 2);

    const [evt] = await readPlanEvents(stream, 1);
    expect(evt.sequence).toBe(2);
  });
});
