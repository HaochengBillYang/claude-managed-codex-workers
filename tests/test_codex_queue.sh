#!/bin/bash
set -u
set -o pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd) || exit 1
QUEUE=$REPO/skills/codex/scripts/codex-queue.sh
temp_root=${TMPDIR:-/tmp}
TEMP=$(mktemp -d "${temp_root%/}/codex-queue-test.XXXXXX") || exit 1
trap 'rm -rf -- "$TEMP"' EXIT
PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
check() {
  local description=$1 output
  shift
  if output=$("$@" 2>&1); then
    ok "$description"
  else
    bad "$description"
    if [[ -n $output ]]; then printf '%s\n' "$output"; fi
  fi
}
equal() {
  [[ $1 == "$2" ]] || { printf 'Expected:\n%s\nActual:\n%s\n' "$2" "$1"; return 1; }
}
rejects() { ! "$@"; }

cat > "$TEMP/usage stub" <<'EOF'
#!/bin/bash
if [[ -n ${USAGE_GATE:-} ]]; then
  touch "$USAGE_GATE.ready"
  for ((attempt=0; attempt<200; attempt++)); do
    [[ ! -e $USAGE_GATE.open ]] || break
    sleep 0.05
  done
fi
printf 'Usage snapshot\nSTATUS=%s\n' "$QUEUE_TEST_STATUS"
EOF
cat > "$TEMP/run stub" <<'EOF'
#!/bin/bash
jq -es --arg brief "$4" 'any(.[]; .brief == $brief and .status == "launched")' \
  "$CODEX_QUEUE_DIR"/*.json >/dev/null || exit 1
printf 'Stub launched\n'
printf '%s\n' "$CODEX_BATCH" "${CODEX_MODEL:-}" "$@" > "$4.args.tmp" &&
  mv -- "$4.args.tmp" "$4.args"
sleep 3
EOF
chmod +x "$TEMP/usage stub" "$TEMP/run stub" || exit 1
export CODEX_USAGE_CMD="$TEMP/usage stub" CODEX_RUN_CMD="$TEMP/run stub"
unset CODEX_MODEL CODEX_BATCH USAGE_GATE

fixture() {
  WORK=$TEMP/$1
  export CODEX_QUEUE_DIR="$WORK/queue" CODEX_RUNS_DIR="$WORK/runs" QUEUE_TEST_STATUS=OK
  mkdir -p "$WORK/work dir" "$CODEX_RUNS_DIR" || exit 1
}
enqueue() {
  local effort=$1 name=$2
  shift 2
  touch "$WORK/$name.md" || return 1
  (cd "$WORK" && "$QUEUE" add "$effort" workspace-write 'work dir' "$name.md" "$@")
}
edit_record() {
  local record=$CODEX_QUEUE_DIR/$1.json
  jq "$2" "$record" > "$record.tmp" && mv -- "$record.tmp" "$record"
}
wait_for_file() {
  local attempt
  for ((attempt=0; attempt<100; attempt++)); do
    [[ ! -e $1 ]] || return 0
    sleep 0.05
  done
  printf 'File did not appear: %s\n' "$1"
  return 1
}

echo '== Queue entries'
fixture ordering
first=$(enqueue low 'older brief' --priority 10 --batch 'batch one' --model test-model) || exit 1
second=$(enqueue high newer --priority 10) || exit 1
third=$(enqueue medium low-priority --priority -1) || exit 1
edit_record "$first" '.created_at -= 60' || exit 1
edit_record "$third" '.created_at -= 120' || exit 1
check 'add writes the queue entry and resolves relative paths' jq -e \
  --arg id "$first" --arg brief "$WORK/older brief.md" --arg workdir "$WORK/work dir" \
  '.id == $id and .name == "older brief" and .brief == $brief and .workdir == $workdir and
   .batch == "batch one" and .model == "test-model" and .priority == 10 and .effort == "low" and
   .sandbox == "workspace-write" and .status == "queued" and .launched_at == null and .run_log == null' \
  "$CODEX_QUEUE_DIR/$first.json"
check 'list --json sorts by descending priority, then oldest first' \
  equal "$("$QUEUE" list --json | jq -r '.[].id')" "$(printf '%s\n' "$first" "$second" "$third")"
check 'plain list uses the same ordering' \
  equal "$("$QUEUE" list | cut -f1)" "$(printf '%s\n' "$first" "$second" "$third")"
check 'add rejects a missing brief' rejects "$QUEUE" add low read-only "$WORK/work dir" "$WORK/missing.md"
check 'add rejects a missing workdir' rejects "$QUEUE" add low read-only "$WORK/missing" "$WORK/newer.md"
check 'invalid adds create no entries' equal "$("$QUEUE" list --json | jq 'length')" 3

echo '== Drain limits and status'
fixture ok
first=$(enqueue high 'first brief' --priority 3 --batch 'test batch' --model test-model) || exit 1
second=$(enqueue medium second --priority 2) || exit 1
enqueue low third --priority 1 >/dev/null && enqueue low fourth >/dev/null || exit 1
dead_pid=$(/bin/bash -c 'printf "%s\n" "$$"')
printf '{"status":"running","pid":%s}\n' "$$" > "$CODEX_RUNS_DIR/live.json"
printf '{"status":"running","pid":%s}\n' "$dead_pid" > "$CODEX_RUNS_DIR/dead.json"
output=$("$QUEUE" drain --max 3) || exit 1
check 'OK counts the live PID, ignores the dead PID and prints IDs followed by its summary' \
  equal "$output" "$(printf '%s\n' "$first" "$second" 'DRAINED=2 QUEUED=2 STATUS=OK')"
check 'the first stub sees a launched entry before it starts' wait_for_file "$WORK/first brief.md.args"
check 'the second stub sees a launched entry before it starts' wait_for_file "$WORK/second.md.args"
check 'launch passes batch, model and the four launcher arguments' equal \
  "$(cat "$WORK/first brief.md.args")" \
  "$(printf '%s\n' 'test batch' test-model high workspace-write "$WORK/work dir" "$WORK/first brief.md")"
check 'launch attaches its output log and timestamp to the entry' jq -e --arg log "$WORK/first brief.md.queue.out" \
  '.run_log == $log and .status == "launched" and (.launched_at >= .created_at)' "$CODEX_QUEUE_DIR/$first.json"
check 'launcher output goes to the queue log' grep -Fxq 'Stub launched' "$WORK/first brief.md.queue.out"

fixture throttle
enqueue high high --priority 30 >/dev/null || exit 1
first=$(enqueue low best-low --priority 20) || exit 1
enqueue low next-low --priority 10 >/dev/null || exit 1
export QUEUE_TEST_STATUS='THROTTLE RESETS=1 REASON=test'
output=$("$QUEUE" drain) || exit 1
check 'THROTTLE launches only the first eligible low-effort entry' \
  equal "$output" "$(printf '%s\n' "$first" 'DRAINED=1 QUEUED=2 STATUS=THROTTLE')"
check 'THROTTLE runs the low-effort launcher' wait_for_file "$WORK/best-low.md.args"
printf '{"status":"running","pid":%s}\n' "$$" > "$CODEX_RUNS_DIR/throttle-live.json"
check 'THROTTLE launches nothing while a worker is already running' \
  equal "$("$QUEUE" drain)" 'DRAINED=0 QUEUED=2 STATUS=THROTTLE'
rm -f "$CODEX_RUNS_DIR/throttle-live.json"
check 'absent model leaves the launcher default in effect' equal "$(sed -n '1,3p' "$WORK/best-low.md.args")" $'adhoc\n\nlow'

fixture no-launch
first=$(enqueue low pending) || exit 1
cp -R -- "$WORK" "$TEMP/before" || exit 1
export QUEUE_TEST_STATUS='BLOCKED UNTIL=1795300212 REASON=test'
check 'BLOCKED launches zero' equal "$("$QUEUE" drain)" 'DRAINED=0 QUEUED=1 STATUS=BLOCKED'
export QUEUE_TEST_STATUS=UNKNOWN
check 'UNKNOWN launches zero' equal "$("$QUEUE" drain)" 'DRAINED=0 QUEUED=1 STATUS=UNKNOWN'
export QUEUE_TEST_STATUS=OK
check 'dry-run previews the eligible ID and reports actual counts' equal "$("$QUEUE" drain --dry-run)" \
  "$(printf '%s\n' "Would launch $first" 'DRAINED=0 QUEUED=1 STATUS=OK')"
check 'BLOCKED, UNKNOWN and dry-run leave entries and logs untouched' diff -r "$TEMP/before" "$WORK"

echo '== Concurrent drain and add'
fixture concurrent
first=$(enqueue low first) || exit 1
USAGE_GATE="$WORK/gate" "$QUEUE" drain --max 1 > "$WORK/drain.out" &
drain_pid=$!
check 'drain holds the lock while usage is running' wait_for_file "$WORK/gate.ready"
second=$(enqueue low added-during-drain --priority -1) || exit 1
check 'a competing drain cannot take the lock' rejects "$QUEUE" drain --max 1
touch "$WORK/gate.open"
if wait "$drain_pid"; then
  ok 'lock holder completes successfully'
else
  bad 'lock holder completes successfully'
fi
check 'the concurrent add does not increase the launch limit' \
  equal "$(cat "$WORK/drain.out")" "$(printf '%s\n' "$first" 'DRAINED=1 QUEUED=1 STATUS=OK')"
check 'a second drain counts the live launcher before a run record exists' \
  equal "$("$QUEUE" drain --max 1)" 'DRAINED=0 QUEUED=1 STATUS=OK'
check 'the concurrent entry is still queued' equal "$("$QUEUE" list --json | jq -r '.[].id')" "$second"

echo '== SQUEEZE, failed and requeue'
fixture squeeze
enqueue low normal-low --priority 5 >/dev/null || exit 1
enqueue medium backlog-medium --priority -1 >/dev/null || exit 1
backlog=$(enqueue low backlog-low --priority -1) || exit 1
export QUEUE_TEST_STATUS='SQUEEZE UNTIL=1795300212 REASON=5h=93%'
check 'SQUEEZE launches only low-effort backlog (priority < 0)' \
  equal "$("$QUEUE" drain)" "$(printf '%s\n' "$backlog" 'DRAINED=1 QUEUED=2 STATUS=SQUEEZE')"
wait_for_file "$WORK/backlog-low.md.args" >/dev/null
printf '{"status":"running","pid":%s}\n' "$$" > "$CODEX_RUNS_DIR/squeeze-live.json"
enqueue low backlog-two --priority -2 >/dev/null || exit 1
check 'SQUEEZE launches nothing while a worker is running' \
  equal "$("$QUEUE" drain)" 'DRAINED=0 QUEUED=3 STATUS=SQUEEZE'
rm -f "$CODEX_RUNS_DIR/squeeze-live.json"
launched_at=$(jq -r '.launched_at' "$CODEX_QUEUE_DIR/$backlog.json")
jq -n --arg b "$WORK/backlog-low.md" --argjson s "$launched_at" \
  '{id:"r1", brief:$b, status:"failed", exit_code:1, failure:"rate_limit", started_at:$s}' > "$CODEX_RUNS_DIR/r1.json"
check 'failed lists the launched entry whose run hit the limit' \
  equal "$("$QUEUE" failed --json | jq -r '.[] | "\(.id) \(.failure)"')" "$backlog rate_limit"
check 'requeue puts it back in the queue' "$QUEUE" requeue "$backlog"
check 'a requeued entry is queued again with launch fields cleared' jq -e \
  '.status == "queued" and .launched_at == null and .run_log == null' "$CODEX_QUEUE_DIR/$backlog.json"
check 'failed no longer lists a requeued entry' equal "$("$QUEUE" failed --json | jq 'length')" 0
unset QUEUE_TEST_STATUS

echo '== Remove and prune'
fixture maintenance
removed=$(enqueue low remove) || exit 1
old=$(enqueue low old-launched) || exit 1
recent=$(enqueue low recent-launched) || exit 1
queued=$(enqueue low old-queued) || exit 1
edit_record "$old" '.status = "launched" | .launched_at = (now | floor) - 8 * 86400' &&
  edit_record "$recent" '.status = "launched" | .launched_at = (now | floor) - 6 * 86400' &&
  edit_record "$queued" '.created_at -= 8 * 86400' || exit 1
check 'remove succeeds for a queue ID' "$QUEUE" remove "$removed"
check 'remove deletes that entry' test ! -e "$CODEX_QUEUE_DIR/$removed.json"
check 'prune succeeds' "$QUEUE" prune
check 'prune deletes an entry launched over seven days ago' test ! -e "$CODEX_QUEUE_DIR/$old.json"
check 'prune retains recent launched entries' test -f "$CODEX_QUEUE_DIR/$recent.json"
check 'prune retains old queued entries' equal "$("$QUEUE" list --json | jq -r '.[].id')" "$queued"

echo "== $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
