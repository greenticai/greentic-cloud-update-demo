# cloud-update-demo

A running Greentic environment updates **its content** and then **its own binary**
from a plan server on the public internet — and never trusts that server.

Nothing is pushed at the runtime. Nobody types an apply. The server holds no
signing key and cannot forge an update; the only thing binding a plan to your
environment is a signature made by a key that was minted on your machine.

```bash
git clone https://github.com/greenticai/greentic-cloud-update-demo
cd greentic-cloud-update-demo
cargo binstall greentic-deployer@1.1.10   # the only thing to install
./demo.sh
```

No Cloudflare account. No server to build. No bundles to compile. ~3 minutes.

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

## Commands

```bash
./demo.sh          # run it
./demo.sh fetch    # download + verify the release artifacts only
./demo.sh clean    # remove home/, bin/ and logs (keeps the caches)
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
| `greentic-deployer` ≥ **1.1.10** | `op updates publish` — `cargo binstall greentic-deployer@1.1.10` |
| `curl`, `tar`, `python3`, `sha256sum` | glue |

`greentic-start` is **not** a prerequisite — the demo downloads the two released
runtimes it moves between and verifies them against their published `.sha256`
sidecars.

## Running your own plan server

The server is ~300 lines of TypeScript in [`server/`](server/). Deploying your own
takes one command and a Cloudflare account, after which `SERVER=https://… ./demo.sh`
changes nothing else about the run. See [`server/README.md`](server/README.md).
