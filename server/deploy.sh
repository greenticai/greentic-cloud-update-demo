#!/usr/bin/env bash
# Deploy the plan store to Cloudflare Workers.
#
#   ./deploy.sh          typecheck, test, deploy
#   ./deploy.sh --check  typecheck + test only
#
# Credentials come from `.cloudflare.env` (see .cloudflare.env.example). They are
# exported into the process environment for wrangler and never written into any
# file wrangler reads as Worker secrets.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

CREDS="$HERE/.cloudflare.env"
[ -f "$CREDS" ] || {
  echo "missing $CREDS — copy .cloudflare.env.example and fill it in" >&2
  exit 1
}
set -a
# shellcheck disable=SC1090
. "$CREDS"
set +a

: "${CLOUDFLARE_API_TOKEN:?not set in .cloudflare.env}"
: "${CLOUDFLARE_ACCOUNT_ID:?not set in .cloudflare.env}"

[ -d node_modules ] || npm install

echo "▸ typecheck"
npx tsc --noEmit

echo "▸ test (workerd + real Durable Object storage)"
npx vitest run

if [ "${1:-}" = "--check" ]; then
  echo "✓ checks passed (not deployed)"
  exit 0
fi

echo "▸ deploy"
npx wrangler deploy
