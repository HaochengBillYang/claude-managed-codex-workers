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

mkdir -p "$(dirname "$OUT")" || exit 1
lock=$OUT.lock
owner=$lock/$$
tmp=
cleanup() {
  if [ -n "$tmp" ]; then rm -f "$tmp"; fi
  if rmdir "$owner" 2>/dev/null; then rmdir "$lock" 2>/dev/null || :; fi
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM
while :; do
  if mkdir "$lock" 2>/dev/null; then
    # Another contender may reclaim the directory before we publish our PID.
    # Query only when our PID is the sole published claim.
    if mkdir "$owner" 2>/dev/null; then
      set -- "$lock"/*
      if [ "$#" -eq 1 ] && [ "$1" = "$owner" ]; then break; fi
      rmdir "$owner" || exit 1
    fi
  elif [ ! -d "$lock" ]; then
    exit 1
  fi
  for entry in "$lock"/*; do
    [ -e "$entry" ] || continue
    [ -d "$entry" ] || exit 1
    pid=${entry##*/}
    case $pid in ''|0|*[!0-9]*) exit 1 ;; esac
    if kill -0 "$pid" 2>/dev/null || ps -p "$pid" >/dev/null 2>&1; then exit 0; fi
    rmdir "$entry" 2>/dev/null || :
  done
  # rmdir only succeeds if no owner has published its PID.
  rmdir "$lock" 2>/dev/null || :
done

summary=$({
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-usage","version":"1"}}}'
  sleep 1
  printf '%s\n' '{"jsonrpc":"2.0","method":"initialized"}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read"}'
  sleep "${CODEX_RESETS_WAIT:-6}"
} | "$CODEX" app-server 2>/dev/null | jq -nRc '
  first(inputs | fromjson? | objects | select(.id == 2))
  | .result.rateLimitResetCredits // empty
' 2>/dev/null)

[ -z "$summary" ] && exit 1   # no answer (offline, logged out, older Codex): keep the old cache

tmp=$(mktemp "$OUT.XXXXXX") || exit 1
jq -c --argjson now "$(date +%s)" '
  {available: .availableCount,
   credits: [(.credits // [])[] | select(.status=="available") | {title, expiresAt, status}],
   updated: $now, source: "app-server"}
  | .expires = ([.credits[].expiresAt | select(. != null)] | min
                | if . == null then null else strflocaltime("%Y-%m-%d") end)
' <<<"$summary" > "$tmp" && mv -f "$tmp" "$OUT"
