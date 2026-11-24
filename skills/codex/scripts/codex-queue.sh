#!/bin/bash
set -u
set -o pipefail
shopt -s nullglob

script_dir=$(cd "$(dirname "$0")" && pwd) || exit 1
queue_dir=${CODEX_QUEUE_DIR:-"$HOME/.claude/codex-queue"}
runs_dir=${CODEX_RUNS_DIR:-"$HOME/.claude/codex-runs"}
usage_cmd=${CODEX_USAGE_CMD:-"$script_dir/codex-usage.sh"}
run_cmd=${CODEX_RUN_CMD:-"$script_dir/codex-run.sh"}

fail() { printf 'codex-queue: %s\n' "$*" >&2; exit 1; }
usage() {
  cat >&2 <<'EOF'
Usage: codex-queue.sh add <effort> <sandbox> <workdir> <brief> [--batch NAME] [--priority N] [--model M]
       codex-queue.sh list [--json]
       codex-queue.sh drain [--max N] [--dry-run]
       codex-queue.sh failed [--json]
       codex-queue.sh requeue <id>
       codex-queue.sh remove <id>
       codex-queue.sh prune
EOF
  exit 2
}

lock_queue() {
  mkdir -p -- "$queue_dir" || exit 1
  lock_dir=$queue_dir/.lock
  mkdir -- "$lock_dir" 2>/dev/null || fail "cannot acquire queue lock: $lock_dir"
  trap 'rmdir -- "$lock_dir"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

add_entry() {
  [[ $# -ge 4 ]] || usage
  local effort=$1 sandbox=$2 workdir=$3 brief=$4
  local batch=adhoc priority=0 model='null' name timestamp created id staging
  shift 4
  case $effort in low|medium|high) ;; *) usage ;; esac
  case $sandbox in read-only|workspace-write) ;; *) usage ;; esac
  while [[ $# -gt 0 ]]; do
    [[ $# -ge 2 ]] || usage
    case $1 in
      --batch) batch=$2 ;;
      --priority) [[ $2 =~ ^-?(0|[1-9][0-9]*)$ ]] || usage; priority=$2 ;;
      --model) model=$(jq -n --arg model "$2" '$model') || exit 1 ;;
      *) usage ;;
    esac
    shift 2
  done
  [[ -d $workdir ]] || fail "workdir is not a directory: $workdir"
  [[ -f $brief ]] || fail "brief is not a file: $brief"
  case $workdir in /*) ;; *) workdir=$PWD/$workdir ;; esac
  case $brief in /*) ;; *) brief=$PWD/$brief ;; esac
  name=${brief##*/}
  name=${name%.md}
  timestamp=$(date '+%Y%m%d-%H%M%S %s') || exit 1
  created=${timestamp##* }

  mkdir -p -- "$queue_dir" || exit 1
  # Hold the ID until its JSON is published, even when adds overlap.
  while :; do
    staging=$(mktemp -d "$queue_dir/.${timestamp% *}-XXXX") || exit 1
    id=${staging##*/.}
    [[ ! -e $queue_dir/$id.json ]] && break
    rmdir -- "$staging" || exit 1
  done
  if jq -n --arg id "$id" --arg name "$name" --arg batch "$batch" \
    --arg brief "$brief" --arg workdir "$workdir" --arg effort "$effort" \
    --arg sandbox "$sandbox" --argjson model "$model" --argjson priority "$priority" \
    --argjson created_at "$created" \
    '{$id, $name, $batch, $brief, $workdir, $effort, $sandbox, $model, $priority,
      $created_at, status: "queued", launched_at: null, run_log: null}' > "$staging/entry" &&
    mv -f -- "$staging/entry" "$queue_dir/$id.json"; then
    rmdir -- "$staging" || exit 1
    printf '%s\n' "$id"
  else
    rm -f -- "$staging/entry"
    rmdir -- "$staging"
    exit 1
  fi
}

