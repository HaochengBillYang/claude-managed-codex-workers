#!/bin/bash
# Prints Codex rate-limit status from the newest session log that has it.
# Last line is machine-readable: STATUS=OK|THROTTLE|BLOCKED [UNTIL=..] [RESETS=n] [ADVICE=..] [REASON=..]
# Banked resets (not exposed by the Codex CLI) are read from $CODEX_RESETS_FILE
# (default ~/.claude/codex-resets.json): {"available": 2, "expires": "2026-12-01", "updated": "2026-11-21"}
set -u
NOW=$(date +%s)
f=""
for c in $(ls -t $(find "$HOME/.codex/sessions" -name '*.jsonl' 2>/dev/null) 2>/dev/null | head -40); do
  grep -q '"rate_limits"' "$c" && { f=$c; break; }
done
[ -z "$f" ] && { echo "No Codex usage snapshot found (run any codex task first)."; echo "STATUS=UNKNOWN"; exit 0; }
rl=$(grep '"rate_limits"' "$f" | tail -1 | jq -c '.. | objects | select(has("rate_limits")) | .rate_limits' | tail -1)
snap=$(stat -f %m "$f")
age=$(( (NOW - snap) / 60 ))
fmt() { date -r "$1" '+%a %b %d %H:%M'; }
win() { # name json -> sets U (effective used %), R (reset epoch), E (elapsed % of window)
  local u r w; u=$(jq -r ".$1.used_percent // 0" <<<"$rl"); r=$(jq -r ".$1.resets_at // 0" <<<"$rl"); w=$(jq -r ".$1.window_minutes // 0" <<<"$rl")
  if [ "$r" -gt 0 ] && [ "$NOW" -ge "$r" ]; then u=0; r=$(( r + w*60 )); fi   # window already reset since snapshot
  U=${u%.*}; R=$r
  E=$(( w>0 ? (100 - (R-NOW)*100/(w*60)) : 0 )); [ $E -lt 0 ] && E=0
}
win primary;   PU=$U; PR=$R
win secondary; WU=$U; WR=$R; WE=$E
echo "Codex usage (snapshot ${age} min old)"
echo "  5-hour window: ${PU}% used, resets $(fmt $PR)"
echo "  Weekly window: ${WU}% used (${WE}% of week elapsed), resets $(fmt $WR)"
RESETS_FILE=${CODEX_RESETS_FILE:-$HOME/.claude/codex-resets.json}
RN=0; REXP=0
if [ -f "$RESETS_FILE" ]; then
  RN=$(jq -r ".available // 0" "$RESETS_FILE" 2>/dev/null || echo 0)
  rx=$(jq -r ".expires // empty" "$RESETS_FILE" 2>/dev/null)
  [ -n "$rx" ] && REXP=$(date -j -f "%Y-%m-%d %H:%M:%S" "$rx 23:59:59" +%s 2>/dev/null || echo 0)
  if [ "$REXP" -gt 0 ] && [ "$NOW" -gt "$REXP" ]; then RN=0; fi   # expired
fi
if [ "$RN" -gt 0 ]; then
  echo "  Banked resets: $RN$( [ "$REXP" -gt 0 ] && echo " (expire $(date -r $REXP '+%a %b %d'))" ) - restore 5h + weekly; user redeems via Codex Usage settings or /usage"
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
