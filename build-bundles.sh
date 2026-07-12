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
# Publishing the result:
#   ./build-bundles.sh
#   cd build && sha256sum v1.gtbundle > v1.gtbundle.sha256 \
#            && sha256sum v2.gtbundle > v2.gtbundle.sha256
#   gh release upload content-v1 v1.gtbundle v1.gtbundle.sha256 \
#                                v2.gtbundle v2.gtbundle.sha256
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
