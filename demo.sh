#!/usr/bin/env bash
# ===========================================================================
# cloud-update-demo — a running environment updates itself, and then its own
#                     binary, from a plan server on the public internet.
#
# Anyone can run this. There is nothing to build and no account to create:
#
#   greentic-deployer >= 1.1.10   cargo binstall greentic-deployer@1.1.10
#   greentic-start    >= 1.1.9    (fetched automatically — see below)
#   curl, tar, python3, sha256sum
#
# The plan server is already running at $SERVER. It stores DSSE-signed plans and
# serves them anonymously. It holds no signing key and cannot forge an update.
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
#   1. CONTENT   v1 (webchat) → v2 (webchat + telegram). Converges hot: the
#                runtime snapshots, applies, verifies, and moves traffic with no
#                restart. Rolls back by itself on failure.
#
#   2. BINARY    greentic-start 1.1.9 → 1.1.11. The plan pins the inner binary's
#                sha256; the runtime verifies the bytes BEFORE touching the
#                filesystem, renames the new binary over its own current_exe()
#                keeping a .prev, and starts answering restart-required. A
#                process cannot replace itself in flight, so this one STAGES —
#                traffic never moves, and we assert the live content is unchanged.
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
#   ./demo.sh          run it
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
DEP="${DEP:-greentic-deployer}"        # >= 1.1.10 — `op updates publish`
VER_FROM="${VER_FROM:-1.1.9}"          # first release with the binary receiver
VER_TO="${VER_TO:-1.1.11}"             # strictly newer: the runtime refuses <=
START_REL="https://github.com/greenticai/greentic-start/releases/download"

# --- content: two versions of one bundle ----------------------------------
# Prebuilt and published as release assets, so running this needs no toolchain.
# Maintainers rebuild them with ./build-bundles.sh (needs gtc + the sample packs).
BUNDLE_REL="${BUNDLE_REL:-https://github.com/greenticai/greentic-cloud-update-demo/releases/download/content-v1}"

# --- demo-local state (never touches your real ~/.greentic) ---------------
HOME_DIR="$HERE/home"                  # becomes $HOME for every command below
BUILD_DIR="$HERE/build"                # v1/v2 bundles
CACHE_DIR="$HERE/release-cache"        # downloaded runtime tarballs
BIN_DIR="$HERE/bin"                    # the runtime COPY that the swap replaces
RUNTIME_BIN="$BIN_DIR/greentic-start"
BUNDLE_ID="updatedemo"
RUNTIME_PORT="${RUNTIME_PORT:-8080}"
POLL_SECS=60                           # MIN_POLL_INTERVAL_SECS — the floor

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
# The receiver swaps current_exe(). Refuse to race a stray runtime.
port_busy() { command -v ss >/dev/null 2>&1 && ss -ltn "sport = :$1" 2>/dev/null | tail -n +2 | grep -q .; }

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
  ( cd "$dir" && sha256sum -c "$f.sha256" >/dev/null 2>&1 ) \
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
  need curl; need sha256sum; need tar; need python3
  step "fetch the release artifacts ($TARGET)"
  fetch_verified "$START_REL/v$VER_FROM" "$(tarball_name "$VER_FROM")" "$CACHE_DIR"
  fetch_verified "$START_REL/v$VER_TO"   "$(tarball_name "$VER_TO")"   "$CACHE_DIR"
  # Bundles: only fetched when not built locally (see ./build-bundles.sh).
  if [ ! -f "$BUILD_DIR/v1.gtbundle" ] || [ ! -f "$BUILD_DIR/v2.gtbundle" ]; then
    fetch_verified "$BUNDLE_REL" v1.gtbundle "$BUILD_DIR"
    fetch_verified "$BUNDLE_REL" v2.gtbundle "$BUILD_DIR"
  else
    ok "v1.gtbundle, v2.gtbundle (built locally)"
  fi
}

cmd_clean() {
  rm -rf "$HOME_DIR" "$BIN_DIR"
  rm -f "$HERE"/.runtime.log "$HERE"/.session.json
  ok "removed home/, bin/ and logs (caches kept)"
}