queued_entries() {
  local record
  for record in "$queue_dir"/*.json; do
    # An entry can disappear while listing if remove or prune runs concurrently.
    cat -- "$record" 2>/dev/null || [[ ! -e $record ]] || return 1
  done | jq -cs '[.[] | select(.status == "queued")] | sort_by(-.priority, .created_at, .id)'
}

pid_alive() {
  [[ $1 =~ ^[1-9][0-9]*$ ]] && kill -0 "$1" 2>/dev/null
}

occupied_slots() {
  local record fields status pid launcher published=' ' count=0
  for record in "$runs_dir"/*.json; do
    fields=$(jq -r '[.status, .pid] | @tsv' "$record" 2>/dev/null) || continue
    IFS=$'\t' read -r status pid <<< "$fields"
    if [[ $status == running ]] && pid_alive "$pid"; then
      count=$((count + 1))
    fi
    case $status in
      running|done|failed|killed)
        # The launcher PID is in the record ID. The JSON pid is the worker PID.
        launcher=${record##*-}
        published="$published${launcher%.json} "
        ;;
    esac
  done
  for record in "$queue_dir"/.launch-*; do
    pid=$(cat -- "$record" 2>/dev/null) || continue
    if pid_alive "$pid" && [[ $published != *" $pid "* ]]; then
      count=$((count + 1))
    elif [[ $dry_run == no ]]; then
      rm -f -- "$record" || return 1
    fi
  done
  printf '%s\n' "$count"
}

launch_entry() {
  local now pid
  now=$(date +%s) || return 1
  jq --argjson now "$now" --arg log "$log" \
    '.status = "launched" | .launched_at = $now | .run_log = $log' <<< "$entry" > "$lock_dir/entry" &&
    mv -f -- "$lock_dir/entry" "$queue_dir/$id.json" || {
    rm -f -- "$lock_dir/entry"
    return 1
  }
  (
    export CODEX_BATCH="$batch"
    if [[ -n $model ]]; then export CODEX_MODEL="$model"; fi
    exec nohup "$run_cmd" "$effort" "$sandbox" "$workdir" "$brief"
  ) </dev/null > "$log" 2>&1 3>&- &
  pid=$!
  printf '%s\n' "$pid" >&3
}

drain() {
  local max=4 dry_run=no status=UNKNOWN usage_output occupied slots=0
  local entries entry id effort sandbox workdir brief batch model log selected=0 drained=0 remaining
  while [[ $# -gt 0 ]]; do
    case $1 in
      --max)
        [[ $# -ge 2 && $2 =~ ^(0|[1-9][0-9]*)$ ]] || usage
        max=$2; shift ;;
      --dry-run) dry_run=yes ;;
      *) usage ;;
    esac
    shift
  done
  if [[ $dry_run == no ]]; then lock_queue; fi

  if usage_output=$("$usage_cmd"); then
    case ${usage_output##*$'\n'} in
      STATUS=OK|STATUS=OK\ *) status=OK ;;
      STATUS=THROTTLE|STATUS=THROTTLE\ *) status=THROTTLE ;;
      STATUS=SQUEEZE|STATUS=SQUEEZE\ *) status=SQUEEZE ;;
      STATUS=BLOCKED|STATUS=BLOCKED\ *) status=BLOCKED ;;
    esac
  fi
  case $status in
    OK)
      occupied=$(occupied_slots) || exit 1
      slots=$((max - occupied))
      ;;
    THROTTLE|SQUEEZE)
      # One worker at a time, not one per drain: running workers use up the slot.
      occupied=$(occupied_slots) || exit 1
      slots=$((1 - occupied))
      ;;
  esac

  entries=$(queued_entries | jq -c '.[]') || exit 1
  while IFS= read -r entry; do
    [[ -n $entry && $selected -lt $slots ]] || break
    {
      IFS= read -r -d '' id && IFS= read -r -d '' effort && IFS= read -r -d '' sandbox &&
        IFS= read -r -d '' workdir && IFS= read -r -d '' brief && IFS= read -r -d '' batch &&
        IFS= read -r -d '' model
    } < <(jq -j '[.id, .effort, .sandbox, .workdir, .brief, .batch, (.model // "")] | .[] + "\u0000"' <<< "$entry") || exit 1
    if [[ $status == THROTTLE && $effort != low ]]; then continue; fi
    # SQUEEZE (the 5h window is 90-97% used): backlog work only, i.e. priority < 0 and low effort.
    if [[ $status == SQUEEZE ]] && ! jq -e '.effort == "low" and ((.priority // 0) < 0)' <<< "$entry" >/dev/null; then continue; fi
    log=$brief.queue.out
    if [[ $dry_run == yes ]]; then
      printf 'Would launch %s\n' "$id"
    else
      launch_entry 3> "$queue_dir/.launch-$id" || exit 1
      printf '%s\n' "$id"
      drained=$((drained + 1))
    fi
    selected=$((selected + 1))
  done <<< "$entries"
  remaining=$(queued_entries | jq 'length') || exit 1
  printf 'DRAINED=%s QUEUED=%s STATUS=%s\n' "$drained" "$remaining" "$status"
}

case ${1:-} in
  add) shift; add_entry "$@" ;;
  list)
    case $#:${2:-} in
      1:) queued_entries | jq -r '.[] | [.id, .priority, .effort, .sandbox, .name, .batch] | @tsv' ;;
      2:--json) queued_entries ;;
      *) usage ;;
    esac
    ;;
  drain) shift; drain "$@" ;;
  failed)
    # Launched entries whose latest run record (same brief, started at or after launch) failed.
    [[ $# -le 2 ]] || usage
    out=$(for entry in "$queue_dir"/*.json; do
      jq -c 'select(.status == "launched")' "$entry" 2>/dev/null
    done | while IFS= read -r e; do
      brief=$(jq -r '.brief' <<< "$e"); since=$(jq -r '(.launched_at // 0) - 5' <<< "$e")
      run=$(for r in "$runs_dir"/*.json; do
        jq -c --arg b "$brief" --argjson s "$since" 'select(.brief == $b and .started_at >= $s)' "$r" 2>/dev/null
      done | jq -sc 'sort_by(.started_at) | last // empty')
      [[ -n $run ]] || continue
      jq -c --argjson run "$run" 'select($run.status == "failed" or $run.status == "killed")
        | {id, name, batch, effort, priority, brief, workdir,
           failure: ($run.failure // $run.status), exit_code: $run.exit_code, run_id: $run.id}' <<< "$e"
    done | jq -s '.')
    case ${2:-} in
      --json) printf '%s\n' "$out" ;;
      '') jq -r '.[] | [.id, .failure, .effort, .name, .brief] | @tsv' <<< "$out" ;;
      *) usage ;;
    esac
    ;;
  requeue)
    [[ $# -eq 2 && $2 =~ ^[0-9]{8}-[0-9]{6}-[[:alnum:]]{4}$ ]] || usage
    lock_queue
    file=$queue_dir/$2.json
    [[ -f $file ]] || fail "no such entry: $2"
    tmp=$(mktemp "$file.XXXXXX") || exit 1
    jq '.status = "queued" | .launched_at = null | .run_log = null' "$file" > "$tmp" && mv -f -- "$tmp" "$file"
    printf '%s\n' "$2"
    ;;
  remove)
    [[ $# -eq 2 && $2 =~ ^[0-9]{8}-[0-9]{6}-[[:alnum:]]{4}$ ]] || usage
    lock_queue
    rm -f -- "$queue_dir/$2.json"
    ;;
  prune)
    [[ $# -eq 1 ]] || usage
    lock_queue
    now=$(date +%s) || exit 1
    cutoff=$((now - 7 * 24 * 60 * 60))
    for record in "$queue_dir"/*.json; do
      if jq -e --argjson cutoff "$cutoff" \
        '.status == "launched" and (.launched_at | type == "number" and . < $cutoff)' "$record" >/dev/null; then
        rm -f -- "$record" || exit 1
      fi
    done
    ;;
  *) usage ;;
esac
