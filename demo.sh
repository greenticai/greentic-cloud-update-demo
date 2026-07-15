#!/usr/bin/env bash
# ===========================================================================
# cloud-update-demo — a running environment updates itself, and then its own
#                     binary, from a plan server on the public internet.
#
# Anyone can run this. There is nothing to build and no account to create:
#
#   the deployer                  cargo binstall greentic-deployer@1.1.16
#                                 (greentic-start 1.1.20/1.1.21 is fetched below)
#   curl, tar, python3  (Linux and macOS; no coreutils needed)
#
# The plan server is already running at $SERVER. It stores DSSE-signed plans and
# serves them anonymously. It holds no signing key and cannot forge an update.
#
# ── PUSH, not poll ─────────────────────────────────────────────────────────
# The runtime opens a Server-Sent Events stream to the server and is *pushed* a
# one-line hint the moment a plan is published — {env_id, sequence, plan_sha256},
# never plan bytes. It reacts by running its normal verified fetch. The hint is
# the same data the anonymous `/plan/meta` already exposes, so a spoofed event
# costs one wasted fetch, never a bad apply. The poll loop stays as a backstop,
# but its interval is set to an HOUR here on purpose: convergence in seconds is
# then proof the push stream — not a lucky poll — delivered it.
#
# The trust chain is real end to end. `op env init` mints YOUR operator key on
# YOUR machine and seeds its public half into the environment's trust root.
# `op updates publish` signs the plan with the private half — which never leaves
# this machine — and uploads only bytes. The runtime verifies every plan against
# its own trust root before it will stage anything. The server is a dumb store:
# it can lose a plan, it cannot mint one.
#
# Two updates, in one run:
#
#   1. CONTENT   v1 (webchat) → v2 (webchat + telegram). Pushed, then converges
#                hot: the runtime snapshots, applies, verifies, and moves traffic
#                with no restart. Rolls back by itself on failure.
#
#   2. BINARY    greentic-start 1.1.20 → 1.1.21. Pushed too. The plan pins the
#                inner binary's sha256; the runtime verifies the bytes BEFORE
#                touching the filesystem, renames the new binary over its own
#                current_exe() keeping a .prev, and starts answering
#                restart-required. A process cannot replace itself in flight, so
#                this one STAGES — traffic never moves, and we assert the live
#                content is unchanged.
#
# ── DANGER, and why this script is careful ─────────────────────────────────
# The receiver swaps `std::env::current_exe()`. A greentic-start left running
# from an earlier demo — started from your PATH, with HOME pointed here —
# subscribes to the very channel this script publishes to. It would win the poll
# race and swap the binary in your ~/.cargo/bin. So this script refuses to start
# while any greentic-start is alive, runs a COPY under ./bin, and asserts at the
# end that the greentic-start on your PATH is byte-for-byte what it was.
#
# Usage:
#   ./demo.sh          run it (content + binary, both pushed over SSE)
#   ./demo.sh no-push  the negative control: push off → v2 must NOT converge in time
#   ./demo.sh fetch    download + verify the release artifacts only
#   ./demo.sh clean    remove home/, bin/ and logs (keeps the caches)
# ===========================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- the plan server ------------------------------------------------------
# Public, shared, and stateless as far as trust is concerned. Point SERVER at
# your own deployment (see server/README.md) and nothing else changes.
SERVER="${SERVER:-https://greentic-plan-server.vladik-dobrik.workers.dev}"

# --- binaries -------------------------------------------------------------
DEP="${DEP:-greentic-deployer}"        # >= 1.1.16 — push fields in `op updates`
VER_FROM="${VER_FROM:-1.1.20}"         # first release with the SSE push receiver
VER_TO="${VER_TO:-1.1.21}"             # strictly newer: the runtime refuses <=
START_REL="https://github.com/greenticai/greentic-start/releases/download"

# --- content: two versions of one bundle ----------------------------------
# Named by `oci://` ref, never copied here: `op env apply` pulls the bundle from
# the registry itself. The plan pins the digest below, and apply fails closed
# unless the bytes it pulled hash to it — so the registry is an untrusted
# delivery channel, exactly like the plan server.
# Maintainers rebuild and republish them with ./build-bundles.sh.
OCI_BASE="${OCI_BASE:-oci://ghcr.io/greenticai/greentic-cloud-update-demo}"
V1_DIGEST="6e6f24f5c3f12c41eaa46d92a54632a131c65b0b7d591c9759a18792700bbb8f"
V2_DIGEST="feb45fafda62abe23b4c479d25120f82e6450745d4984d6ca105886cffecbe83"

# --- demo-local state (never touches your real ~/.greentic) ---------------
HOME_DIR="$HERE/home"                  # becomes $HOME for every command below
CACHE_DIR="$HERE/release-cache"        # downloaded runtime tarballs
BIN_DIR="$HERE/bin"                    # the runtime COPY that the swap replaces
RUNTIME_BIN="$BIN_DIR/greentic-start"
BUNDLE_ID="updatedemo"
RUNTIME_PORT="${RUNTIME_PORT:-8080}"

