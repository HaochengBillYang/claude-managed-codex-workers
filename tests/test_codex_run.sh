#!/bin/bash
# Tests codex-run.sh failure classification and the stall watchdog with stub codex binaries.
# Never runs the real codex. bash 3.2 compatible; works with BSD and GNU tools.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
RUN=$REPO/skills/codex/scripts/codex-run.sh
TEMP=$(mktemp -d); trap 'rm -rf "$TEMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

# A usage stub, so the wrapper's trailing usage report needs no real Codex data.
mkdir -p "$TEMP/bin"
stub() { printf '#!/bin/bash\ncat >/dev/null\n%s\n' "$2" > "$TEMP/bin/$1"; chmod +x "$TEMP/bin/$1"; }
stub ok      'echo "{\"type\":\"thread.started\"}"; exit 0'
stub hang    'echo "{\"type\":\"thread.started\"}"; sleep 30; exit 0'
stub limit   'echo "{\"type\":\"thread.started\"}"; echo "ERROR: You have hit your usage limit." >&2; exit 1'
stub failevt 'echo "{\"type\":\"turn.failed\",\"error\":{\"message\":\"rate_limit_reached: try later\"}}"; exit 1'
stub quotaout 'echo "{\"type\":\"item.completed\",\"item\":{\"type\":\"command_execution\",\"aggregated_output\":\"no Codex quota was spent\"}}"; exit 3'

run_case() { # name stub -> prints "status failure"
  local name=$1 bin=$2
  printf '# brief\n' > "$TEMP/$name.md"
  CODEX_BIN="$TEMP/bin/$bin" CODEX_RUNS_DIR="$TEMP/runs-$name" CODEX_IDLE_TIMEOUT=2 CODEX_WATCHDOG_INTERVAL=1 \
    "$RUN" low read-only "$TEMP" "$TEMP/$name.md" >/dev/null 2>&1
  jq -r '"\(.status) \(.failure)"' "$TEMP/runs-$name"/*.json
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

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
