#!/usr/bin/env bash
# Publish docs/ (the guide + the publishing console) to Cloudflare Pages.
#
# A DIRECTORY deploy, not a single file: index.html imports ./publisher.js as a
# real ES module, so the page and the code it runs stay one source of truth
# rather than a copy pasted into a <script> tag.
#
# The same directory is what GitHub Pages serves from `main`/docs, so both hosts
# show identical content.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS="${CREDS:-$HOME/.claude/skills/html-deploy/.env}"

[ -f "$CREDS" ] || { echo "missing Cloudflare Pages credentials: $CREDS" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
. "$CREDS"
set +a
: "${CLOUDFLARE_API_TOKEN:?}"
: "${CLOUDFLARE_ACCOUNT_ID:?}"

npx --yes wrangler@latest pages deploy "$HERE/docs" \
  --project-name=cloud-update-demo \
  --branch=main \
  --commit-dirty=true
