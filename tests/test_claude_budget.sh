#!/bin/bash
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd) || exit 1
BUDGET=$REPO/skills/codex/scripts/claude-budget.sh
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/claude-budget-test.XXXXXX") || exit 1
trap 'rm -rf "$TEMP"' EXIT
PASS=0
FAIL=0

check() {
  local description=$1 output
  shift
  if output=$("$@" 2>&1); then
    PASS=$((PASS+1))
    printf '  \033[32mPASS\033[0m %s\n' "$description"
  else
    FAIL=$((FAIL+1))
    printf '  \033[31mFAIL\033[0m %s\n' "$description"
    [ -z "$output" ] || printf '%s\n' "$output"
  fi
}

export CLAUDE_WRITER_CAP=20 CLAUDE_WRITER_THROTTLE=15 CLAUDE_USAGE_STALE=900
export REAL_JQ
REAL_JQ=$(command -v jq) || exit 1
now=$(date +%s)

usage() {
  printf '{"five_hour_pct":%s,"weekly_pct":%s,"updated_at":%s,"five_hour_resets_at":%s,"weekly_resets_at":%s}\n' \
    "$1" "$2" "${3:-$now}" "$((now + 3600))" "$((now + 86400))" > "$CLAUDE_USAGE_FILE"
}
fixture() {
  mkdir "$TEMP/$1" || exit 1
  export CLAUDE_USAGE_FILE="$TEMP/$1/usage.json" CLAUDE_WRITER_LEDGER="$TEMP/$1/writer state/ledger.json"
  usage 10 20 || exit 1
}
expect() {
  local want_rc=$1 want_status=$2 output rc=0
  shift 2
  output=$("$@" 2>&1) || rc=$?
  if [[ $rc != "$want_rc" || ${output##*$'\n'} != "$want_status"* ]]; then
    printf 'Expected exit %s and final line starting with %s, got exit %s:\n%s\n' "$want_rc" "$want_status" "$rc" "$output"
    return 1
  fi
}

echo '== Claude writer budget'
fixture happy
check 'reserve creates the missing ledger parent and records the baseline' \
  expect 0 'STATUS=OK SPENT_5H=0 SPENT_WK=0 REMAIN_5H=20 REMAIN_WK=20 OPEN=0' "$BUDGET" reserve writer
check 'status counts the open reservation' \
  expect 0 'STATUS=OK SPENT_5H=0 SPENT_WK=0 REMAIN_5H=20 REMAIN_WK=20 OPEN=1' "$BUDGET" status
usage 14 26 || exit 1
check 'settle records both deltas and closes the reservation' \
  expect 0 'STATUS=OK SPENT_5H=4 SPENT_WK=6 REMAIN_5H=16 REMAIN_WK=14 OPEN=0' "$BUDGET" settle writer
check 'status reads the saved settlement' \
  expect 0 'STATUS=OK SPENT_5H=4 SPENT_WK=6 REMAIN_5H=16 REMAIN_WK=14 OPEN=0' "$BUDGET" status

fixture thresholds
"$BUDGET" reserve first >/dev/null || exit 1
usage 25 21 || exit 1
check 'settle reports THROTTLE at exactly 15 points' expect 0 'STATUS=THROTTLE ' "$BUDGET" settle first
check 'reserve still accepts work at THROTTLE' expect 0 'STATUS=THROTTLE ' "$BUDGET" reserve second
usage 30 22 || exit 1
check 'settle reports BLOCKED at exactly 20 points' expect 0 'STATUS=BLOCKED SPENT_5H=20 ' "$BUDGET" settle second
cp "$CLAUDE_WRITER_LEDGER" "$TEMP/before" || exit 1
check 'reserve exits 1 at the cap' expect 1 'STATUS=BLOCKED SPENT_5H=20 ' "$BUDGET" reserve third
check 'blocked reserve leaves the ledger unchanged' cmp "$TEMP/before" "$CLAUDE_WRITER_LEDGER"

fixture stale
usage 10 20 "$((now - 901))" || exit 1
check 'a stale snapshot blocks reserve' expect 1 'STATUS=BLOCKED ' "$BUDGET" reserve writer
check 'a stale snapshot creates no ledger' test ! -e "$CLAUDE_WRITER_LEDGER"

fixture malformed
mkdir -p "$(dirname "$CLAUDE_WRITER_LEDGER")" || exit 1
for invalid in '{' '' '{"entries":[{"settled":{"t":1}}]}' $'{"entries":[]}\n{"entries":[]}'; do
  printf '%s' "$invalid" > "$TEMP/before"
  cp "$TEMP/before" "$CLAUDE_WRITER_LEDGER" || exit 1
  check 'reserve blocks an invalid ledger' expect 1 'STATUS=BLOCKED ' "$BUDGET" reserve writer
  check 'status blocks an invalid ledger' expect 0 'STATUS=BLOCKED ' "$BUDGET" status
  check 'settle blocks an invalid ledger' expect 1 'STATUS=BLOCKED ' "$BUDGET" settle writer
  check 'invalid ledger stays byte-for-byte unchanged' cmp "$TEMP/before" "$CLAUDE_WRITER_LEDGER"
done
printf '%s\n' '{"entries":[]}' > "$CLAUDE_WRITER_LEDGER"
chmod 000 "$CLAUDE_WRITER_LEDGER" || exit 1
if [ ! -r "$CLAUDE_WRITER_LEDGER" ]; then
  check 'an unreadable ledger is blocked' expect 1 'STATUS=BLOCKED ' "$BUDGET" reserve writer
fi
chmod 600 "$CLAUDE_WRITER_LEDGER" || exit 1
rm "$CLAUDE_WRITER_LEDGER"
mkdir "$CLAUDE_WRITER_LEDGER" || exit 1
check 'a non-file ledger path is blocked' expect 1 'STATUS=BLOCKED ' "$BUDGET" reserve writer
check 'the non-file ledger path is untouched' test -d "$CLAUDE_WRITER_LEDGER"

fixture jq-errors
"$BUDGET" reserve writer >/dev/null || exit 1
cp "$CLAUDE_WRITER_LEDGER" "$TEMP/before" || exit 1
# Override only jq discovery, including on hosts with jq in /usr/bin.
cat > "$TEMP/bash-env" <<'STUB'
command() {
  if [[ $* == '-v jq' ]]; then
    printf '%s\n' "$JQ_STUB"
  else
    builtin command "$@"
  fi
}
STUB
export JQ_STUB="$TEMP/jq"
cat > "$JQ_STUB" <<'STUB'
#!/bin/bash
for arg; do
  if [[ $arg == *"$FAIL_FILTER"* ]]; then
    # A filter can emit partial output before reporting an error.
    printf '{}\n'
    exit 5
  fi
done
exec "$REAL_JQ" "$@"
STUB
chmod +x "$JQ_STUB" || exit 1
check 'a failing spend calculation blocks reserve' expect 1 'STATUS=BLOCKED ' \
  env BASH_ENV="$TEMP/bash-env" FAIL_FILTER='def inwin' "$BUDGET" reserve other
check 'a failing reserve transformation blocks reserve' expect 1 'STATUS=BLOCKED ' \
  env BASH_ENV="$TEMP/bash-env" FAIL_FILTER='.entries +=' "$BUDGET" reserve other
check 'a failing settle transformation blocks settle' expect 1 'STATUS=BLOCKED ' \
  env BASH_ENV="$TEMP/bash-env" FAIL_FILTER='def delta' "$BUDGET" settle writer
check 'a failing settle verdict blocks before saving' expect 1 'STATUS=BLOCKED ' \
  env BASH_ENV="$TEMP/bash-env" FAIL_FILTER='def inwin' "$BUDGET" settle writer
check 'jq failures leave the ledger unchanged' cmp "$TEMP/before" "$CLAUDE_WRITER_LEDGER"

cat > "$TEMP/mv-error" <<'STUB'
mv() {
  # The temporary file should be adjacent to the ledger and use a unique name.
  [[ $2 == "$CLAUDE_WRITER_LEDGER".tmp.* && $2 != "$CLAUDE_WRITER_LEDGER.tmp.$$" && -f $2 ]] || return 1
  printf '%s\n' "$2" > "$MOVE_SOURCE"
  return 1
}
STUB
check 'a failed ledger rename blocks reserve' expect 1 'STATUS=BLOCKED ' \
  env BASH_ENV="$TEMP/mv-error" MOVE_SOURCE="$TEMP/move-source" "$BUDGET" reserve other
temp_ledger_removed() {
  local path
  read -r path < "$TEMP/move-source" && [ ! -e "$path" ]
}
check 'the failed rename cleans up its temporary file' temp_ledger_removed
check 'the failed rename preserves the ledger' cmp "$TEMP/before" "$CLAUDE_WRITER_LEDGER"

fixture locks
lock="$CLAUDE_WRITER_LEDGER.lock"
mkdir -p "$lock" || exit 1
dead_pid=$(/bin/bash -c 'printf "%s\n" "$$"')
printf '%s\n' "$dead_pid" > "$lock/pid-$dead_pid"
cat > "$TEMP/check-lock-owner" <<'STUB'
mv() {
  local owner
  read -r owner < "$CLAUDE_WRITER_LEDGER.lock/pid-$$" && [[ $owner == "$$" ]] || return 1
  command mv "$@"
}
STUB
check 'reserve takes over a dead holder and records its own PID' expect 0 'STATUS=OK ' \
  env BASH_ENV="$TEMP/check-lock-owner" "$BUDGET" reserve writer
check 'the recovered lock is released' test ! -e "$lock"
mkdir "$lock" || exit 1
printf '%s\n' "$$" > "$lock/pid-$$"
cp "$CLAUDE_WRITER_LEDGER" "$TEMP/before" || exit 1
check 'a live holder blocks reserve' expect 1 'STATUS=BLOCKED REASON=ledger is locked ' "$BUDGET" reserve other
check 'the live holder keeps its lock' test -f "$lock/pid-$$"
check 'the live lock leaves the ledger unchanged' cmp "$TEMP/before" "$CLAUDE_WRITER_LEDGER"

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