# The poll interval is set to an HOUR (the runtime's own default). The point is
# to take the poll OUT of the picture: with push working, a plan converges in
# seconds, which the once-an-hour poll could not possibly explain. That is the
# whole proof — see step 4. `no-push` mode flips PUSH_ENABLED to false and shows
# the same publish does NOT converge inside the budget, i.e. the demo can fail
# for the stated reason.
POLL_INTERVAL="${POLL_INTERVAL:-3600}" # DEFAULT_POLL_INTERVAL_SECS — an hour away
PUSH_BUDGET="${PUSH_BUDGET:-90}"       # seconds a pushed update must converge in
PUSH_ENABLED="${PUSH_ENABLED:-true}"   # `no-push` sets this false (negative control)

# The LOCAL environment is `local`. The SERVER-side namespace is the random
# `demo-…` the plan server mints for this run. They are independent on purpose:
# the server id is just a path segment in the endpoint URL, and a non-`local`
# local env would need a `customer_id` billing principal this demo has no use for.
ENV_ID="local"

# --- presentation ---------------------------------------------------------
if [ -t 1 ]; then BOLD=$'\e[1m'; GRN=$'\e[32m'; CYN=$'\e[36m'; RED=$'\e[31m'; DIM=$'\e[2m'; Z=$'\e[0m'
else BOLD= GRN= CYN= RED= DIM= Z=; fi
say()  { printf '%s\n' "${CYN}${BOLD}▸ $*${Z}"; }
ok()   { printf '%s\n' "${GRN}  ✓ $*${Z}"; }
info() { printf '%s\n' "  $*"; }
dim()  { printf '%s\n' "${DIM}  $*${Z}"; }
die()  { printf '%s\n' "${RED}✗ $*${Z}" >&2; exit 1; }
step() { printf '\n%s\n' "${BOLD}══ $* ══${Z}"; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 not on PATH${2:+ — $2}"; }

version_at_least() { # <binary> <min>
  local have; have=$("$1" --version 2>/dev/null | awk '{print $NF}')
  python3 - "$have" "$2" <<'PY' || die "$1 is $have, need >= $2"
import sys
def parts(v): return [int(x) for x in v.split("-")[0].split(".")]
sys.exit(0 if parts(sys.argv[1]) >= parts(sys.argv[2]) else 1)
PY
  ok "$1 $have"
}

# --- background processes: PID-based cleanup, never `pkill -f` ------------
PIDS=()
cleanup() { local p; for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
start_bg() { local log="$1"; shift; "$@" >"$log" 2>&1 & PIDS+=($!); }

# `op` is a subcommand of the deployer binary, run against the isolated home.
op() { env HOME="$HOME_DIR" "$DEP" op "$@"; }

# The bundle digest currently serving traffic — the thing a content update moves.
live_digest() {
  op env show "$ENV_ID" 2>/dev/null | python3 -c '
import json, sys
env = json.load(sys.stdin)["result"]["environment"]
live = {e["revision_id"] for s in env["traffic_splits"] for e in s["entries"] if e["weight_bps"] > 0}
print("".join(r["bundle_digest"] for r in env["revisions"] if r["revision_id"] in live))
' 2>/dev/null || true
}

show_live() {
  op env show "$ENV_ID" | python3 -c '
import json, sys
env = json.load(sys.stdin)["result"]["environment"]
live = {e["revision_id"] for s in env["traffic_splits"] for e in s["entries"] if e["weight_bps"] > 0}
for r in env["revisions"]:
    if r["revision_id"] in live:
        packs = ", ".join(p["pack_id"] for p in r["pack_list"])
        print("    sequence %s   %s   [%s]" % (r["sequence"], r["bundle_digest"], packs))
'
}

# ===========================================================================
# Portability: macOS ships neither `sha256sum` nor `ss`. Everything below is
# POSIX-ish and works on Linux and macOS with the stock toolchain.

# The digest of a file, as bare hex.
sha256_of() { # <file>
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else die "need sha256sum (Linux) or shasum (macOS)"
  fi
}

# Compare a file against a `<hash>  <name>` sidecar. `sha256sum -c` would be the
# obvious call, but macOS has no such thing — so read the hash and compare it.
sha256_matches() { # <file> <sidecar>
  local want have
  want="$(awk '{print $1}' "$2" 2>/dev/null)"
  have="$(sha256_of "$1")"
  [ -n "$want" ] && [ "$want" = "$have" ]
}

# The receiver swaps current_exe(). Refuse to race a stray runtime.
port_busy() { # <port>
  if command -v ss >/dev/null 2>&1; then
    ss -ltn "sport = :$1" 2>/dev/null | tail -n +2 | grep -q .
  elif command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
  else
    return 1   # cannot tell; the runtime will fail loudly if the port is taken
  fi
}

assert_clean_host() {
  # `pgrep -x` matches the kernel's 15-char `comm`, so only greentic-start is
  # name-matched — it is the one process that rewrites an executable.
  local stray
  if command -v pgrep >/dev/null 2>&1 && stray=$(pgrep -x greentic-start 2>/dev/null) && [ -n "$stray" ]; then
    stray=$(echo "$stray" | tr '\n' ' ')
    die "a greentic-start is already running (pid $stray)
    It may be a survivor of an earlier demo. A stray runtime pointed at this
    demo's HOME polls the same channel, wins the race, and swaps ITS OWN
    executable — the one on your PATH.
    Stop it first:  kill $stray"
  fi
  port_busy "$RUNTIME_PORT" \
    && die "port $RUNTIME_PORT is already in use — stop whatever holds it, then re-run"
  ok "no stray runtime, port $RUNTIME_PORT free"
}

# ===========================================================================
# The plan pins a digest for ONE (name, target) pair. The target triple is baked
# into the running binary at compile time, so it is the RELEASE's triple.
detect_target() {
  local os arch; os="$(uname -s)"; arch="$(uname -m)"
  case "$os/$arch" in
    Linux/x86_64)  echo x86_64-unknown-linux-gnu  ;;
    Linux/aarch64) echo aarch64-unknown-linux-gnu ;;
    Darwin/arm64)  echo aarch64-apple-darwin      ;;
    Darwin/x86_64) echo x86_64-apple-darwin       ;;
    *) die "no published greentic-start release for $os/$arch" ;;
  esac
}
TARGET="${TARGET:-$(detect_target)}"

