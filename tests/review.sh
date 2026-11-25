#!/bin/bash
# Local review checklist. Only --live runs the Codex end-to-end checks.
set -u
set -o pipefail

LIVE=no
GUI=no
for arg in "$@"; do
  case $arg in
    --live) LIVE=yes ;;
    --gui) GUI=yes ;;
    *) printf 'unknown arg %s\n' "$arg" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/.." || exit 1

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
    if [ -n "$output" ]; then printf '%s\n' "$output"; fi
  fi
}

shell_syntax() {
  find . \( -name .git -o -name .claude -o -name .codex-briefs \) -prune -o \
    -type f -name '*.sh' -exec bash -c '
      status=0
      for script do
        bash -n "$script" || status=1
      done
      exit "$status"
    ' bash {} +
}

manifest=plugins/codex-workers/.claude-plugin/plugin.json
version_filter='.version | select(type == "string" and length > 0)'
installed_version() {
  local expected versions
  expected=$(jq -er "$version_filter" "$manifest") || return 1
  versions=$(jq -r '
    .plugins | to_entries[]
    | select(.key | startswith("codex-workers@"))
    | .value[] | select(.scope == "user") | .version
  ' "$HOME/.claude/plugins/installed_plugins.json") || return 1
  if ! grep -Fxq -- "$expected" <<<"$versions"; then
    printf 'Expected user-scope version %s, found %s\n' "$expected" "${versions:-none}"
    return 1
  fi
}

version_monotonic() {
  local head_version main_version
  head_version=$(git show "HEAD:$manifest" | jq -er "$version_filter") || return 1
  main_version=$(git show "origin/main:$manifest" | jq -er "$version_filter") || return 1
  ruby -rrubygems -e '
    head, main = ARGV
    if Gem::Version.new(head) < Gem::Version.new(main)
      abort "Plugin version on HEAD (#{head}) is lower than origin/main (#{main})."
    end
  ' "$head_version" "$main_version"
}

echo "== 1. Repository checks"
check "shell syntax" shell_syntax
check "Ruby rate-limiter tests" ruby -Ilib -Itest test/test_rate_limiter.rb
check "Codex queue tests" bash tests/test_codex_queue.sh
check "Codex run wrapper tests" bash tests/test_codex_run.sh
check "usage check tests" bash tests/test_codex_usage.sh
check "banked-resets refresh tests" bash tests/test_resets_refresh.sh
check "installer tests" bash tests/test_install.sh
check "Claude budget tests" bash tests/test_claude_budget.sh
check "claude plugin validate ." claude plugin validate .
check "claude plugin test plugins/codex-workers" claude plugin test plugins/codex-workers

echo "== 2. Install and version checks"
check "installed skill matches repo" diff -rq skills/codex "$HOME/.claude/skills/codex"
check "installed user-scope plugin version matches repo" installed_version
if git rev-parse --verify --quiet origin/main >/dev/null; then
  check "plugin version on HEAD is at least origin/main" version_monotonic
else
  echo "  SKIP plugin version comparison (origin/main unavailable)"
fi

if [ "$LIVE" = yes ]; then
  echo "== 3. Live end-to-end checks"
  if [ "$GUI" = yes ]; then
    check "tests/e2e.sh --gui" tests/e2e.sh --gui
  else
    check "tests/e2e.sh" tests/e2e.sh
  fi
fi

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
