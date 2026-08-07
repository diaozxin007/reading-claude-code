#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITEMAP_PATH="${SITEMAP_PATH:-${SCRIPT_DIR}/sitemap.xml}"
SITE_URL="${SITE_URL:-https://readingclaude.club}"
INDEXNOW_ENDPOINT="${INDEXNOW_ENDPOINT:-https://www.bing.com/indexnow}"

usage() {
  cat <<'EOF'
Usage: scripts/submit-indexnow.sh [--dry-run]

Extract every <loc> URL from the sitemap and submit it to IndexNow.

Environment variables:
  INDEXNOW_KEY       IndexNow key. By default it is read from scripts/<key>.txt.
  SITEMAP_PATH       Sitemap path. Defaults to scripts/sitemap.xml.
  SITE_URL           Public site root used for keyLocation.
  INDEXNOW_ENDPOINT  API endpoint. Defaults to https://www.bing.com/indexnow.
EOF
}

DRY_RUN=false
case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=true ;;
  -h|--help) usage; exit 0 ;;
  *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

for command in curl jq; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Missing required command: $command" >&2
    exit 1
  fi
done

if [[ ! -f "$SITEMAP_PATH" ]]; then
  echo "Sitemap not found: $SITEMAP_PATH" >&2
  exit 1
fi

if [[ -z "${INDEXNOW_KEY:-}" ]]; then
  shopt -s nullglob
  txt_files=("${SCRIPT_DIR}"/*.txt)
  shopt -u nullglob

  key_files=()
  for file in "${txt_files[@]}"; do
    candidate="$(tr -d '[:space:]' < "$file")"
    if [[ "$(basename "$file")" == "${candidate}.txt" && "$candidate" =~ ^[A-Za-z0-9_-]{8,128}$ ]]; then
      key_files+=("$file")
    fi
  done

  if [[ ${#key_files[@]} -ne 1 ]]; then
    echo "Set INDEXNOW_KEY, or keep exactly one valid <key>.txt file in scripts/." >&2
    exit 1
  fi

  INDEXNOW_KEY="$(tr -d '[:space:]' < "${key_files[0]}")"
fi

if [[ ! "$INDEXNOW_KEY" =~ ^[A-Za-z0-9_-]{8,128}$ ]]; then
  echo "INDEXNOW_KEY has an invalid format." >&2
  exit 1
fi

HOST="$(printf '%s' "$SITE_URL" | sed -E 's#^https?://([^/]+).*$#\1#')"
KEY_LOCATION="${SITE_URL%/}/${INDEXNOW_KEY}.txt"

URL_JSON="$(
  sed -nE 's#.*<loc>([^<]+)</loc>.*#\1#p' "$SITEMAP_PATH" |
    jq -R -s -c 'split("\n") | map(select(length > 0)) | unique'
)"
URL_COUNT="$(jq 'length' <<<"$URL_JSON")"

if [[ "$URL_COUNT" -eq 0 ]]; then
  echo "No <loc> URLs found in $SITEMAP_PATH" >&2
  exit 1
fi

# IndexNow requires every submitted URL to belong to the declared host.
# Fail loudly rather than accidentally submitting a legacy mirror domain.
SITE_ROOT="${SITE_URL%/}"
MISMATCHED_URLS="$(
  jq -r --arg root "$SITE_ROOT" \
    '.[] | select(. != $root and (startswith($root + "/") | not))' \
    <<<"$URL_JSON"
)"
if [[ -n "$MISMATCHED_URLS" ]]; then
  echo "Sitemap contains URLs outside SITE_URL ($SITE_ROOT):" >&2
  printf '%s\n' "$MISMATCHED_URLS" >&2
  exit 1
fi

PAYLOAD="$(
  jq -n -c \
    --arg host "$HOST" \
    --arg key "$INDEXNOW_KEY" \
    --arg keyLocation "$KEY_LOCATION" \
    --argjson urlList "$URL_JSON" \
    '{host: $host, key: $key, keyLocation: $keyLocation, urlList: $urlList}'
)"

echo "IndexNow: prepared $URL_COUNT URLs from $SITEMAP_PATH" >&2

if [[ "$DRY_RUN" == true ]]; then
  jq . <<<"$PAYLOAD"
  exit 0
fi

response_file="$(mktemp)"
trap 'rm -f "$response_file"' EXIT

HTTP_CODE="$(
  curl --silent --show-error --location \
    --output "$response_file" \
    --write-out '%{http_code}' \
    --request POST "$INDEXNOW_ENDPOINT" \
    --header 'Content-Type: application/json; charset=utf-8' \
    --data "$PAYLOAD"
)"

echo "IndexNow response: HTTP $HTTP_CODE"
if [[ -s "$response_file" ]]; then
  cat "$response_file"
  echo
fi

case "$HTTP_CODE" in
  200|202) echo "IndexNow accepted $URL_COUNT URLs." ;;
  *) echo "IndexNow rejected the submission." >&2; exit 1 ;;
esac