tarball_name() { printf 'greentic-start-v%s-%s.tgz' "$1" "$TARGET"; }

# Download an artifact and verify it against its published .sha256 sidecar. The
# sidecar is re-fetched every time: trusting a cached checksum for a cached
# artifact proves nothing.
fetch_verified() { # <url-base> <filename> <destdir>
  local base="$1" f="$2" dir="$3" out="$3/$2"
  mkdir -p "$dir"
  if [ ! -f "$out" ]; then
    say "downloading $f"
    curl -fsSL --retry 3 -o "$out.part" "$base/$f" || die "download failed: $base/$f"
    mv "$out.part" "$out"
  fi
  curl -fsSL --retry 3 -o "$dir/$f.sha256" "$base/$f.sha256" \
    || die "checksum sidecar unavailable for $f"
  sha256_matches "$out" "$dir/$f.sha256" \
    || die "checksum mismatch for $f — refusing to use it"
  ok "$f (checksum verified)"
}

# Extract the inner greentic-start. `unpack_release_binary` matches by exact
# file-name component, so the nesting inside the archive is irrelevant.
extract_binary() { # <tarball> <destdir>
  local tgz="$1" dest="$2"
  rm -rf "$dest"; mkdir -p "$dest"
  tar xzf "$tgz" -C "$dest"
  find "$dest" -type f -name greentic-start | head -1
}

cmd_fetch() {
  need curl; need tar; need python3
  step "fetch the release artifacts ($TARGET)"
  fetch_verified "$START_REL/v$VER_FROM" "$(tarball_name "$VER_FROM")" "$CACHE_DIR"
  fetch_verified "$START_REL/v$VER_TO"   "$(tarball_name "$VER_TO")"   "$CACHE_DIR"
  dim "no bundles are downloaded — apply pulls them from ${OCI_BASE#oci://}"
}

cmd_clean() {
  rm -rf "$HOME_DIR" "$BIN_DIR"
  rm -f "$HERE"/.runtime.log "$HERE"/.session.json
  ok "removed home/, bin/ and logs (caches kept)"
}

# ===========================================================================
# The manual flow: `env` → `serve` → `switch v2` / `switch v1` → `status`.
#
# Same commands the scripted run makes, one at a time, so you can drive the
# channel by hand and watch a running environment change under you.
# ===========================================================================

# Read a field out of the session the plan server minted for this checkout.
session() { # <field>
  [ -f "$HERE/.session.json" ] || die "no namespace yet — run: ./demo.sh env"
  python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' \
    "$HERE/.session.json" "$1"
}

# Put a greentic-start COPY under ./bin and print its path. Never run the one on
# your PATH: a plan carrying a binary would swap whatever `current_exe()` is.
ensure_runtime_bin() {
  [ -x "$RUNTIME_BIN" ] && return 0
  need curl; need tar
  fetch_verified "$START_REL/v$VER_FROM" "$(tarball_name "$VER_FROM")" "$CACHE_DIR"
  local from_bin
  from_bin="$(extract_binary "$CACHE_DIR/$(tarball_name "$VER_FROM")" "$CACHE_DIR/x-$VER_FROM")"
  [ -n "$from_bin" ] || die "no greentic-start inside the $VER_FROM tarball"
  mkdir -p "$BIN_DIR"
  cp "$from_bin" "$RUNTIME_BIN"; chmod +x "$RUNTIME_BIN"
}

