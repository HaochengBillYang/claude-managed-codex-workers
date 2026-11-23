#!/bin/bash
# Budget for Claude writer subagents: at most CAP points (default 20) of BOTH the Claude
# 5-hour and weekly limits, measured from ~/.claude/claude-usage.json (written by the
# codex-workers plugin from the same data its band shows).
#
#   claude-budget.sh reserve [label]   check the budget and record a baseline for one writer
#   claude-budget.sh settle <label>    record what that writer cost (delta since its baseline)
#   claude-budget.sh status            spend and remaining budget in the current windows
#
# Last line of reserve/status is machine-readable:
#   STATUS=OK|THROTTLE|BLOCKED SPENT_5H=n SPENT_WK=n REMAIN_5H=n REMAIN_WK=n [OPEN=n] [REASON=..]
# reserve exits 1 on BLOCKED and records nothing then. Deltas include anything else the
# account did meanwhile (other sessions, parallel writers), so the budget is conservative.
set -u
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

USAGE_FILE=${CLAUDE_USAGE_FILE:-"$HOME/.claude/claude-usage.json"}
LEDGER=${CLAUDE_WRITER_LEDGER:-"$HOME/.claude/claude-writer-ledger.json"}
CAP=${CLAUDE_WRITER_CAP:-20}            # points of each window writers may use
THROTTLE_AT=${CLAUDE_WRITER_THROTTLE:-15}
STALE_AFTER=${CLAUDE_USAGE_STALE:-900}  # seconds
TOLERANCE=300                           # reset times within this many seconds are one window
JQ=$(command -v jq || echo /usr/bin/jq)
NOW=$(date +%s)

die() { printf 'claude-budget: %s\n' "$*" >&2; exit 2; }
[ -x "$JQ" ] || die "jq not found"

cmd=${1:-}; label=${2:-}
case $cmd in reserve|settle|status) ;; *) die "usage: claude-budget.sh <reserve|settle|status> [label]";; esac

# Snapshot -------------------------------------------------------------------
snapshot=""; snap_age=""
if [ -f "$USAGE_FILE" ]; then
  snapshot=$("$JQ" -ce 'select((.five_hour_pct|type)=="number" and (.weekly_pct|type)=="number" and (.updated_at|type)=="number")' "$USAGE_FILE" 2>/dev/null) || snapshot=""
  [ -n "$snapshot" ] && snap_age=$(( NOW - $("$JQ" -r '.updated_at|floor' <<<"$snapshot") ))
fi

# Ledger (with a mkdir lock for writers) --------------------------------------
LOCK="$LEDGER.lock"
lock() {
  local i
  for i in $(seq 1 50); do mkdir "$LOCK" 2>/dev/null && { trap 'rmdir "$LOCK" 2>/dev/null' EXIT; return 0; }; sleep 0.1; done
  die "ledger is locked ($LOCK); remove it if no other claude-budget.sh is running"
}
ledger() { if [ -f "$LEDGER" ]; then "$JQ" -c 'if type=="object" and (.entries|type)=="array" then . else {entries:[]} end' "$LEDGER" 2>/dev/null || echo '{"entries":[]}'; else echo '{"entries":[]}'; fi; }
save() { local tmp="$LEDGER.tmp.$$"; mkdir -p "$(dirname "$LEDGER")" && printf '%s\n' "$1" > "$tmp" && mv -f "$tmp" "$LEDGER"; }

