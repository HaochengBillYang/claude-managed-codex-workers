#!/bin/bash
# Prints Codex rate-limit status from the newest session log that has it.
# Last line is machine-readable: STATUS=OK|THROTTLE|SQUEEZE|BLOCKED [UNTIL=..] [RESETS=n] [ADVICE=..] [REASON=..]
# Banked resets come from the Codex app-server (account/rateLimits/read), cached in
# $CODEX_RESETS_FILE (default ~/.claude/codex-resets.json) by codex-resets-refresh.sh.
# A cache older than 10 min is refreshed in the background, so this script never waits on it.
set -u
NOW=$(date +%s)
# Newest *valid* snapshot across the newest 40 session files. A line still being written (partial
# JSON) is skipped. So are other limit kinds: runs refused at the limit log limit_id "premium" with
# null windows, sometimes as the only entries in their file. Only entries carrying both windows
# (limit_id "codex" or absent) count, so a blocked account keeps showing its last real numbers.
valid_rl() {
  grep '"rate_limits"' "$1" 2>/dev/null | tail -20 | jq -c '.. | objects | select(has("rate_limits")) | .rate_limits
    | select(type == "object" and .primary != null and .secondary != null and ((.limit_id // "codex") == "codex"))' 2>/dev/null | tail -1
}
f=""; rl=""; seen=""
for c in $(ls -t $(find "$HOME/.codex/sessions" -name '*.jsonl' 2>/dev/null) 2>/dev/null | head -40); do
  grep -q '"rate_limits"' "$c" || continue
  seen=$c
  rl=$(valid_rl "$c"); [ -n "$rl" ] && { f=$c; break; }
done
[ -z "$seen" ] && { echo "No Codex usage snapshot found (run any codex task first)."; echo "STATUS=UNKNOWN"; exit 0; }
[ -z "$f" ] && f=$seen   # only invalid entries: falls through to the unreadable check below
snap=$(stat -f %m "$f")
age=$(( (NOW - snap) / 60 ))
fmt() { date -r "$1" '+%a %b %d %H:%M'; }
win() { # name json -> sets U (effective used %), R (reset epoch), E (elapsed % of window)
  local u r w; u=$(jq -r ".$1.used_percent // 0" <<<"$rl"); r=$(jq -r ".$1.resets_at // 0" <<<"$rl"); w=$(jq -r ".$1.window_minutes // 0" <<<"$rl")
  if [ "$r" -gt 0 ] && [ "$NOW" -ge "$r" ]; then u=0; r=$(( r + w*60 )); fi   # window already reset since snapshot
  U=${u%.*}; R=$r
  E=$(( w>0 ? (100 - (R-NOW)*100/(w*60)) : 0 )); [ $E -lt 0 ] && E=0
}
# Fail closed: a partial last line or malformed rate-limit data must give UNKNOWN (no launches),
# never a status computed from empty numbers.
isnum() { case ${1:-} in ''|*[!0-9]*) return 1;; esac; }
unreadable() { echo "Codex usage snapshot unreadable ($f)."; echo "STATUS=UNKNOWN REASON=unreadable_snapshot"; exit 0; }
jq -e '(.primary.used_percent|type=="number") and (.secondary.used_percent|type=="number")' <<<"${rl:-null}" >/dev/null 2>&1 || unreadable
win primary;   PU=$U; PR=$R
win secondary; WU=$U; WR=$R; WE=$E
for v in "$PU" "$PR" "$WU" "$WR" "$WE"; do isnum "$v" || unreadable; done
echo "Codex usage (snapshot ${age} min old)"
echo "  5-hour window: ${PU}% used, resets $(fmt $PR)"
echo "  Weekly window: ${WU}% used (${WE}% of week elapsed), resets $(fmt $WR)"
RESETS_FILE=${CODEX_RESETS_FILE:-$HOME/.claude/codex-resets.json}
REFRESH="$(dirname "$0")/codex-resets-refresh.sh"
rupd=$(jq -r ".updated // 0" "$RESETS_FILE" 2>/dev/null || echo 0)
case $rupd in ""|*[!0-9]*) rupd=0;; esac   # hand-written files may hold a date string
if [ -x "$REFRESH" ] && [ $(( NOW - rupd )) -gt 600 ]; then
  ( "$REFRESH" >/dev/null 2>&1 & ) 2>/dev/null
fi
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
SQUEEZE_MAX=${CODEX_SQUEEZE_MAX:-97}
reached=$(jq -r ".rate_limit_reached_type // empty" <<<"$rl" 2>/dev/null)
adv5=""; if [ "$RN" -gt 0 ]; then [ $WU -ge 50 ] && adv5=" ADVICE=REDEEM_RECOMMENDED" || adv5=" ADVICE=REDEEM_OPTIONAL"; fi
if [ $PU -ge $SQUEEZE_MAX ] || { [ -n "$reached" ] && [ $PU -ge 90 ]; }; then
  echo "STATUS=BLOCKED UNTIL=$PR$EXTRA$adv5 REASON=5h_limit"
elif [ $PU -ge 90 ] && [ $WU -lt 95 ]; then
  # SQUEEZE: use the tail of the 5h window for backlog work only (priority < 0, low effort, one at a time).
  echo "STATUS=SQUEEZE UNTIL=$PR$EXTRA$adv5 REASON=5h=${PU}%"
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
