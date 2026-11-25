#!/bin/bash
set -u
set -o pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd) || exit 1
REFRESH=$REPO/skills/codex/scripts/codex-resets-refresh.sh
temp_root=${TMPDIR:-/tmp}
TEMP=$(mktemp -d "${temp_root%/}/codex-resets-test.XXXXXX") || exit 1
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

cat > "$TEMP/codex stub" <<'STUB' || exit 1
#!/bin/bash
if [[ -n ${RESETS_TEST_ENTERED:-} ]]; then
  : > "$RESETS_TEST_ENTERED"
fi
if [[ -n ${RESETS_TEST_GATE:-} ]]; then
  for ((attempt=0; attempt<100; attempt++)); do
    [[ -f "$RESETS_TEST_GATE" ]] && break
    sleep 0.05
  done
  [[ -f "$RESETS_TEST_GATE" ]] || exit 1
fi
cat >/dev/null || exit 1
case $RESETS_TEST_RESPONSE in
  valid)
    printf '%s\n' '{"id":1,"jsonrpc":"2.0","result":{}}'
    printf '%s\n' '{"id":2,"jsonrpc":"2.0","result":{"rateLimitResetCredits":{"availableCount":2,"credits":[{"title":"Later reset","expiresAt":1735776000,"status":"available"},{"title":"Used reset","expiresAt":1735603200,"status":"redeemed"},{"title":"Earlier reset","expiresAt":1735689600,"status":"available"}]}}}'
    ;;
  empty)
    printf '%s\n' '{"id":2,"jsonrpc":"2.0","result":{"rateLimitResetCredits":{"availableCount":0,"credits":[]}}}'
    ;;
  reordered)
    printf '%s\n' 'not JSON' '{"id":20,"result":{"rateLimitResetCredits":{"availableCount":20}}}' \
      '   { "jsonrpc": "2.0", "result": {"rateLimitResetCredits":{"availableCount":3}}, "id": 2 }'
    ;;
  invalid_expiry)
    printf '%s\n' '{"id":2,"result":{"rateLimitResetCredits":{"availableCount":1,"credits":[{"expiresAt":"invalid","status":"available"}]}}}'
    ;;
  missing)
    printf '%s\n' '{"id":1,"jsonrpc":"2.0","result":{}}' '{"jsonrpc":"2.0","method":"account/rateLimits/updated"}'
    ;;
  garbage)
    printf '%s\n' 'not JSON' '{"id":2,this is malformed'
    ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$TEMP/codex stub" || exit 1
mkdir "$TEMP/cache" || exit 1
export CODEX_BIN="$TEMP/codex stub" CODEX_RESETS_FILE="$TEMP/cache/resets.json"
export CODEX_RESETS_WAIT=1 TZ=UTC0

refresh_status() {
  local expected=$1 status=0
  RESETS_TEST_RESPONSE=$2 "$REFRESH" || status=$?
  if [[ $status != "$expected" ]]; then
    printf 'Expected exit %s, got %s\n' "$expected" "$status"
    return 1
  fi
}

