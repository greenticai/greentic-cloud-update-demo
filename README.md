# cloud-update-demo

A running Greentic environment updates **its content** and then **its own binary**
from a plan server on the public internet — and never trusts that server.

Nothing is pushed at the runtime. Nobody types an apply. The server holds no
signing key and cannot forge an update; the only thing binding a plan to your
environment is a signature made by a key that was minted on your machine.

```bash
git clone https://github.com/greenticai/greentic-cloud-update-demo
cd greentic-cloud-update-demo
cargo binstall gtc && gtc install --release 1.1.2   # the pinned toolchain
./demo.sh
```

No Cloudflare account. No server to build. **No bundles to download** — the plan
names them by `oci://` ref and `op env apply` pulls them from GHCR itself.
~3 minutes.

```
       operator key — minted on YOUR machine by `op env init`,
       trusted by YOUR environment, never uploaded anywhere
              │ signs
              ▼
   ┌──────────────────────────┐   sign + POST …/plan (X-Api-Key)   ┌────────────────────────┐
   │  greentic-plan-server    │◀───────────── upload ──────────────│  op updates publish    │
   │  (Cloudflare Worker)     │                                    └────────────────────────┘
   │  stores bytes. no keys.  │
   └──────────────────────────┘
              ▲  GET …/plan/meta · …/plan · …/plan.sig   (anonymous, poll loop)
              │
   ┌──────────────────────────┐        ┌──────────────────────────┐
   │      greentic-start      │───────▶│   GitHub Releases (CDN)  │
   │   serving v1, polling    │  fetch │  the binary tarball      │
   └──────────────────────────┘        └──────────────────────────┘
              │ verify DSSE vs trust root → stage → apply
              ▼
        v1 ──────▶ v2        and       1.1.9 ──────▶ 1.1.11
        (content, hot)                 (binary, staged)
```

## What happens

| # | Step | What it proves |
|---|------|----------------|
| 1 | `POST /v1/demo/session` | You get an unguessable namespace on the shared server and an upload credential scoped to it. Reads need no credential at all. |
| 2 | `op env init` + `op env apply` | Mints **your** operator key, seeds its public half into the env's trust root, deploys v1 — *and* writes the update channel, because the manifest declares one. |
| 3 | `greentic-start start` | Serves v1 and polls the cloud. Runs as a **copy** under `./bin` — see the hazard below. |
| 4 | `op updates publish --target-file v2` | Signs the v2 manifest in memory, uploads bytes. Within one poll interval the runtime fetches, verifies, stages, converges, and moves traffic. **No restart.** |
| 5 | `op updates publish --binary …` | The plan pins `greentic-start` 1.1.11 by sha256. The runtime downloads the tarball from GitHub, verifies the inner binary *before touching the filesystem*, renames it over its own `current_exe()` keeping a `.prev`, and starts answering `x-greentic-restart-required: true`. |

Then the script asserts what it claimed:

```
✓ traffic never moved during the binary update — content digest unchanged
✓ the greentic-start on your PATH is byte-for-byte unchanged
✓ on-disk binary == the digest pinned in the signed plan
x-greentic-restart-required: true
```

## What it proves

| Property | How it is enforced |
|---|---|
| **The server cannot forge an update** | Plans are DSSE-signed by the operator key. The server stores bytes and answers GETs. It has no key and never signs. |
| **The server cannot be MITM'd into one either** | Reads are anonymous and the signature — not TLS, not the origin — is the trust anchor. A hostile server can withhold a plan; it cannot mint one. |
| **You cannot be pushed a downgrade** | Every plan carries a monotonic `sequence`, and it is the **signed plan**, not the server's advisory `/meta`, that the anti-rollback check reads. The binary receiver additionally refuses a version `<=` the running one. |
| **Two operators cannot fork a channel** | The store enforces strict monotonicity inside a Durable Object, so the read-modify-write is serialized. The loser of a race gets `409`, never a silent fork. |
| **Discovery is not authority** | The channel is deny-by-default. An env that never declared an `updates` block fetches nothing, ever. |
| **A plan cannot re-point the channel it arrived on** | `op updates publish` strips `updates` from a plan target before signing, and the apply path rejects one that smuggles it in. Otherwise a single compromised plan would be a self-perpetuating takeover. |
| **The artifact host is untrusted** | The tarball comes from GitHub's CDN over a URL in the plan. The **inner binary's** sha256 is pinned in the signed plan and verified in memory before a byte is written. |
| **Convergence is reversible** | Content applies under a pre-apply snapshot with automatic rollback. The binary swap copies the original to `.prev` and commits with a single atomic rename. |
| **Activation is explicit** | A process cannot replace itself in flight. The swap only *stages*: the runtime keeps serving the old code and reports `restart_required`. |

## ⚠️ The hazard this demo guards against

