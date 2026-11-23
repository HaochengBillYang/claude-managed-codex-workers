#!/bin/bash
# Reads banked Codex rate-limit resets from the Codex app-server (read-only
# `account/rateLimits/read`) and caches them in $CODEX_RESETS_FILE
# (default ~/.claude/codex-resets.json). Never redeems anything.
# Output file: {"available":N,"expires":"YYYY-MM-DD"|null,"credits":[{title,expiresAt,status}],
#               "updated":<epoch>,"source":"app-server"}
set -u
OUT=${CODEX_RESETS_FILE:-$HOME/.claude/codex-resets.json}
APP_CODEX=/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex
if [ -n "${CODEX_BIN:-}" ]; then CODEX=$CODEX_BIN
elif [ -x "$APP_CODEX" ]; then CODEX=$APP_CODEX
else CODEX=$(command -v codex || echo codex)
fi

resp=$({
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-usage","version":"1"}}}'
  sleep 1
  printf '%s\n' '{"jsonrpc":"2.0","method":"initialized"}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read"}'
  sleep "${CODEX_RESETS_WAIT:-6}"
} | "$CODEX" app-server 2>/dev/null | grep -m1 '^{"id":2')

summary=$(jq -c '.result.rateLimitResetCredits // empty' <<<"$resp" 2>/dev/null)
[ -z "$summary" ] && exit 1   # no answer (offline, logged out, older Codex): keep the old cache

mkdir -p "$(dirname "$OUT")"
tmp=$(mktemp "$OUT.XXXXXX") || exit 1
jq -c --argjson now "$(date +%s)" '
  {available: .availableCount,
   credits: [(.credits // [])[] | select(.status=="available") | {title, expiresAt, status}],
   updated: $now, source: "app-server"}
  | .expires = ([.credits[].expiresAt | select(. != null)] | min
                | if . == null then null else strflocaltime("%Y-%m-%d") end)
' <<<"$summary" > "$tmp" && mv -f "$tmp" "$OUT"
