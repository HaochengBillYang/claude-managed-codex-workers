#!/bin/bash
# Usage: codex-run.sh <low|medium|high> <read-only|workspace-write> <workdir> <brief-file> (model: $CODEX_MODEL, default gpt-6.2-sol)
set -u

APP_CODEX=/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex
if [ -n "${CODEX_BIN:-}" ]; then CODEX=$CODEX_BIN
elif [ -x "$APP_CODEX" ]; then CODEX=$APP_CODEX
else CODEX=$(command -v codex || echo codex)
fi
JQ=$(command -v jq) || JQ=/usr/bin/jq
RUNS_DIR=${CODEX_RUNS_DIR:-"$HOME/.claude/codex-runs"}
BATCH=${CODEX_BATCH:-adhoc}
EFFORT=$1
SB=$2
DIR=$3
BRIEF=$4
SBARGS=(-s "$SB")

brief_path=$BRIEF
workdir_path=$DIR
case $brief_path in /*) ;; *) brief_path=$PWD/$brief_path;; esac
case $workdir_path in /*) ;; *) workdir_path=$PWD/$workdir_path;; esac
name=${BRIEF##*/}
name=${name%.md}

mkdir -p -- "$RUNS_DIR" || exit 1
# Derive the ID and epoch timestamp from the same clock reading.
timestamp=$(date '+%Y%m%d-%H%M%S %s') || exit 1
id=${timestamp% *}-$$
started_at=${timestamp##* }
record=$RUNS_DIR/$id.json

write_record() {
  "$JQ" -n \
    --arg id "$id" --arg name "$name" --arg batch "$BATCH" \
    --arg brief "$brief_path" --arg workdir "$workdir_path" \
    --arg effort "$EFFORT" --arg model "${CODEX_MODEL:-gpt-6.2-sol}" \
    --arg sandbox "$SB" --argjson pid "$child_pid" \
    --arg status "$1" --argjson exit_code "$2" \
    --argjson started_at "$started_at" --argjson ended_at "$3" \
    --arg failure "${FAILURE:-}" \
    '{
      $id, $name, $batch, $brief, $workdir, $effort, $model, $sandbox, $pid,
      $status, $exit_code, $started_at, $ended_at,
      failure: (if $failure == "" then null else $failure end),
      events: ($brief + ".events.jsonl"),
      result: ($brief + ".result"),
      log: ($brief + ".log")
    }' > "$record.tmp" && mv -f -- "$record.tmp" "$record"
}

write_final_record() {
  local ended_at
  if ! ended_at=$(date +%s) || ! write_record "$1" "$2" "$ended_at"; then
    printf 'codex-run: failed to write final record %s (status %s)\n' "$record" "$1" >&2
    exit 1
  fi
}

prune_records() (
  LC_ALL=C
  shopt -s nullglob
  # IDs sort by start time, so finalizing a record does not change its rank.
  records=("$RUNS_DIR"/*.json)
  excess=$((${#records[@]} - 50))
  for ((i=0; i<excess; i++)); do
    candidate=${records[i]}
    pid=$("$JQ" -r 'select(.status == "running") | .pid |
      select(type == "number" and . > 0 and . <= 2147483647 and . == floor)' \
      "$candidate" 2>/dev/null) || continue
    if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
      continue
    fi
    rm -f -- "$candidate"
  done
)

child_pid=
watchdog_pid=
interrupted=
finish_killed() {
  trap '' INT TERM HUP
  local deadline=$((SECONDS + 10))
  if [[ -n $watchdog_pid ]]; then
    kill "$watchdog_pid" 2>/dev/null
  fi
  kill -TERM "$child_pid" 2>/dev/null
  while kill -0 "$child_pid" 2>/dev/null && (( SECONDS < deadline )); do
    sleep 0.1
  done
  if kill -0 "$child_pid" 2>/dev/null; then
    kill -KILL "$child_pid" 2>/dev/null
  fi
  wait "$child_pid" 2>/dev/null
  write_final_record killed 130
  prune_records
  exit 130
}
on_signal() {
  interrupted=yes
  if [[ -n $child_pid ]]; then
    finish_killed
  fi
}
trap on_signal INT TERM HUP

"$CODEX" exec --json -m "${CODEX_MODEL:-gpt-6.2-sol}" -c "model_reasoning_effort=\"$EFFORT\"" "${SBARGS[@]}" \
  --skip-git-repo-check -C "$DIR" -o "$BRIEF.result" - \
  < "$BRIEF" > "$BRIEF.events.jsonl" 2> "$BRIEF.log" &
child_pid=$!
if [[ -n $interrupted ]]; then
  finish_killed
fi
write_record running null null
prune_records

# Watchdog: a worker whose event stream stays silent for CODEX_IDLE_TIMEOUT seconds (default
# 20 min) is stopped and recorded as `stalled`, e.g. after the Mac slept mid-run. Otherwise
# a hung worker would hold a THROTTLE/SQUEEZE slot forever.
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
IDLE=${CODEX_IDLE_TIMEOUT:-1200}
rm -f -- "$BRIEF.stalled"
(
  while kill -0 "$child_pid" 2>/dev/null; do
    sleep "${CODEX_WATCHDOG_INTERVAL:-30}"
    last=$(mtime "$BRIEF.events.jsonl")
    if [ $(( $(date +%s) - last )) -gt "$IDLE" ]; then
      : > "$BRIEF.stalled"; kill -TERM "$child_pid" 2>/dev/null; break
    fi
  done
) &
watchdog_pid=$!

wait "$child_pid"
rc=$?
kill "$watchdog_pid" 2>/dev/null; wait "$watchdog_pid" 2>/dev/null
status=failed
FAILURE=
if (( rc == 0 )); then
  status=done
elif [ -f "$BRIEF.stalled" ]; then
  FAILURE=stalled
  rm -f -- "$BRIEF.stalled"
# Classify limits only from Codex's own stderr and its error/turn.failed events: never from
# item output, which may quote any text (a worker reading a file that says "quota" is not a limit).
elif { cat "$BRIEF.log" 2>/dev/null
       "$JQ" -c 'select(.type == "error" or .type == "turn.failed")' "$BRIEF.events.jsonl" 2>/dev/null
     } | grep -qiE "usage limit|rate.?limit.?(reached|exceeded)|rate_limit_reached|quota|\b429\b"; then
  FAILURE=rate_limit   # Codex hit its limit mid-run: a candidate for the Claude fallback
else
  FAILURE=error
fi
write_final_record "$status" "$rc"
prune_records

echo "codex exit=$rc  result=$BRIEF.result  log=$BRIEF.log"
grep -iE 'rate.?limit|usage limit|quota' "$BRIEF.log" | tail -3
"$(dirname "$0")/codex-usage.sh"
exit "$rc"
