#!/bin/zsh
# Phase 0 helper: post a JSON payload file to a webhook route from Config/secrets.local.json.
# Usage: Tools/post.sh <payload.json> [route=test]
# Prints only http status + message id. Never prints the webhook URL.
set -euo pipefail
cd "$(dirname "$0")/.."
payload="$1"; route="${2:-test}"
wh=$(jq -r --arg r "$route" '.discordWebhooks[$r] // empty' Config/secrets.local.json)
[[ -n "$wh" ]] || { echo "no webhook for route '$route'"; exit 1; }
jq -e '.allowed_mentions' "$payload" >/dev/null || { echo "payload must set allowed_mentions (rule 9)"; exit 1; }
resp=$(curl -sS -w '\n%{http_code}' -H 'Content-Type: application/json' --data @"$payload" "$wh?wait=true")
code=${resp##*$'\n'}; body=${resp%$'\n'*}
echo "http=$code id=$(print -r -- "$body" | jq -r '.id // .message // "?"')"
