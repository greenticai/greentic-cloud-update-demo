# greentic-plan-server

The Greentic plan store, as a Cloudflare Worker. It stores DSSE-signed update
plans and serves them anonymously. **It holds no signing key and cannot mint,
alter, or forge a plan** — it can only lose one, which the client survives.

A port of the plan-store half of `greentic-updates-server` (the Rust original),
with the wire contract preserved byte for byte: same routes, same JSON shapes,
same error envelope (`{"error": "...", "code": "..."}`), same status codes.

## Why a Durable Object

The store's headline guarantee is a **strictly monotonic sequence**: two
operators publishing concurrently must not silently fork the channel — the loser
gets a `409`. That check is a read-modify-write, so it is only a guarantee if the
writes are serialized.

One Durable Object per environment id gives exactly that. On KV the check would
be racy, and the demo would be claiming a property it does not have. The test
suite asserts it directly: eight concurrent publishers at the same sequence →
exactly one `201`, seven `409`.

## Routes

| Route | Auth | Purpose |
|---|---|---|
| `GET /healthz` | — | liveness |
| `POST /v1/demo/session` | rate-limited by IP | mint an ephemeral env id + an upload credential scoped to it (24h TTL) |
| `POST /v1/environments/{id}/plan` | `X-Api-Key` | upload a signed plan; monotonic, idempotent on identical replay |
| `GET /v1/environments/{id}/plan` | **none** | the signed plan bytes |
| `GET /v1/environments/{id}/plan.sig` | **none** | the DSSE envelope |
| `GET /v1/environments/{id}/plan/meta` | **none** | `{sequence, plan_sha256, uploaded_at}` |
| `GET /v1/environments/{id}` | none | the environment record |
| `GET /v1/environments/{id}/audit` | none | what happened to this environment |

Reads are anonymous **by design**. The trust anchor is the signature the runtime
verifies against its own trust root, not the transport and not the origin.

### Deliberate divergences from the Rust original

This instance is public and shared, so three things changed:

- **No `GET /v1/environments`** — listing every environment would leak other
  people's ids.
- **The audit log is per-environment**, not global, for the same reason.
- **No Cert-CA routes** (`/v1/ca`, `/v1/enroll`, `/v1/revoke`, `/v1/crl`). Plan
  reads are anonymous, so nothing enrolls.

Two things were tightened:

- The upload credential is compared in **constant time** (the Rust original uses
  `!=` and calls a constant-time compare a follow-up; on an internet-facing
  server that follow-up is not optional).
- Upload bodies are **size-bounded before buffering** (512 KB), and the decoded
  plan and envelope are capped at 64 KB each.

## Upload credentials

Deny-by-default. Two credentials are accepted:

- the **per-environment token** minted by `POST /v1/demo/session` — this is what
  lets anyone run the demo against the shared instance with no account and no
  secret committed to the repo;
- a **server-wide `PLAN_UPLOAD_TOKEN` secret**, matching the Rust server's
  behaviour, for a self-hosted single-tenant deployment.

With neither configured, uploads are disabled outright.

Guessing someone else's env id buys an attacker nothing: they could overwrite the
plan, but that runtime will reject anything not signed by a key its trust root
already carries. The worst case is denial of an update, not a compromise.

## Deploy your own

```bash
cp .cloudflare.env.example .cloudflare.env   # fill in, then: chmod 600 .cloudflare.env
./deploy.sh                                   # typecheck → test → deploy
```

The API token needs the **"Edit Cloudflare Workers"** template. A Pages-scoped
token cannot create a Worker or a Durable Object.

> The credentials deliberately live in `.cloudflare.env`, **not** `.env`: wrangler
> treats a `.env` file as a source of Worker *secrets* and binds its contents into
> the deployed Worker's runtime environment. A Cloudflare API token has no
> business inside the Worker it deploys.

For a single-tenant deployment, add a server-wide credential and skip the demo
session flow entirely:

```bash
npx wrangler secret put PLAN_UPLOAD_TOKEN
```

Then point the demo at it — nothing else about the run changes:

```bash
SERVER=https://your-worker.workers.dev ../demo.sh
```

## Development

```bash
npm install
npm test         # 17 tests, in workerd, against real Durable Object storage
npm run typecheck
npm run dev      # local server on :8787
./deploy.sh --check   # typecheck + test, no deploy
```