cmd_env() {
  step "create the environment and apply v1"
  need curl; need tar; need python3
  need "$DEP" "cargo binstall greentic-deployer@1.1.16"
  version_at_least "$DEP" 1.1.16

  say "claiming a namespace on $SERVER"
  curl -fsS --retry 3 -X POST "$SERVER/v1/demo/session" -o "$HERE/.session.json" \
    || die "could not reach the plan server at $SERVER"
  PLAN_ENDPOINT="$(session plan_endpoint)"
  ok "namespace $(session env_id) — expires in 24h"

  mkdir -p "$HERE/manifests"
  write_manifests
  ok "manifests/v1.gen.json (carries the \`updates\` block) and v2.gen.json"

  rm -rf "$HOME_DIR"; mkdir -p "$HOME_DIR"
  say "op env init — mints your operator key, seeds the env's trust root"
  op env init | python3 -c '
import json, sys
r = json.load(sys.stdin)["result"]
print("    operator_key_id=%s" % r["trust_root"]["operator_key_id"])'

  say "op env apply — deploys v1 AND subscribes to the channel"
  op env apply --answers "$HERE/manifests/v1.gen.json" >/dev/null \
    || die "env apply failed"
  ok "v1 is live:"
  show_live

  info ""
  info "next:  ./demo.sh serve          (in this terminal — keep it open)"
  info "then:  ./demo.sh switch v2      (in a second terminal)"
}

cmd_serve() {
  [ -f "$HERE/.session.json" ] || die "no environment yet — run: ./demo.sh env"
  assert_clean_host
  ensure_runtime_bin
  step "serving env \`$ENV_ID\` — subscribed to $(session env_id), poll fallback ${POLL_INTERVAL}s"
  info "publish from another terminal:  ./demo.sh switch v2"
  info "Ctrl-C to stop."
  echo
  # Foreground on purpose: its log IS the demo. Convergence shows up here.
  exec env HOME="$HOME_DIR" "$RUNTIME_BIN" start --env "$ENV_ID" --no-browser
}

cmd_switch() { # <v1|v2>
  local v="${1:-}"
  case "$v" in v1|v2) ;; *) die "usage: $0 switch v1|v2" ;; esac
  [ -f "$HERE/manifests/$v.gen.json" ] || die "no manifests — run: ./demo.sh env"

  step "publish $v to the plan server"
  # Switching BACK to v1 is not a downgrade: anti-rollback guards the plan
  # SEQUENCE (which only ever grows), not the content the plan points at.
  say "op updates publish — next sequence from the server, sign in memory, upload"
  env GREENTIC_PLAN_UPLOAD_TOKEN="$(session upload_token)" HOME="$HOME_DIR" "$DEP" \
    op updates publish "$ENV_ID" --target-file "$HERE/manifests/$v.gen.json" \
    | python3 -c '
import json, sys
r = json.load(sys.stdin)["result"]
print("    sequence=%s  key_id=%s  plan_sha256=%s…" % (r["sequence"], r["key_id"], r["plan_sha256"][:16]))'
  ok "uploaded. The server pushed a one-line hint down the runtime's stream."
  info "within a second it fetches, verifies the signature, and converges — no wait for the poll."
  info "watch:  ./demo.sh status"
}

cmd_status() {
  step "status"
  say "what your runtime is actually serving"
  if [ -n "$(live_digest)" ]; then
    show_live
    dim "v1 = [app-webchat-bot]   v2 = [app-webchat-bot, messaging-telegram]"
  else
    info "    no environment yet — run: ./demo.sh env"
    return 0
  fi

  say "what the plan server is holding"
  curl -fsS "$SERVER/v1/environments/$(session env_id)/plan/meta" 2>/dev/null \
    | python3 -c '
import json, sys
m = json.load(sys.stdin)
print("    sequence=%s  plan_sha256=%s…  uploaded_at=%s" % (m["sequence"], m["plan_sha256"][:16], m["uploaded_at"]))' \
    || info "    no plan published yet"

  if curl -fsS -m 2 "localhost:$RUNTIME_PORT/healthz" >/dev/null 2>&1; then
    say "runtime is up on :$RUNTIME_PORT"
    curl -si -m 2 "localhost:$RUNTIME_PORT/healthz" 2>/dev/null \
      | grep -i 'restart-required' | sed 's/^/    /' || true
  else
    dim "runtime is not running — start it with: ./demo.sh serve"
  fi
}

