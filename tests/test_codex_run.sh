#!/bin/bash
# Tests codex-run.sh with stub codex binaries.
# Never runs the real codex. bash 3.2 compatible; works with BSD and GNU tools.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
RUN=$REPO/skills/codex/scripts/codex-run.sh
TEMP=$(mktemp -d); trap 'rm -rf "$TEMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

# Isolate the trailing usage report from real Codex data.
export HOME="$TEMP/home"
mkdir -p "$TEMP/bin" "$HOME"
stub() { printf '#!/bin/bash\ncat >/dev/null\n%s\n' "$2" > "$TEMP/bin/$1"; chmod +x "$TEMP/bin/$1"; }
stub ok      'echo "{\"type\":\"thread.started\"}"; exit 0'
stub hang    'echo "{\"type\":\"thread.started\"}"; sleep 30; exit 0'
stub limit   'echo "{\"type\":\"thread.started\"}"; echo "ERROR: You have hit your usage limit." >&2; exit 1'
stub failevt 'echo "{\"type\":\"turn.failed\",\"error\":{\"message\":\"rate_limit_reached: try later\"}}"; exit 1'
stub quotaout 'echo "{\"type\":\"item.completed\",\"item\":{\"type\":\"command_execution\",\"aggregated_output\":\"no Codex quota was spent\"}}"; exit 3'
stub graceful 'trap '\'': > "$TERM_MARKER"; sleep 2; exit 0'\'' TERM
: > "$READY_MARKER"
while :; do sleep 0.1; done'
stub stubborn 'trap '\'': > "$TERM_MARKER"'\'' TERM
: > "$READY_MARKER"
while :; do sleep 0.1; done'

export REAL_JQ
REAL_JQ=$(command -v jq) || exit 1
cat > "$TEMP/bin/jq" <<'EOF'
#!/bin/bash
: > "$JQ_MARKER"
if [[ -n ${FAIL_STATUS:-} ]]; then
  for arg in "$@"; do
    [[ $arg != "$FAIL_STATUS" ]] || exit 1
  done
fi
exec "$REAL_JQ" "$@"
EOF
chmod +x "$TEMP/bin/jq"