The receiver swaps `std::env::current_exe()`. A `greentic-start` left running from
an earlier demo — started from your **PATH**, with `HOME` pointed at this
directory — subscribes to the very channel this script publishes to. It would win
the poll race and swap **its own** executable: the one in `~/.cargo/bin`.

So `demo.sh` refuses to start while any `greentic-start` is alive, runs a **copy**
under `./bin`, and asserts at the end that the binary on your PATH is unchanged.

If it ever happens to you, the original is sitting next to it:

```bash
mv ~/.cargo/bin/greentic-start.prev ~/.cargo/bin/greentic-start
```

## One server, not two

The plan store **does not host artifacts**. Its routes are `/plan`, `/plan.sig`,
`/plan/meta` and an audit log — there is no file server in it.

That is the TUF split: signed *metadata* lives in one place, the *bytes* it
describes live anywhere (GitHub, a CDN, OCI), and the digest inside the signed
plan is the only thing that binds them. Artifacts are large, cacheable and
**untrusted**; the plan store is a small credential-gated control plane with a
monotonic sequence and an audit trail. Colocating them would be the wrong
simplification.

## Drive it from a web page

<https://cloud-update-demo.pages.dev> is a publishing console. It generates an
Ed25519 key **in your browser**, and two buttons publish v1 / v2 to the plan
server. Your runtime picks the change up within 60s.

Your environment accepts what the page signs for exactly one reason: you add the
page's *public* key to `trust-root.json`. The private half never leaves the
browser, and the server never sees it — so the page is an operator console, not a
new trusted party. The page generates the setup commands with your endpoint and
key already filled in.

The console's crypto is [`docs/publisher.js`](docs/publisher.js) — byte-compatible
with `greentic-update`'s `build_update_plan` (pretty-printed plan JSON, compact
in-toto statement, the non-standard space-delimited DSSE PAE, and
`key_id = sha256(raw pubkey)[..16]`).

## Drive it by hand

`./demo.sh` tells the whole story unattended. To drive the channel yourself and
watch a running environment change under you, use the step commands instead —
you can flip between v1 and v2 as many times as you like:

```bash
./demo.sh env            # create the env, apply v1, subscribe to the channel
./demo.sh serve          # run the runtime (keep this terminal open)

# ...in a second terminal:
./demo.sh switch v2      # publish v2 → within 60s the runtime converges to it
./demo.sh status         # what you serve vs what the server holds
./demo.sh switch v1      # and back again
```

Switching back to v1 is **not** a downgrade. Anti-rollback guards the plan
`sequence`, which only ever grows; the content the plan points at is free to move
in either direction. Publish v1 after v2 and the sequence goes 1 → 2 while the
live bundle returns to webchat-only.

## Commands

```bash
./demo.sh                # the whole story, unattended (content + binary update)

./demo.sh env            # create the environment, apply v1, subscribe
./demo.sh serve          # run the runtime in the foreground
./demo.sh switch v1|v2   # publish that version to the plan server
./demo.sh status         # what your runtime serves vs what the server holds

./demo.sh fetch          # download + verify the release artifacts only
./demo.sh clean          # remove home/, bin/ and logs (keeps the caches)
```

Everything lives under `./home/.greentic`; your real `~/.greentic` is never
touched. Background processes are tracked by PID and killed on exit.

| Variable | Default | Why you'd change it |
|---|---|---|
| `SERVER` | the public plan server | Point at your own deployment (see [`server/`](server/)) |
| `VER_FROM` / `VER_TO` | `1.1.9` / `1.1.11` | Move between different released runtimes |
| `RUNTIME_PORT` | `8080` | The port is taken |

## Prerequisites

| What | Why |
|---|---|
| toolchain release **1.1.2** | `cargo binstall gtc && gtc install --release 1.1.2` — pins `greentic-deployer` 1.1.11 and `greentic-start` 1.1.11 |
| `bash`, `curl`, `tar`, `python3` | glue |

Runs on **Linux and macOS** with the stock toolchain — no coreutils, no Homebrew.
(`sha256sum` on Linux, `shasum` on macOS; `ss` or `lsof` for the port check.)

The **content is never copied to your machine**. Each bundle is named in the
manifest by an `oci://` ref under
`ghcr.io/greenticai/greentic-cloud-update-demo`, and `op env apply` pulls it from
the registry anonymously — no login, no Docker. The plan pins the bundle's
`sha256`, and apply **fails closed** unless the bytes it pulled hash to exactly
that: the registry is an untrusted delivery channel, precisely like the plan
server.

## Running your own plan server

The server is ~300 lines of TypeScript in [`server/`](server/). Deploying your own
takes one command and a Cloudflare account, after which `SERVER=https://… ./demo.sh`
changes nothing else about the run. See [`server/README.md`](server/README.md).