# Write the env-manifests for THIS run. The bundle is named by an `oci://` ref
# and pinned by digest — nothing is read from the local filesystem, so there is
# no absolute-path trap and nothing to download first.
#
# Only v1 carries the `updates` block — that is the subscription, and the only
# place it may live. `op updates publish` STRIPS `updates` from a plan target
# before signing: a signed plan that could re-point the channel it arrived on
# would be a self-perpetuating takeover primitive.
#
# `push_enabled: true` opts into the SSE stream. The runtime does not need a
# stream URL: it DERIVES one from `plan_endpoint` by swapping the trailing
# `/plan` for `/updates/stream`. `poll_interval_secs` is the hour-away fallback.
write_manifests() {
  python3 - "$OCI_BASE" "$V1_DIGEST" "$V2_DIGEST" "$ENV_ID" "$BUNDLE_ID" "$HERE" "$PLAN_ENDPOINT" "$POLL_INTERVAL" "$PUSH_ENABLED" <<'PY'
import json, sys
oci, v1d, v2d, env_id, bundle_id, here, endpoint, poll, push = sys.argv[1:10]

def manifest(version, digest, updates=None):
    doc = {"schema": "greentic.env-manifest.v1", "environment": {"id": env_id}}
    if updates:
        doc["updates"] = updates
    doc["bundles"] = [{"bundle_id": bundle_id,
                       "bundle_source_uri": "%s/%s:1" % (oci, version),
                       "bundle_digest": "sha256:" + digest}]
    with open("%s/manifests/%s.gen.json" % (here, version), "w") as fh:
        json.dump(doc, fh, indent=2)
        fh.write("\n")

manifest("v1", v1d, {"plan_endpoint": endpoint,
                     "on_notify": "apply",
                     "push_enabled": push == "true",
                     "poll_interval_secs": int(poll)})
manifest("v2", v2d)
PY
}