run_stub() {
  local name=$1 bin=$2
  printf '# brief\n' > "$TEMP/$name.md"
  CODEX_BIN="$TEMP/bin/$bin" CODEX_RUNS_DIR="$TEMP/runs-$name" CODEX_IDLE_TIMEOUT=2 CODEX_WATCHDOG_INTERVAL=1 \
    "$RUN" low read-only "$TEMP" "$TEMP/$name.md"
}
run_case() { # name stub -> prints "status failure"
  run_stub "$@" >/dev/null 2>&1
  jq -r '"\(.status) \(.failure)"' "$TEMP/runs-$1"/*.json
}
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

echo '== codex-run.sh classification and watchdog'
expect 'success is done with no failure'                "$(run_case a ok)"       'done null'
start=$(date +%s); got=$(run_case b hang); took=$(( $(date +%s) - start ))
expect 'a silent worker is stopped as stalled'           "$got"                   'failed stalled'
if [ "$took" -lt 20 ]; then ok "the watchdog stops it well before the stub's 30 s (${took}s)"; else bad "watchdog too slow (${took}s)"; fi
expect 'a usage limit on stderr is rate_limit'          "$(run_case c limit)"    'failed rate_limit'
expect 'a limit in a turn.failed event is rate_limit'   "$(run_case d failevt)"  'failed rate_limit'
expect '"quota" in command output is not a limit'       "$(run_case e quotaout)" 'failed error'
if ls "$TEMP"/*.stalled >/dev/null 2>&1; then bad 'stall markers left behind'; else ok 'no stall markers left behind'; fi

echo '== codex-run.sh record handling and signals'
prune_dir="$TEMP/runs-prune"
mkdir -p "$prune_dir"
printf '{"status":"running","pid":%s}\n' "$$" > "$prune_dir/001.json"
printf '{"status":"running","pid":2147483647}\n' > "$prune_dir/002.json"
printf '{"status":"done","pid":%s}\n' "$$" > "$prune_dir/003.json"
for ((i=4; i<=52; i++)); do
  printf '{"status":"done"}\n' > "$(printf '%s/%03d.json' "$prune_dir" "$i")"
done
run_stub prune ok >/dev/null 2>&1
records=("$prune_dir"/*.json)
if [[ -f $prune_dir/001.json && ! -e $prune_dir/002.json && ! -e $prune_dir/003.json &&
      -f $prune_dir/004.json && ${#records[@]} -eq 51 ]]; then
  ok 'pruning keeps the newest 50 plus an older live running record'
else
  bad 'pruning keeps the newest 50 plus an older live running record'
fi

export JQ_MARKER="$TEMP/jq.used"
if PATH="$TEMP/bin:$PATH" run_stub path ok >/dev/null 2>&1 && [[ -f $JQ_MARKER ]]; then
  ok 'record writing uses jq from PATH'
else
  bad 'record writing uses jq from PATH'
fi

check_write_failure() {
  if [[ $1 -ne 0 ]] && grep -q "failed to write final record .* (status $2)" "$3"; then
    ok "a failed $2 record write exits nonzero and reports to stderr"
  else
    bad "a failed $2 record write exits nonzero and reports to stderr"
  fi
}
PATH="$TEMP/bin:$PATH" FAIL_STATUS=done run_stub write-failure ok > /dev/null 2>"$TEMP/write-error"
check_write_failure "$?" done "$TEMP/write-error"

wait_for_file() {
  local attempt
  for ((attempt=0; attempt<100; attempt++)); do
    [[ -e $1 ]] && return 0
    sleep 0.05
  done
  return 1
}

signal_case() {
  local name=$1 worker=$2 fail_status=${3:-}
  local wrapper child record rc started elapsed attempt
  local records
  printf '# brief\n' > "$TEMP/$name.md"
  PATH="$TEMP/bin:$PATH" FAIL_STATUS="$fail_status" TERM_MARKER="$TEMP/$name.term" READY_MARKER="$TEMP/$name.ready" \
    CODEX_BIN="$TEMP/bin/$worker" CODEX_RUNS_DIR="$TEMP/runs-$name" CODEX_WATCHDOG_INTERVAL=1 \
    "$RUN" low read-only "$TEMP" "$TEMP/$name.md" > /dev/null 2>"$TEMP/$name.error" &
  wrapper=$!
  # Resolve the glob after the wrapper has written its initial record.
  for ((attempt=0; attempt<100; attempt++)); do
    records=("$TEMP/runs-$name/"*"-$wrapper.json")
    record=${records[0]}
    [[ -f $record ]] && break
    sleep 0.05
  done
  if ! wait_for_file "$TEMP/$name.ready" || ! child=$(jq -er '.pid' "$record"); then
    bad "$name worker becomes ready"
    kill -TERM "$wrapper" 2>/dev/null
    wait "$wrapper"
    return
  fi
  started=$SECONDS
  kill -TERM "$wrapper"
  if wait_for_file "$TEMP/$name.term" && kill -0 "$child" 2>/dev/null &&
    jq -e '.status == "running"' "$record" >/dev/null; then
    ok "$name worker stays recorded as running while alive after TERM"
  else
    bad "$name worker stays recorded as running while alive after TERM"
  fi
  while kill -0 "$wrapper" 2>/dev/null && (( SECONDS - started < 15 )); do
    sleep 0.1
  done
  if kill -0 "$wrapper" 2>/dev/null; then
    bad "$name wrapper exits within 15 seconds"
    kill -KILL "$child" "$wrapper" 2>/dev/null
  fi
  wait "$wrapper"
  rc=$?
  elapsed=$((SECONDS - started))
  if [[ -n $fail_status ]]; then
    check_write_failure "$rc" killed "$TEMP/$name.error"
  elif [[ $rc -eq 130 ]] && ! kill -0 "$child" 2>/dev/null &&
    jq -e '.status == "killed" and .exit_code == 130' "$record" >/dev/null; then
    ok "$name worker has exited before killed is recorded"
  else
    bad "$name worker has exited before killed is recorded"
    kill -KILL "$child" 2>/dev/null
  fi
  if [[ $worker == stubborn ]]; then
    if (( elapsed >= 9 && elapsed <= 13 )); then
      ok "a TERM-resistant worker is killed after the grace period (${elapsed}s)"
    else
      bad "a TERM-resistant worker is killed after the grace period (${elapsed}s)"
    fi
  fi
}
signal_case graceful graceful
signal_case stubborn stubborn
signal_case signal-write-failure graceful killed

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
