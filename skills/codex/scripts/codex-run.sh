#!/bin/bash
# Usage: codex-run.sh <low|medium> <read-only|workspace-write> <workdir> <brief-file>
set -u

# Works on macOS and on Windows under Git Bash (MSYS).
APP_CODEX=/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex
# Windows: the Codex app unpacks its CLI under a per-version hash directory.
WIN_CODEX=
if [ -n "${LOCALAPPDATA:-}" ]; then
  WIN_CODEX=$(ls -t "$LOCALAPPDATA"/OpenAI/Codex/bin/*/codex.exe 2>/dev/null | head -1)
fi
if [ -n "${CODEX_BIN:-}" ]; then CODEX=$CODEX_BIN
elif [ -x "$APP_CODEX" ]; then CODEX=$APP_CODEX
elif [ -n "$WIN_CODEX" ]; then CODEX=$WIN_CODEX
else CODEX=$(command -v codex || echo codex)
fi
JQ=$(command -v jq || true)
if [ -z "$JQ" ] && [ -n "${LOCALAPPDATA:-}" ]; then   # winget install jqlang.jq (its Links alias is invisible to MSYS)
  JQ=$(ls "$LOCALAPPDATA"/Microsoft/WinGet/Packages/jqlang.jq_*/jq.exe 2>/dev/null | head -1)
fi
JQ=${JQ:-/usr/bin/jq}
RUNS_DIR=${CODEX_RUNS_DIR:-"$HOME/.claude/codex-runs"}
BATCH=${CODEX_BATCH:-adhoc}
EFFORT=$1
SB=$2
DIR=$3
BRIEF=$4
SBARGS=(-s "$SB")

brief_path=$BRIEF
workdir_path=$DIR
case $brief_path in /*|[A-Za-z]:[/\\]*) ;; *) brief_path=$PWD/$brief_path;; esac
case $workdir_path in /*|[A-Za-z]:[/\\]*) ;; *) workdir_path=$PWD/$workdir_path;; esac
# On Windows, record native paths (C:/...) so non-MSYS readers such as the plugin can open them.
if command -v cygpath >/dev/null 2>&1; then
  brief_path=$(cygpath -m -- "$brief_path")
  workdir_path=$(cygpath -m -- "$workdir_path")
fi
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
    --arg effort "$EFFORT" --arg sandbox "$SB" --argjson pid "$child_pid" \
    --arg status "$1" --argjson exit_code "$2" \
    --argjson started_at "$started_at" --argjson ended_at "$3" \
    '{
      $id, $name, $batch, $brief, $workdir, $effort, $sandbox, $pid,
      $status, $exit_code, $started_at, $ended_at,
      events: ($brief + ".events.jsonl"),
      result: ($brief + ".result"),
      log: ($brief + ".log")
    }' > "$record.tmp" && mv -f -- "$record.tmp" "$record"
}

prune_records() (
  LC_ALL=C
  shopt -s nullglob
  # IDs sort by start time, so finalizing a record does not change its rank.
  records=("$RUNS_DIR"/*.json)
  excess=$((${#records[@]} - 50))
  if (( excess > 0 )); then
    rm -f -- "${records[@]:0:excess}"
  fi
)

child_pid=
interrupted=
finish_killed() {
  trap '' INT TERM HUP
  kill -TERM "$child_pid" 2>/dev/null
  write_record killed 130 "$(date +%s)"
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

"$CODEX" exec --json -m gpt-6.2-sol -c "model_reasoning_effort=\"$EFFORT\"" "${SBARGS[@]}" \
  --skip-git-repo-check -C "$DIR" -o "$BRIEF.result" - \
  < "$BRIEF" > "$BRIEF.events.jsonl" 2> "$BRIEF.log" &
child_pid=$!
if [[ -n $interrupted ]]; then
  finish_killed
fi
write_record running null null
prune_records

wait "$child_pid"
rc=$?
status=failed
if (( rc == 0 )); then
  status=done
fi
write_record "$status" "$rc" "$(date +%s)"
prune_records

echo "codex exit=$rc  result=$BRIEF.result  log=$BRIEF.log"
grep -iE 'rate.?limit|usage limit|quota' "$BRIEF.log" | tail -3
"$(dirname "$0")/codex-usage.sh"
exit "$rc"