# Write the env-manifests for THIS run. `bundle_path` must be absolute: a
# relative path resolves against $HOME, not the working directory. Bundles are
# not byte-deterministic across builds, so digests are recomputed, never fixed.
#
# Only v1 carries the `updates` block — that is the subscription, and the only
# place it may live. `op updates publish` STRIPS `updates` from a plan target
# before signing: a signed plan that could re-point the channel it arrived on
# would be a self-perpetuating takeover primitive.
write_manifests() {
  python3 - "$BUILD_DIR" "$ENV_ID" "$BUNDLE_ID" "$HERE" "$PLAN_ENDPOINT" "$POLL_SECS" <<'PY'
import hashlib, json, sys
build, env_id, bundle_id, here, endpoint, poll = sys.argv[1:7]

def manifest(version, updates=None):
    path = "%s/%s.gtbundle" % (build, version)
    digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
    doc = {"schema": "greentic.env-manifest.v1", "environment": {"id": env_id}}
    if updates:
        doc["updates"] = updates
    doc["bundles"] = [{"bundle_id": bundle_id,
                       "bundle_path": path,
                       "bundle_digest": "sha256:" + digest}]
    with open("%s/manifests/%s.gen.json" % (here, version), "w") as fh:
        json.dump(doc, fh, indent=2)
        fh.write("\n")

manifest("v1", {"plan_endpoint": endpoint,
                "on_notify": "apply",
                "poll_interval_secs": int(poll)})
manifest("v2")
PY
}

# ===========================================================================
cmd_run() {
  step "0. preflight"
  need curl; need tar; need python3; need sha256sum
  need "$DEP" "cargo binstall greentic-deployer@1.1.10"
  version_at_least "$DEP" 1.1.10
  assert_clean_host

  # The PATH runtime is never used — but the swap hazard means we prove it.
  local path_start path_start_sha=""
  if path_start="$(command -v greentic-start 2>/dev/null)" && [ -n "$path_start" ]; then
    path_start_sha="$(sha256sum "$path_start" | cut -d' ' -f1)"
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
print("    enabled=%s  on_update=%s  poll_interval_secs=%s" % (str(r["enabled"]).lower(), r["on_update"], r["poll_interval_secs"]))
print("    plan_endpoint=%s" % r["plan_endpoint"])'
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
  ok "serving v1; the poll loop is polling the cloud"

  # -------------------------------------------------------------------------
  step "4. publish the CONTENT update — one command"
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

  say "waiting for the runtime to fetch → DSSE-verify → stage → apply…"
  dim "poll interval ${POLL_SECS}s; nothing was pushed at the runtime"
  local moved=""
  for i in $(seq 1 $((POLL_SECS * 2 + 60))); do
    [ -n "$(live_digest)" ] && [ "$(live_digest)" != "$before" ] && { moved=1; break; }
    sleep 1
  done
  [ -n "$moved" ] || { tail -25 "$HERE/.runtime.log" >&2; die "traffic never moved (see .runtime.log)"; }
  ok "v2 is live — telegram joined webchat, with no restart:"
  show_live
  local after_content; after_content=$(live_digest)

  # -------------------------------------------------------------------------
  step "5. publish the BINARY update — same channel, same key, same server"
  local to_dir="$CACHE_DIR/x-$VER_TO" to_bin inner_sha
  to_bin="$(extract_binary "$CACHE_DIR/$(tarball_name "$VER_TO")" "$to_dir")"
  [ -n "$to_bin" ] || die "no greentic-start inside the $VER_TO tarball"
  inner_sha="$(sha256sum "$to_bin" | cut -d' ' -f1)"
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

  say "waiting for the runtime to fetch the archive → verify the digest → swap itself…"
  local swapped=""
  for i in $(seq 1 $((POLL_SECS * 2 + 120))); do
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

  local disk_sha; disk_sha="$(sha256sum "$RUNTIME_BIN" | cut -d' ' -f1)"
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
    [ "$(sha256sum "$path_start" | cut -d' ' -f1)" = "$path_start_sha" ] \
      || die "the greentic-start on your PATH was modified — this must never happen"
    ok "the greentic-start on your PATH is byte-for-byte unchanged"
  fi

  # The still-running process serves the OLD code until restarted. That is the
  # honest contract: activation is explicit.
  info ""
  info "the process is still serving $VER_FROM — a swap stages, it does not activate:"
  dim "  $ curl -si localhost:$RUNTIME_PORT/healthz | grep -i restart-required"
  curl -si "localhost:$RUNTIME_PORT/healthz" 2>/dev/null | grep -i 'restart-required' | sed 's/^/    /' || true

  printf '\n%s\n' "${GRN}${BOLD}✓ content converged hot; the binary staged itself. Both from a server on the public internet.${Z}"
  info "two plans, sequence 1 → 2, both signed by the key \`op env init\` minted here."
  info "the server never held a key. The runtime never trusted the server — only the signature."
  info "state lives under $HOME_DIR; your real ~/.greentic was never touched."
}

case "${1:-run}" in
  run)   cmd_run ;;
  fetch) cmd_fetch ;;
  clean) cmd_clean ;;
  *)     die "usage: $0 [run|fetch|clean]" ;;
esac
