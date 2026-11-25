#!/bin/bash
set -u
set -o pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd) || exit 1
USAGE=$REPO/skills/codex/scripts/codex-usage.sh
TEMP=$(mktemp -d /tmp/codex-usage-test.XXXXXX) || exit 1
trap 'rm -rf -- "$TEMP"' EXIT

export HOME="$TEMP/home" TZ=UTC0 LC_ALL=C
unset CODEX_RESETS_FILE CODEX_SQUEEZE_MAX
mkdir -p "$HOME/.codex/sessions" "$HOME/.claude" "$TEMP/bin" || exit 1
SESSION=$HOME/.codex/sessions/x.jsonl
RESETS=$HOME/.claude/codex-resets.json

# Use a single current timestamp for the fixtures and every invocation.
USAGE_TEST_NOW=$(/bin/date +%s) || exit 1
export USAGE_TEST_NOW
USAGE_TEST_PLATFORM=$(uname -s) || exit 1
export USAGE_TEST_PLATFORM
cat > "$TEMP/bin/date" <<'STUB'
#!/bin/bash
if [[ $# -eq 1 && $1 == +%s ]]; then
  printf '%s\n' "$USAGE_TEST_NOW"
elif [[ $USAGE_TEST_PLATFORM == Linux && $1 == -r ]]; then
  /bin/date -d "@$2" "$3"
elif [[ $USAGE_TEST_PLATFORM == Linux && $1 == -j && $2 == -f ]]; then
  /bin/date -d "$4" "$5"
else
  /bin/date "$@"
fi
STUB
cat > "$TEMP/bin/stat" <<'STUB'
#!/bin/bash
if [[ $USAGE_TEST_PLATFORM == Linux && $1 == -f && $2 == %m ]]; then
  /usr/bin/stat -c %Y "$3"
else
  /usr/bin/stat "$@"
fi
STUB
cat > "$TEMP/bin/codex" <<'STUB'
#!/bin/bash
touch "$HOME/codex-called"
exit 1
STUB
chmod +x "$TEMP/bin/"* || exit 1
export PATH="$TEMP/bin:$PATH"

PRIMARY_RESET=$((USAGE_TEST_NOW + 2 * 3600))
WEEKLY_RESET=$((USAGE_TEST_NOW + 18 * 3600 * 7))
PAST_RESET=$((USAGE_TEST_NOW - 60))
EXPIRY=$(date -r "$USAGE_TEST_NOW" +%Y-%m-%d) || exit 1

fixture() {
  local primary=$1 weekly=$2 resets=${3:-0} reached=${4:-null}
  local primary_reset=${5:-$PRIMARY_RESET} weekly_reset=${6:-$WEEKLY_RESET}
  local expires=${7:-}
  printf '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":%s,"resets_at":%s,"window_minutes":300},"secondary":{"used_percent":%s,"resets_at":%s,"window_minutes":10080},"rate_limit_reached_type":%s}}}\n' \
    "$primary" "$primary_reset" "$weekly" "$weekly_reset" "$reached" > "$SESSION" || return 1
  # A fresh zero-reset cache exercises the no-resets path without a refresh.
  printf '{"updated":%s,"available":%s,"expires":"%s"}\n' \
    "$USAGE_TEST_NOW" "$resets" "$expires" > "$RESETS"
}

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

check() {
  local description=$1 expected=$2 output
  shift 2
  fixture "$@" || exit 1
  if output=$("$USAGE" 2>&1) && [[ ${output##*$'\n'} == "$expected" ]]; then
    ok "$description"
  else
    bad "$description"
    printf 'Expected final line:\n%s\nActual output:\n%s\n' "$expected" "$output"
  fi
}

echo '== Usage status'
check 'OK below the throttle thresholds' 'STATUS=OK' 69 40
check 'THROTTLE at 70% even when weekly usage is on pace' \
  'STATUS=THROTTLE REASON=5h=70%,weekly_ahead_of_pace_by=0pts' 70 25
check 'THROTTLE when weekly usage is ahead of pace and no resets are banked' \
  'STATUS=THROTTLE REASON=5h=69%,weekly_ahead_of_pace_by=16pts' 69 41
check 'Banked resets suppress pace-only throttle' 'STATUS=OK RESETS=2' 69 41 2
check 'SQUEEZE at 90% with weekly usage below 95%' \
  "STATUS=SQUEEZE UNTIL=$PRIMARY_RESET REASON=5h=90%" 90 94
check 'SQUEEZE at 96% with weekly usage below 95%' \
  "STATUS=SQUEEZE UNTIL=$PRIMARY_RESET REASON=5h=96%" 96 94
check 'BLOCKED at 97% on the 5-hour window' \
  "STATUS=BLOCKED UNTIL=$PRIMARY_RESET REASON=5h_limit" 97 40
check 'BLOCKED at 90% when rate_limit_reached_type is set' \
  "STATUS=BLOCKED UNTIL=$PRIMARY_RESET REASON=5h_limit" 90 40 0 '"primary"'
check 'BLOCKED at 95% weekly even when 5-hour usage is 93%' \
  "STATUS=BLOCKED UNTIL=$WEEKLY_RESET REASON=weekly_limit" 93 95
check 'A past 5-hour reset makes 100% usage count as zero' \
  'STATUS=OK' 100 25 0 null "$PAST_RESET"
check 'A past weekly reset makes 100% usage count as zero' \
  'STATUS=THROTTLE REASON=5h=70%,weekly_ahead_of_pace_by=-1pts' \
  70 100 0 null "$PRIMARY_RESET" "$PAST_RESET"

echo '== Reset advice'
check 'REDEEM_RECOMMENDED at 50% weekly usage in SQUEEZE' \
  "STATUS=SQUEEZE UNTIL=$PRIMARY_RESET RESETS=2 ADVICE=REDEEM_RECOMMENDED REASON=5h=90%" 90 50 2
check 'REDEEM_OPTIONAL below 50% weekly usage in SQUEEZE' \
  "STATUS=SQUEEZE UNTIL=$PRIMARY_RESET RESETS=2 ADVICE=REDEEM_OPTIONAL REASON=5h=90%" 90 49 2
check 'REDEEM_BEFORE_EXPIRY when resets expire today and usage exceeds 20%' \
  'STATUS=OK RESETS=2 ADVICE=REDEEM_BEFORE_EXPIRY' 21 20 2 null "$PRIMARY_RESET" "$WEEKLY_RESET" "$EXPIRY"

if [[ -e $HOME/codex-called ]]; then
  bad 'The codex stub was invoked'
fi
echo "== $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
