#!/bin/bash
# Prints Codex rate-limit status from the newest session log that has it.
# Last line is machine-readable: STATUS=OK|THROTTLE|BLOCKED|UNKNOWN [UNTIL=..] [RESETS=n] [ADVICE=..] [REASON=..]
# Banked resets (not exposed by the Codex CLI) are read from $CODEX_RESETS_FILE
# (default ~/.claude/codex-resets.json): {"available": 2, "expires": "2026-12-01", "updated": "2026-11-21"}
set -u
unknown() {
  printf '%s\n' "$1" 'STATUS=UNKNOWN'
  exit 0
}

# Portable across macOS (BSD date/stat) and Windows Git Bash / Linux (GNU date/stat).
JQ_BIN=$(command -v jq || true)
if [ -z "$JQ_BIN" ] && [ -n "${LOCALAPPDATA:-}" ]; then   # winget install jqlang.jq (its Links alias is invisible to MSYS)
  JQ_BIN=$(ls "$LOCALAPPDATA"/Microsoft/WinGet/Packages/jqlang.jq_*/jq.exe 2>/dev/null | head -1)
fi
JQ_BIN=${JQ_BIN:-/usr/bin/jq}
[ -x "$JQ_BIN" ] || unknown 'jq not found (winget install jqlang.jq / brew install jq)'
jq() { "$JQ_BIN" "$@" | tr -d '\r'; }   # jq.exe on Windows emits CRLF
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
epoch_fmt() { date -d "@$1" "$2" 2>/dev/null || date -r "$1" "$2"; }   # epoch format
day_end_epoch() { date -d "$1 23:59:59" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$1 23:59:59" +%s 2>/dev/null || echo 0; }
NOW=$(date +%s)
f=""
while IFS= read -r c; do
  grep -q '"rate_limits"' "$c" && { f=$c; break; }
done < <(
  find "$HOME/.codex/sessions" -name '*.jsonl' -print0 2>/dev/null |
    while IFS= read -r -d '' candidate; do
      snap=$(mtime "$candidate") || continue
      printf '%s\t%s\n' "$snap" "$candidate"
    done | sort -rn | head -40 | cut -f2-
)
[ -n "$f" ] || unknown 'No Codex usage snapshot found (run any codex task first).'
line=$(grep '"rate_limits"' "$f" | tail -1)
rl=$(set -o pipefail; jq -c '.. | objects | select(has("rate_limits")) | .rate_limits' <<<"$line" 2>/dev/null | tail -1) &&
  [ -n "$rl" ] || unknown 'Could not parse Codex rate limits from the usage snapshot.'
snap=$(mtime "$f")
age=$(( (NOW - snap) / 60 ))
fmt() { epoch_fmt "$1" '+%a %b %d %H:%M'; }
win() { # name json -> sets U (effective used %), R (reset epoch), E (elapsed % of window)
  local values u r w
  values=$(set -o pipefail; jq -er --arg window "$1" '
    .[$window] |
    select((.used_percent | type) == "number" and (.resets_at | type) == "number") |
    [(.used_percent | if . < 0 then ceil else floor end), (.resets_at | floor),
     (.window_minutes // 0 | floor)] | @tsv
  ' <<<"$rl" 2>/dev/null) || return 1
  IFS=$'\t' read -r u r w <<<"$values"
  [[ $u =~ ^-?[0-9]+$ && $r =~ ^-?[0-9]+$ && $w =~ ^-?[0-9]+$ ]] || return 1
  if [ "$r" -gt 0 ] && [ "$NOW" -ge "$r" ]; then u=0; r=$(( r + w*60 )); fi   # window already reset since snapshot
  U=$u; R=$r
  E=$(( w>0 ? (100 - (R-NOW)*100/(w*60)) : 0 ))
  if [ "$E" -lt 0 ]; then E=0; fi
}
win primary || unknown 'Invalid primary window in the Codex usage snapshot.'
PU=$U; PR=$R
win secondary || unknown 'Invalid secondary window in the Codex usage snapshot.'
WU=$U; WR=$R; WE=$E
echo "Codex usage (snapshot ${age} min old)"
echo "  5-hour window: ${PU}% used, resets $(fmt $PR)"
echo "  Weekly window: ${WU}% used (${WE}% of week elapsed), resets $(fmt $WR)"
RESETS_FILE=${CODEX_RESETS_FILE:-$HOME/.claude/codex-resets.json}
RN=0; REXP=0
if [ -f "$RESETS_FILE" ]; then
  RN=$(jq -r ".available // 0" "$RESETS_FILE" 2>/dev/null || echo 0)
  rx=$(jq -r ".expires // empty" "$RESETS_FILE" 2>/dev/null)
  [ -n "$rx" ] && REXP=$(day_end_epoch "$rx")
  if [ "$REXP" -gt 0 ] && [ "$NOW" -gt "$REXP" ]; then RN=0; fi   # expired
fi
if [ "$RN" -gt 0 ]; then
  echo "  Banked resets: $RN$( [ "$REXP" -gt 0 ] && echo " (expire $(epoch_fmt $REXP '+%a %b %d'))" ) - restore 5h + weekly; user redeems via Codex Usage settings or /usage"
fi
credits=$(jq -r 'if .credits.unlimited then "unlimited" elif .credits.has_credits then (.credits.balance|tostring) else empty end' <<<"$rl" 2>/dev/null)
[ -n "$credits" ] && echo "  Credits: $credits"

ahead=$(( WU - WE ))
EXTRA=""; [ "$RN" -gt 0 ] && EXTRA=" RESETS=$RN"
soon=0; [ "$RN" -gt 0 ] && [ "$REXP" -gt 0 ] && [ $(( REXP - NOW )) -lt 259200 ] && soon=1
if [ $PU -ge 90 ]; then
  adv=""; if [ "$RN" -gt 0 ]; then [ $WU -ge 50 ] && adv=" ADVICE=REDEEM_RECOMMENDED" || adv=" ADVICE=REDEEM_OPTIONAL"; fi
  echo "STATUS=BLOCKED UNTIL=$PR$EXTRA$adv REASON=5h_limit"
elif [ $WU -ge 95 ]; then
  adv=""; [ "$RN" -gt 0 ] && adv=" ADVICE=REDEEM_RECOMMENDED"
  echo "STATUS=BLOCKED UNTIL=$WR$EXTRA$adv REASON=weekly_limit"
else
  adv=""; [ $soon -eq 1 ] && { [ $PU -gt 20 ] || [ $WU -gt 20 ]; } && adv=" ADVICE=REDEEM_BEFORE_EXPIRY"
  # Banked resets enlarge the effective weekly budget, so pace alone does not throttle while any remain.
  if [ $PU -ge 70 ] || { [ "$RN" -eq 0 ] && [ $ahead -gt 15 ]; }; then
    echo "STATUS=THROTTLE$EXTRA$adv REASON=5h=${PU}%,weekly_ahead_of_pace_by=${ahead}pts"
  else echo "STATUS=OK$EXTRA$adv"; fi
fi
