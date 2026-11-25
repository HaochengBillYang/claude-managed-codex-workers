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
blocked() {
  printf 'STATUS=BLOCKED REASON=%s\n' "$*"
  [ "$cmd" = status ] && exit 0
  exit 1
}

cmd=${1:-}; label=${2:-}
case $cmd in reserve|settle|status) ;; *) die "usage: claude-budget.sh <reserve|settle|status> [label]";; esac

[ -x "$JQ" ] || blocked "jq not found"

# Snapshot -------------------------------------------------------------------
snapshot=""; snap_age=""
if [ -f "$USAGE_FILE" ]; then
  snapshot=$("$JQ" -ces '
    def reset: . == null or type == "number";
    select(length == 1) | .[0]
    | select((.five_hour_pct|type)=="number" and (.weekly_pct|type)=="number" and
             (.updated_at|type)=="number" and (.five_hour_resets_at|reset) and (.weekly_resets_at|reset))
  ' "$USAGE_FILE" 2>/dev/null) || snapshot=""
  if [ -n "$snapshot" ]; then
    updated=$("$JQ" -er '.updated_at | floor' <<<"$snapshot") || blocked "could not calculate snapshot age"
    [[ $updated =~ ^[0-9]+$ ]] || blocked "invalid snapshot timestamp"
    snap_age=$(( NOW - updated ))
  fi
fi

# Ledger (with a mkdir lock for writers) --------------------------------------
LOCK="$LEDGER.lock"
LOCK_PID="$LOCK/pid-$$"
lock() {
  local i marker pid
  mkdir -p "$(dirname "$LEDGER")" || blocked "could not create ledger directory"
  for ((i=0; i<50; i++)); do
    if mkdir "$LOCK" 2>/dev/null; then
      if ! printf '%s\n' "$$" > "$LOCK_PID"; then
        rm -f "$LOCK_PID"
        rmdir "$LOCK"
        blocked "could not record ledger lock holder"
      fi
      trap 'rm -f "$LOCK_PID"; rmdir "$LOCK" 2>/dev/null' EXIT
      return 0
    fi
    for marker in "$LOCK"/pid-*; do
      [ -f "$marker" ] || continue
      pid=${marker##*/pid-}
      [[ $pid =~ ^[1-9][0-9]*$ ]] || continue
      if ! kill -0 "$pid" 2>/dev/null && ! ps -p "$pid" >/dev/null 2>&1; then
        # Only the contender that removed this holder's marker may remove the directory.
        if rm "$marker" 2>/dev/null; then
          rmdir "$LOCK" 2>/dev/null || :
        fi
      fi
    done
    sleep 0.1
  done
  blocked "ledger is locked ($LOCK)"
}
ledger() {
  if [ ! -e "$LEDGER" ] && [ ! -L "$LEDGER" ]; then
    local parent
    parent=$(dirname "$LEDGER")
    while [ ! -e "$parent" ] && [ ! -L "$parent" ]; do
      parent=$(dirname "$parent")
    done
    [ -d "$parent" ] && [ -x "$parent" ] || return 1
    printf '%s\n' '{"entries":[]}'
    return
  fi
  [ -f "$LEDGER" ] && [ -r "$LEDGER" ] || return 1
  "$JQ" -ces '
    def number: type == "number";
    def reset: . == null or number;
    def resets: (.five_hour_resets_at | reset) and (.weekly_resets_at | reset);
    def entry:
      type == "object" and (.label | type == "string") and (.t | number) and
      (.start_5h | number) and (.start_wk | number) and resets and
      (.settled | . == null or
        (type == "object" and (.t | number) and (.d5h | number and . >= 0) and
         (.dwk | number and . >= 0) and resets));
    select(length == 1) | .[0]
    | select(type == "object" and (.entries | type == "array" and all(.[]; entry)))
  ' "$LEDGER" 2>/dev/null
}
save() {
  local tmp
  tmp=$(mktemp "$LEDGER.tmp.XXXXXX") || return 1
  if printf '%s\n' "$1" > "$tmp" && mv -f "$tmp" "$LEDGER"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

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

verdict() { # Prints a verdict. Returns 1 for a budget block or 2 for a calculation error.
  local sums s5 swk open status reason=""
  if [ -z "$snapshot" ]; then
    printf 'STATUS=BLOCKED REASON=no Claude usage snapshot at %s (is the codex-workers plugin installed and enabled?)\n' "$USAGE_FILE"; return 1
  fi
  sums=$("$JQ" -ce --argjson snap "$snapshot" --argjson now "$NOW" --argjson tol "$TOLERANCE" "$SUMS" <<<"$1") || return 2
  s5=$("$JQ" -er '.spent_5h' <<<"$sums") || return 2
  swk=$("$JQ" -er '.spent_wk' <<<"$sums") || return 2
  open=$("$JQ" -er '.open' <<<"$sums") || return 2
  status=$("$JQ" -ern --argjson a "$s5" --argjson b "$swk" --argjson cap "$CAP" --argjson thr "$THROTTLE_AT" \
    'if ($a >= $cap or $b >= $cap) then "BLOCKED" elif ($a >= $thr or $b >= $thr) then "THROTTLE" else "OK" end') || return 2
  if [ "$snap_age" -gt "$STALE_AFTER" ]; then
    status=BLOCKED; reason="REASON=STALE snapshot $(( snap_age / 60 )) min old (open Claude Code with the codex-workers plugin to refresh it)"
  elif [ "$status" = BLOCKED ]; then reason="REASON=writer budget of $CAP points used in the 5h or weekly window"
  elif [ "$status" = THROTTLE ]; then reason="REASON=writer spend at or above $THROTTLE_AT points"
  fi
  local line
  line=$("$JQ" -ern --argjson a "$s5" --argjson b "$swk" --argjson cap "$CAP" --arg st "$status" --arg open "$open" --arg reason "$reason" \
    '"STATUS=\($st) SPENT_5H=\($a) SPENT_WK=\($b) REMAIN_5H=\([$cap-$a,0]|max) REMAIN_WK=\([$cap-$b,0]|max) OPEN=\($open)" + (if $reason != "" then " " + $reason else "" end)') || return 2
  printf '%s\n' "$line"
  [ "$status" != BLOCKED ]
}

if [ "$cmd" = settle ]; then
  [ -n "$label" ] || die "settle needs the label given to reserve"
  [ -n "$snapshot" ] || blocked "no Claude usage snapshot at $USAGE_FILE"
fi
[ "$cmd" = status ] || lock
l=$(ledger) || blocked "unreadable or malformed ledger at $LEDGER"

# Capture the verdict before printing it or committing any mutation.
check_verdict() {
  verdict_rc=0
  line=$(verdict "$1") || verdict_rc=$?
  [ "$verdict_rc" -le 1 ] || blocked "could not calculate writer budget"
}

if [ "$cmd" = status ]; then
  check_verdict "$l"
  if [ -n "$snapshot" ]; then
    "$JQ" -er --argjson age "$snap_age" '"Claude usage (snapshot \($age / 60 | floor) min old): 5h \(.five_hour_pct)%, weekly \(.weekly_pct)%"' <<<"$snapshot" \
      || blocked "could not display usage snapshot"
  fi
  "$JQ" -r '.entries[] | select(.settled == null) | "  open reservation: \(.label) (since \(.t | strftime("%Y-%m-%d %H:%M")) UTC)"' <<<"$l" \
    || blocked "could not display open reservations"
  printf '%s\n' "$line"
  exit 0
fi

[ -n "$label" ] || label="writer-$NOW"
open_reservation=$("$JQ" -er --arg label "$label" 'any(.entries[]; .label == $label and .settled == null) | tostring' <<<"$l") \
  || blocked "could not check open reservations"

case $cmd in
reserve)
  [ "$open_reservation" != true ] || die "an open reservation named '$label' exists; settle it first or pick another label"
  check_verdict "$l"
  if [ "$verdict_rc" -eq 0 ]; then
    l=$("$JQ" -ce --arg label "$label" --argjson snap "$snapshot" --argjson now "$NOW" \
      '.entries += [{label: $label, start_5h: $snap.five_hour_pct, start_wk: $snap.weekly_pct,
         five_hour_resets_at: $snap.five_hour_resets_at, weekly_resets_at: $snap.weekly_resets_at, t: $now, settled: null}]' <<<"$l") \
      || blocked "could not update reservation"
    message=$("$JQ" -er --arg label "$label" '"Reserved \u0027\($label)\u0027 (baseline 5h \(.five_hour_pct)%, weekly \(.weekly_pct)%)."' <<<"$snapshot") \
      || blocked "could not display reservation"
    save "$l" || blocked "could not write $LEDGER"
    printf '%s\n' "$message"
  fi
  printf '%s\n' "$line"
  exit "$verdict_rc"
  ;;
settle)
  [ "$open_reservation" = true ] || die "no open reservation named '$label'"
  [ "$snap_age" -gt "$STALE_AFTER" ] && printf 'claude-budget: warning: snapshot is %s min old; the delta may be too low\n' $(( snap_age / 60 )) >&2
  # delta = now - start, floored at 0; if the window reset in between, the post-reset value.
  l=$("$JQ" -ce --arg label "$label" --argjson snap "$snapshot" --argjson now "$NOW" --argjson tol "$TOLERANCE" '
    def same($a; $b): ($a != null and $b != null and (($a - $b) | fabs) <= $tol);
    def delta($start; $end; $r0; $r1): if ($r0 != null and $r1 != null and (same($r0; $r1) | not)) then $end else ([$end - $start, 0] | max) end;
    (.entries | map(.label == $label and .settled == null) | rindex(true)) as $i
    | .entries[$i] |= (. + {settled: {
        d5h: delta(.start_5h; $snap.five_hour_pct; .five_hour_resets_at; $snap.five_hour_resets_at),
        dwk: delta(.start_wk; $snap.weekly_pct; .weekly_resets_at; $snap.weekly_resets_at),
        end_5h: $snap.five_hour_pct, end_wk: $snap.weekly_pct,
        five_hour_resets_at: $snap.five_hour_resets_at, weekly_resets_at: $snap.weekly_resets_at, t: $now}})' <<<"$l") \
    || blocked "could not settle reservation"
  message=$("$JQ" -er --arg label "$label" '[.entries[] | select(.label == $label)] | last | "Settled \(.label): 5h +\(.settled.d5h) points, weekly +\(.settled.dwk) points."' <<<"$l") \
    || blocked "could not display settlement"
  check_verdict "$l"
  save "$l" || blocked "could not write $LEDGER"
  printf '%s\n' "$message" "$line"
  exit 0
  ;;
esac