# ===========================================================================
cmd_run() {
  step "0. preflight"
  need curl; need tar; need python3
  need "$DEP" "cargo binstall greentic-deployer@1.1.16"
  version_at_least "$DEP" 1.1.16
  assert_clean_host

  # The PATH runtime is never used — but the swap hazard means we prove it.
  local path_start path_start_sha=""
  if path_start="$(command -v greentic-start 2>/dev/null)" && [ -n "$path_start" ]; then
    path_start_sha="$(sha256_of "$path_start")"
    dim "PATH greentic-start: $path_start (sha256:${path_start_sha:0:16}…) — must not change"
  fi

  cmd_fetch

  step "1. claim a namespace on the plan server"
  say "POST $SERVER/v1/demo/session"
  curl -fsS --retry 3 -X POST "$SERVER/v1/demo/session" -o "$HERE/.session.json" \
    || die "could not reach the plan server at $SERVER"
  local SERVER_ENV
  SERVER_ENV="$(python3 -c 'import json;print(json.load(open("'"$HERE"'/.session.json"))["env_id"])')"
  UPLOAD_TOKEN="$(python3 -c 'import json;print(json.load(open("'"$HERE"'/.session.json"))["upload_token"])')"
  PLAN_ENDPOINT="$(python3 -c 'import json;print(json.load(open("'"$HERE"'/.session.json"))["plan_endpoint"])')"
  ok "server namespace: $SERVER_ENV  (your local env stays \`$ENV_ID\`)"
  info "plan_endpoint=$PLAN_ENDPOINT"
  dim "an unguessable namespace with its own upload credential; it expires in 24h"
  dim "the credential authorises UPLOAD only — plan reads are anonymous"

  rm -rf "$HOME_DIR"; mkdir -p "$HOME_DIR" "$HERE/manifests"
  write_manifests
  trap cleanup EXIT

  # -------------------------------------------------------------------------
  step "2. create the environment and apply v1"
  say "op env init — creates the env, mints the operator key, seeds the trust root"
  op env init | python3 -c '
import json, sys
r = json.load(sys.stdin)["result"]
print("    outcome=%s   operator_key_id=%s" % (r["outcome"], r["trust_root"]["operator_key_id"]))'
  dim "that key_id is what every plan below is signed with — remember it"

  say "op env apply — deploy v1 AND subscribe to the cloud update channel"
  dim "v1 carries an \`updates\` block; the block IS the opt-in (deny-by-default)"
  # stdout is the JSON outcome, stderr the convergence plan; keep stderr on a
  # failure or `set -e` exits with nothing to show for it.
  op env apply --answers "$HERE/manifests/v1.gen.json" >/dev/null \
    || die "env apply failed (re-run without the redirect to see the plan)"
  ok "v1 is live:"
  show_live

  op updates config-show "$ENV_ID" | python3 -c '
import json, sys
r = json.load(sys.stdin)["result"]
print("    enabled=%s  on_update=%s  push_enabled=%s  poll_interval_secs=%s" % (
    str(r["enabled"]).lower(), r["on_update"], str(r.get("push_enabled", True)).lower(), r["poll_interval_secs"]))
print("    plan_endpoint=%s" % r["plan_endpoint"])
se = r.get("stream_endpoint")
print("    stream_endpoint=%s" % (se if se else "(derived: plan_endpoint with /plan → /updates/stream)"))'
  dim "the manifest wrote the channel — no \`config-set\`, no \`--enabled true\`"

  # -------------------------------------------------------------------------
  step "3. start the runtime (a COPY — it will overwrite its own binary)"
  local from_dir="$CACHE_DIR/x-$VER_FROM" from_bin
  from_bin="$(extract_binary "$CACHE_DIR/$(tarball_name "$VER_FROM")" "$from_dir")"
  [ -n "$from_bin" ] || die "no greentic-start inside the $VER_FROM tarball"
  rm -rf "$BIN_DIR"; mkdir -p "$BIN_DIR"
  cp "$from_bin" "$RUNTIME_BIN"; chmod +x "$RUNTIME_BIN"
  ok "running greentic-start $("$RUNTIME_BIN" --version | awk '{print $NF}') from $RUNTIME_BIN"
  dim "its current_exe() is $RUNTIME_BIN — that, and nothing else, is what the swap replaces"

  start_bg "$HERE/.runtime.log" env HOME="$HOME_DIR" "$RUNTIME_BIN" start --env "$ENV_ID" --no-browser
  local i
  for i in $(seq 1 60); do grep -q "revision ingress listening" "$HERE/.runtime.log" 2>/dev/null && break; sleep 0.5; done
  grep -q "revision ingress listening" "$HERE/.runtime.log" \
    || { tail -20 "$HERE/.runtime.log" >&2; die "the runtime did not come up"; }
  ok "serving v1"

  # Wait until the runtime has SUBSCRIBED to the push stream before publishing, so
  # the convergence timed in step 4 is the push delivering — not a reconnect, and
  # certainly not the hour-away poll. Connect catch-up would cover us even if we
  # published first (a fresh subscriber is handed the current head on connect),
  # but observing the subscription first makes the timing claim exact.
  local subscribed=""
  for i in $(seq 1 40); do
    grep -q "update-stream:.*subscribing to" "$HERE/.runtime.log" 2>/dev/null && { subscribed=1; break; }
    sleep 0.5
  done
  if [ -n "$subscribed" ]; then
    ok "subscribed to the push stream — the poll fallback is ${POLL_INTERVAL}s away:"
    grep "update-stream:.*subscribing to" "$HERE/.runtime.log" | tail -1 | sed 's/.*\(update-stream:.*\)/    \1/'
  else
    dim "did not observe the 'subscribing' log line; relying on connect catch-up + timing"
  fi

  # -------------------------------------------------------------------------
  step "4. publish the CONTENT update — pushed, not polled"
  say "op updates publish — read the next sequence off the server, sign in memory, upload"
  local before; before=$(live_digest)
  env GREENTIC_PLAN_UPLOAD_TOKEN="$UPLOAD_TOKEN" HOME="$HOME_DIR" "$DEP" \
    op updates publish "$ENV_ID" --target-file "$HERE/manifests/v2.gen.json" \
    | python3 -c '
import json, sys
r = json.load(sys.stdin)["result"]
print("    plan_id=%s  sequence=%s  key_id=%s" % (r["plan_id"], r["sequence"], r["key_id"]))
print("    status=%s  plan_sha256=%s…" % (r["status"], r["plan_sha256"][:16]))'
  ok "the signing key never left this machine; the server stored bytes it cannot forge"

  say "the server pushed a one-line hint down the stream; waiting for fetch → DSSE-verify → apply…"
  dim "the poll fallback is ${POLL_INTERVAL}s away, so converging now can only be the push"
  local moved="" t0=$SECONDS
  for i in $(seq 1 "$PUSH_BUDGET"); do
    [ -n "$(live_digest)" ] && [ "$(live_digest)" != "$before" ] && { moved=1; break; }
    sleep 1
  done
  local elapsed=$((SECONDS - t0))
  [ -n "$moved" ] || { tail -25 "$HERE/.runtime.log" >&2; die "traffic never moved within ${PUSH_BUDGET}s (see .runtime.log)"; }
  ok "v2 is live in ${elapsed}s — telegram joined webchat, with no restart:"
  show_live
  dim "${elapsed}s to converge vs a ${POLL_INTERVAL}s poll interval — the push stream delivered it, not a poll"
  local after_content; after_content=$(live_digest)

  # -------------------------------------------------------------------------
  step "5. publish the BINARY update — same channel, same key, same server"
  local to_dir="$CACHE_DIR/x-$VER_TO" to_bin inner_sha
  to_bin="$(extract_binary "$CACHE_DIR/$(tarball_name "$VER_TO")" "$to_dir")"
  [ -n "$to_bin" ] || die "no greentic-start inside the $VER_TO tarball"
  inner_sha="$(sha256_of "$to_bin")"
  local source_url="$START_REL/v$VER_TO/$(tarball_name "$VER_TO")"
  info "target   greentic-start $VER_TO  sha256:${inner_sha:0:16}…"
  info "source   $source_url"
  dim "the plan store does NOT host artifacts. It serves signed metadata; the bytes"
  dim "live on GitHub's CDN. The digest inside the signed plan is the only thing"
  dim "binding them — that is the TUF split, and why the transport does not matter."

  say "op updates publish --binary — content target unchanged, binary pinned by digest"
  env GREENTIC_PLAN_UPLOAD_TOKEN="$UPLOAD_TOKEN" HOME="$HOME_DIR" "$DEP" \
    op updates publish "$ENV_ID" \
      --target-file "$HERE/manifests/v2.gen.json" \
      --binary "name=greentic-start,version=$VER_TO,target=$TARGET,digest=sha256:$inner_sha,source=$source_url" \
    | python3 -c '
import json, sys
r = json.load(sys.stdin)["result"]
print("    plan_id=%s  sequence=%s  key_id=%s" % (r["plan_id"], r["sequence"], r["key_id"]))'

  say "the plan is pushed too; waiting for the runtime to fetch the archive → verify the digest → swap itself…"
  dim "this one also downloads a tarball from GitHub's CDN, so it takes a little longer than the content update"
  local swapped=""
  for i in $(seq 1 $((PUSH_BUDGET + 120))); do
    [ -f "$HOME_DIR/.greentic/environments/$ENV_ID/binary-update-pending.json" ] && { swapped=1; break; }
    sleep 1
  done
  local marker="$HOME_DIR/.greentic/environments/$ENV_ID/binary-update-pending.json"
  [ -n "$swapped" ] || { tail -30 "$HERE/.runtime.log" >&2; die "the binary was never swapped (see .runtime.log)"; }

  ok "swapped:"
  python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
print("    %s -> %s   restart_required" % (m["from_version"], m["to_version"]))' "$marker"

  local disk_sha; disk_sha="$(sha256_of "$RUNTIME_BIN")"
  [ "$disk_sha" = "$inner_sha" ] \
    || die "the binary on disk is not the one the plan pinned
    pinned  sha256:$inner_sha
    on disk sha256:$disk_sha"
  ok "on-disk binary == the digest pinned in the signed plan"
  [ -f "$RUNTIME_BIN.prev" ] && ok "the original is preserved at $(basename "$RUNTIME_BIN").prev — the swap is reversible"

  # -------------------------------------------------------------------------
  step "what the run proved"
  # A binary cannot converge hot: a process may not replace itself in flight.
  # So the swap only STAGES, and traffic must not have moved.
  [ "$(live_digest)" = "$after_content" ] \
    || die "the live content changed during a binary update — it must not"
  ok "traffic never moved during the binary update — content digest unchanged"

  # The whole point of the ./bin copy: your PATH binary is untouched.
  if [ -n "$path_start_sha" ]; then
    [ "$(sha256_of "$path_start")" = "$path_start_sha" ] \
      || die "the greentic-start on your PATH was modified — this must never happen"
    ok "the greentic-start on your PATH is byte-for-byte unchanged"
  fi

  # The still-running process serves the OLD code until restarted. That is the
  # honest contract: activation is explicit.
  info ""
  info "the process is still serving $VER_FROM — a swap stages, it does not activate:"
  dim "  $ curl -si localhost:$RUNTIME_PORT/healthz | grep -i restart-required"
  curl -si "localhost:$RUNTIME_PORT/healthz" 2>/dev/null | grep -i 'restart-required' | sed 's/^/    /' || true

  printf '\n%s\n' "${GRN}${BOLD}✓ content converged hot; the binary staged itself — both PUSHED from a server on the public internet.${Z}"
  info "two plans, sequence 1 → 2, both signed by the key \`op env init\` minted here."
  info "each converged in seconds against an hour-long poll interval — only the push stream explains that."
  info "the server never held a key. The runtime never trusted the server — only the signature."
  info "state lives under $HOME_DIR; your real ~/.greentic was never touched."
  info ""
  info "prove it the other way:  PUSH_ENABLED=false ./demo.sh no-push"
  dim "  same publish, push turned off → v2 must NOT converge inside ${PUSH_BUDGET}s (the poll is an hour away)"
}