# Spend in the current windows: settled deltas whose settle-time reset matches the snapshot's.
# Without a reset time, fall back to entries settled within the window's length.
SUMS='
  def same($a; $b): ($a != null and $b != null and (($a - $b) | fabs) <= $tol);
  def inwin($e; $reset; $len; $key):
    if $reset != null then same($e.settled[$key]; $reset) else ($now - $e.settled.t) < $len end;
  [.entries[] | select(.settled != null)] as $s
  | { spent_5h: ([$s[] | select(inwin(.; $snap.five_hour_resets_at; 18000; "five_hour_resets_at")) | .settled.d5h] | add // 0),
      spent_wk: ([$s[] | select(inwin(.; $snap.weekly_resets_at; 604800; "weekly_resets_at")) | .settled.dwk] | add // 0),
      open: ([.entries[] | select(.settled == null)] | length) }'

verdict() { # $1 ledger json -> prints the STATUS line, returns 1 when BLOCKED
  local sums s5 swk open status reason=""
  if [ -z "$snapshot" ]; then
    printf 'STATUS=BLOCKED REASON=no Claude usage snapshot at %s (is the codex-workers plugin installed and enabled?)\n' "$USAGE_FILE"; return 1
  fi
  sums=$("$JQ" -c --argjson snap "$snapshot" --argjson now "$NOW" --argjson tol "$TOLERANCE" "$SUMS" <<<"$1")
  s5=$("$JQ" -r '.spent_5h' <<<"$sums"); swk=$("$JQ" -r '.spent_wk' <<<"$sums"); open=$("$JQ" -r '.open' <<<"$sums")
  status=$("$JQ" -rn --argjson a "$s5" --argjson b "$swk" --argjson cap "$CAP" --argjson thr "$THROTTLE_AT" \
    'if ($a >= $cap or $b >= $cap) then "BLOCKED" elif ($a >= $thr or $b >= $thr) then "THROTTLE" else "OK" end')
  if [ "$snap_age" -gt "$STALE_AFTER" ]; then
    status=BLOCKED; reason="REASON=STALE snapshot $(( snap_age / 60 )) min old (open Claude Code with the codex-workers plugin to refresh it)"
  elif [ "$status" = BLOCKED ]; then reason="REASON=writer budget of $CAP points used in the 5h or weekly window"
  elif [ "$status" = THROTTLE ]; then reason="REASON=writer spend at or above $THROTTLE_AT points"
  fi
  "$JQ" -rn --argjson a "$s5" --argjson b "$swk" --argjson cap "$CAP" --arg st "$status" --arg open "$open" --arg reason "$reason" \
    '"STATUS=\($st) SPENT_5H=\($a) SPENT_WK=\($b) REMAIN_5H=\([$cap-$a,0]|max) REMAIN_WK=\([$cap-$b,0]|max) OPEN=\($open)" + (if $reason != "" then " " + $reason else "" end)'
  [ "$status" != BLOCKED ]
}

case $cmd in
status)
  l=$(ledger)
  if [ -n "$snapshot" ]; then
    "$JQ" -r --argjson age "$snap_age" '"Claude usage (snapshot \($age / 60 | floor) min old): 5h \(.five_hour_pct)%, weekly \(.weekly_pct)%"' <<<"$snapshot"
  fi
  "$JQ" -r '.entries[] | select(.settled == null) | "  open reservation: \(.label) (since \(.t | strftime("%Y-%m-%d %H:%M")) UTC)"' <<<"$l"
  verdict "$l"; exit 0
  ;;
reserve)
  [ -n "$label" ] || label="writer-$NOW"
  lock; l=$(ledger)
  if "$JQ" -e --arg label "$label" 'any(.entries[]; .label == $label and .settled == null)' <<<"$l" >/dev/null; then
    die "an open reservation named '$label' exists; settle it first or pick another label"
  fi
  line=$(verdict "$l"); ok=$?
  if [ $ok -eq 0 ]; then
    l=$("$JQ" -c --arg label "$label" --argjson snap "$snapshot" --argjson now "$NOW" \
      '.entries += [{label: $label, start_5h: $snap.five_hour_pct, start_wk: $snap.weekly_pct,
         five_hour_resets_at: $snap.five_hour_resets_at, weekly_resets_at: $snap.weekly_resets_at, t: $now, settled: null}]' <<<"$l")
    save "$l" || die "could not write $LEDGER"
    echo "Reserved '$label' (baseline 5h $("$JQ" -r .five_hour_pct <<<"$snapshot")%, weekly $("$JQ" -r .weekly_pct <<<"$snapshot")%)."
  fi
  echo "$line"; exit $(( ok == 0 ? 0 : 1 ))
  ;;
settle)
  [ -n "$label" ] || die "settle needs the label given to reserve"
  [ -n "$snapshot" ] || die "no Claude usage snapshot at $USAGE_FILE"
  lock; l=$(ledger)
  "$JQ" -e --arg label "$label" 'any(.entries[]; .label == $label and .settled == null)' <<<"$l" >/dev/null \
    || die "no open reservation named '$label'"
  [ "$snap_age" -gt "$STALE_AFTER" ] && printf 'claude-budget: warning: snapshot is %s min old; the delta may be too low\n' $(( snap_age / 60 )) >&2
  # delta = now - start, floored at 0; if the window reset in between, the post-reset value.
  l=$("$JQ" -c --arg label "$label" --argjson snap "$snapshot" --argjson now "$NOW" --argjson tol "$TOLERANCE" '
    def same($a; $b): ($a != null and $b != null and (($a - $b) | fabs) <= $tol);
    def delta($start; $end; $r0; $r1): if ($r0 != null and $r1 != null and (same($r0; $r1) | not)) then $end else ([$end - $start, 0] | max) end;
    (.entries | map(.label == $label and .settled == null) | rindex(true)) as $i
    | .entries[$i] |= (. + {settled: {
        d5h: delta(.start_5h; $snap.five_hour_pct; .five_hour_resets_at; $snap.five_hour_resets_at),
        dwk: delta(.start_wk; $snap.weekly_pct; .weekly_resets_at; $snap.weekly_resets_at),
        end_5h: $snap.five_hour_pct, end_wk: $snap.weekly_pct,
        five_hour_resets_at: $snap.five_hour_resets_at, weekly_resets_at: $snap.weekly_resets_at, t: $now}})' <<<"$l")
  save "$l" || die "could not write $LEDGER"
  "$JQ" -r --arg label "$label" '[.entries[] | select(.label == $label)] | last | "Settled \(.label): 5h +\(.settled.d5h) points, weekly +\(.settled.dwk) points."' <<<"$l"
  verdict "$l"; exit 0
  ;;
esac
