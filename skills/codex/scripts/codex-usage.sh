#!/bin/bash
# Prints Codex rate-limit status from the newest session log that has it.
# Last line is machine-readable: STATUS=OK|THROTTLE|BLOCKED ...
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
ahead=$(( WU - WE ))
if [ $PU -ge 90 ]; then echo "STATUS=BLOCKED UNTIL=$PR REASON=5h_limit"
elif [ $WU -ge 95 ]; then echo "STATUS=BLOCKED UNTIL=$WR REASON=weekly_limit"
elif [ $PU -ge 70 ] || [ $ahead -gt 15 ]; then echo "STATUS=THROTTLE REASON=5h=${PU}%,weekly_ahead_of_pace_by=${ahead}pts"
else echo "STATUS=OK"; fi