# ===========================================================================
# no-push — the negative control.
#
# Everything the content half of `run` does, but with `push_enabled: false` in
# the manifest. The runtime never opens the stream, so the published v2 has only
# the hour-away poll to reach it — and must therefore NOT converge inside the
# push budget. A demo whose success is push must be able to fail without it; this
# is that failure, asserted.
# ===========================================================================
cmd_no_push() {
  PUSH_ENABLED=false
  step "0. preflight (push DISABLED — negative control)"
  need curl; need tar; need python3
  need "$DEP" "cargo binstall greentic-deployer@1.1.16"
  version_at_least "$DEP" 1.1.16
  assert_clean_host
  cmd_fetch

  step "1. claim a namespace on the plan server"
  curl -fsS --retry 3 -X POST "$SERVER/v1/demo/session" -o "$HERE/.session.json" \
    || die "could not reach the plan server at $SERVER"
  UPLOAD_TOKEN="$(python3 -c 'import json;print(json.load(open("'"$HERE"'/.session.json"))["upload_token"])')"
  PLAN_ENDPOINT="$(python3 -c 'import json;print(json.load(open("'"$HERE"'/.session.json"))["plan_endpoint"])')"
  ok "server namespace: $(session env_id)  (push_enabled=false)"

  rm -rf "$HOME_DIR"; mkdir -p "$HOME_DIR" "$HERE/manifests"
  write_manifests
  trap cleanup EXIT

  step "2. create the environment and apply v1 (channel enabled, push OFF)"
  op env init >/dev/null
  op env apply --answers "$HERE/manifests/v1.gen.json" >/dev/null || die "env apply failed"
  op updates config-show "$ENV_ID" | python3 -c '
import json, sys
r = json.load(sys.stdin)["result"]
print("    enabled=%s  push_enabled=%s  poll_interval_secs=%s" % (
    str(r["enabled"]).lower(), str(r.get("push_enabled", True)).lower(), r["poll_interval_secs"]))'

  step "3. start the runtime"
  local from_bin
  from_bin="$(extract_binary "$CACHE_DIR/$(tarball_name "$VER_FROM")" "$CACHE_DIR/x-$VER_FROM")"
  [ -n "$from_bin" ] || die "no greentic-start inside the $VER_FROM tarball"
  rm -rf "$BIN_DIR"; mkdir -p "$BIN_DIR"; cp "$from_bin" "$RUNTIME_BIN"; chmod +x "$RUNTIME_BIN"
  start_bg "$HERE/.runtime.log" env HOME="$HOME_DIR" "$RUNTIME_BIN" start --env "$ENV_ID" --no-browser
  local i
  for i in $(seq 1 60); do grep -q "revision ingress listening" "$HERE/.runtime.log" 2>/dev/null && break; sleep 0.5; done
  grep -q "revision ingress listening" "$HERE/.runtime.log" \
    || { tail -20 "$HERE/.runtime.log" >&2; die "the runtime did not come up"; }
  # With push off the runtime must not subscribe. Give it the same grace the
  # positive run gives the subscribe line, then assert it never appeared.
  sleep 5
  if grep -q "update-stream:.*subscribing to" "$HERE/.runtime.log" 2>/dev/null; then
    die "the runtime subscribed to the stream with push_enabled=false — the opt-out is not being honoured"
  fi
  ok "runtime is up and did NOT open a push stream (push_enabled=false)"

  step "4. publish v2 — and prove it does NOT converge without push"
  local before; before=$(live_digest)
  env GREENTIC_PLAN_UPLOAD_TOKEN="$UPLOAD_TOKEN" HOME="$HOME_DIR" "$DEP" \
    op updates publish "$ENV_ID" --target-file "$HERE/manifests/v2.gen.json" >/dev/null \
    || die "publish failed"
  ok "v2 published (sequence 1). The poll is ${POLL_INTERVAL}s away and there is no stream."
  say "watching for ${PUSH_BUDGET}s — with push off, traffic must stay on v1…"
  local moved=""
  for i in $(seq 1 "$PUSH_BUDGET"); do
    [ -n "$(live_digest)" ] && [ "$(live_digest)" != "$before" ] && { moved=1; break; }
    sleep 1
  done
  if [ -n "$moved" ]; then
    die "v2 converged inside ${PUSH_BUDGET}s with push disabled — the positive run proves nothing
    (something other than the push stream is delivering updates this fast)"
  fi
  printf '\n%s\n' "${GRN}${BOLD}✓ negative control held: v2 did NOT converge in ${PUSH_BUDGET}s without push.${Z}"
  info "the poll would still get there — in ${POLL_INTERVAL}s. The push stream is what makes it seconds."
  info "so a passing \`./demo.sh run\` is push doing the work, not a lucky poll."
}

case "${1:-run}" in
  run)     cmd_run ;;
  no-push) cmd_no_push ;;
  env)     cmd_env ;;
  serve)   cmd_serve ;;
  switch)  shift; cmd_switch "${1:-}" ;;
  status)  cmd_status ;;
  fetch)   cmd_fetch ;;
  clean)   cmd_clean ;;
  *)       die "usage: $0 [run|no-push|env|serve|switch v1|v2|status|fetch|clean]

  run              the whole story, unattended (content + binary update, PUSHED)
  no-push          the negative control: push off → v2 must NOT converge in time

  env              create the environment, apply v1, subscribe to the channel
  serve            run the runtime in the foreground (keep the terminal open)
  switch v1|v2     publish that version to the plan server
  status           what your runtime serves vs what the server holds

  fetch            download + verify the release artifacts only
  clean            remove home/, bin/ and logs (keeps the caches)" ;;
esac
