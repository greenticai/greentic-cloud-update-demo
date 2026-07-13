#!/usr/bin/env bash
# ===========================================================================
# build-bundles.sh — MAINTAINER ONLY. Rebuild the two demo bundles.
#
# Running the demo does NOT need this: ./demo.sh downloads prebuilt bundles from
# the release and verifies them against their .sha256 sidecars. This script is
# how those assets are produced, and it needs `gtc` plus the two sample packs.
#
# v1 = webchat only            (the version we update FROM)
# v2 = webchat + telegram      (the version we update TO)
#
# The two must differ, or there is nothing to converge to — asserted below.
#
# Publishing the result — the demo pulls bundles from GHCR by `oci://` ref, so
# nothing is downloaded to a user's machine and no release asset is involved:
#
#   ./build-bundles.sh
#   gh auth token | oras login ghcr.io -u <you> --password-stdin
#   cd build
#   for v in v1 v2; do
#     oras push ghcr.io/greenticai/greentic-cloud-update-demo/$v:1 \
#       --artifact-type application/vnd.unknown.artifact.v1 \
#       --annotation "org.opencontainers.image.source=https://github.com/greenticai/greentic-cloud-update-demo" \
#       $v.gtbundle:application/octet-stream
#   done
#
# A NEW package is private by default and GitHub has no API to change that, so
# flip each one to Public once, by hand, at
#   https://github.com/orgs/greenticai/packages
# Then `op env apply` can pull it anonymously — no login, no Docker.
#
# The layer digest oras prints for each push IS the .gtbundle's sha256; paste it
# into V1_DIGEST / V2_DIGEST in demo.sh and BUNDLE in docs/index.html, which is
# what the signed plan pins.
# ===========================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GTC="${GTC:-gtc}"
BUILD_DIR="$HERE/build"
BUNDLE_ID="updatedemo"

# The sample packs. Override PACK_DIR if your checkout differs.
PACK_DIR="${PACK_DIR:-$(cd "$HERE/.." && pwd)/webchat-gui-default/packs}"
APP_PACK="$PACK_DIR/app-webchat-bot.gtpack"
TG_PACK="$PACK_DIR/messaging-telegram.gtpack"

die() { printf '✗ %s\n' "$*" >&2; exit 1; }

command -v "$GTC" >/dev/null || die "gtc not on PATH (cargo binstall gtc)"
[ -f "$APP_PACK" ] || die "missing sample pack: $APP_PACK"
[ -f "$TG_PACK" ]  || die "missing sample pack: $TG_PACK"

build_bundle() { # <name> <pack>...
  local name="$1"; shift
  local root="$BUILD_DIR/ws-$name"
  rm -rf "$root"; mkdir -p "$root/packs"
  "$GTC" dev bundle init "$root" --bundle-name "$BUNDLE_ID" --bundle-id "$BUNDLE_ID" --execute >/dev/null
  local p
  for p in "$@"; do
    cp "$p" "$root/packs/"
    "$GTC" dev bundle add app-pack "$p" --root "$root" --execute >/dev/null
  done
  "$GTC" dev bundle build --root "$root" --output "$BUILD_DIR/$name.gtbundle" >/dev/null
  printf '  ✓ %s.gtbundle  sha256:%s…\n' \
    "$name" "$(sha256sum "$BUILD_DIR/$name.gtbundle" | cut -c1-16)"
}

mkdir -p "$BUILD_DIR"
echo "▸ v1 — webchat only"
build_bundle v1 "$APP_PACK"
echo "▸ v2 — webchat + telegram"
build_bundle v2 "$APP_PACK" "$TG_PACK"

[ "$(sha256sum "$BUILD_DIR/v1.gtbundle" | cut -d' ' -f1)" \
  != "$(sha256sum "$BUILD_DIR/v2.gtbundle" | cut -d' ' -f1)" ] \
  || die "v1 and v2 have the same digest — there would be nothing to update to"
echo "✓ built"