no_temp_files() (
  shopt -s dotglob nullglob
  local_entries=("$TEMP/cache/"*)
  if [[ ${#local_entries[@]} -ne 1 || ${local_entries[0]} != "$CODEX_RESETS_FILE" ]]; then
    printf 'Expected only %s in cache directory. Found:\n' "$CODEX_RESETS_FILE"
    printf '  %s\n' "${local_entries[@]}"
    return 1
  fi
)

echo '== Resets refresh'
printf '%s\n' '{"available":99,"credits":[]}' > "$TEMP/original.json" || exit 1
cp "$TEMP/original.json" "$CODEX_RESETS_FILE" || exit 1
ln "$CODEX_RESETS_FILE" "$TEMP/old-cache-link" || exit 1

check 'a valid answer exits 0' refresh_status 0 valid
check 'the cache contains two credits with the earliest expiry date' jq -e '
  .available == 2 and .expires == "2025-01-01" and
  .credits == [
    {"title":"Later reset","expiresAt":1735776000,"status":"available"},
    {"title":"Earlier reset","expiresAt":1735689600,"status":"available"}
  ]
' "$CODEX_RESETS_FILE"
check 'the refresh replaces the cache without rewriting the old file' \
  cmp "$TEMP/original.json" "$TEMP/old-cache-link"
check 'the refresh leaves no temporary files' no_temp_files

check 'a zero-credit answer exits 0' refresh_status 0 empty
check 'the cache contains zero credits, an empty array and a null expiry' jq -e '
  .available == 0 and .credits == [] and has("expires") and .expires == null
' "$CODEX_RESETS_FILE"

cp "$CODEX_RESETS_FILE" "$TEMP/before-missing.json" || exit 1
check 'an answer without id 2 exits 1' refresh_status 1 missing
check 'an answer without id 2 leaves the existing cache unchanged' \
  cmp "$TEMP/before-missing.json" "$CODEX_RESETS_FILE"
check 'garbage output exits 1' refresh_status 1 garbage

check 'the response matches numeric id 2 despite whitespace and key order' refresh_status 0 reordered
check 'the cache uses id 2 instead of id 20' jq -e '.available == 3' "$CODEX_RESETS_FILE"

overlapping_refresh() {
  local first status=0 attempt
  RESETS_TEST_ENTERED="$TEMP/first-entered" RESETS_TEST_RESPONSE=valid \
    RESETS_TEST_GATE="$TEMP/first-release" "$REFRESH" &
  first=$!
  for ((attempt=0; attempt<100; attempt++)); do
    [[ -f "$TEMP/first-entered" ]] && break
    sleep 0.05
  done
  if [[ ! -f "$TEMP/first-entered" ]]; then
    wait "$first"
    return 1
  fi
  RESETS_TEST_ENTERED="$TEMP/second-entered" refresh_status 0 empty || status=1
  : > "$TEMP/first-release"
  wait "$first" || status=1
  [[ $status == 0 && ! -e "$TEMP/second-entered" ]]
}
check 'an overlapping refresh exits 0 without starting the app-server' overlapping_refresh
check 'the first refresh writes the cache' jq -e '.available == 2' "$CODEX_RESETS_FILE"
check 'the lock is gone after the first refresh' no_temp_files

stale_refresh() {
  local dead_pid
  (exit 0) &
  dead_pid=$!
  wait "$dead_pid" || return 1
  mkdir -p "$CODEX_RESETS_FILE.lock/$dead_pid" || return 1
  refresh_status 0 empty &&
    jq -e '.available == 0' "$CODEX_RESETS_FILE" &&
    no_temp_files
}
check 'a refresh takes over a stale lock and removes it on exit' stale_refresh

transform_fails() { ! RESETS_TEST_RESPONSE=invalid_expiry "$REFRESH"; }
cp "$CODEX_RESETS_FILE" "$TEMP/before-write-failure.json" || exit 1
check 'a failed jq transformation exits nonzero' transform_fails
check 'a failed jq transformation leaves no temporary files' no_temp_files
check 'a failed jq transformation preserves the cache' cmp "$TEMP/before-write-failure.json" "$CODEX_RESETS_FILE"

mkdir "$TEMP/failing-tools" || exit 1
printf '%s\n' '#!/bin/bash' 'exit 1' > "$TEMP/failing-tools/mv" || exit 1
chmod +x "$TEMP/failing-tools/mv" || exit 1
PATH="$TEMP/failing-tools:$PATH" check 'a failed rename exits 1' refresh_status 1 valid
check 'a failed rename leaves no temporary files' no_temp_files
check 'a failed rename preserves the cache' cmp "$TEMP/before-write-failure.json" "$CODEX_RESETS_FILE"

echo "== $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
