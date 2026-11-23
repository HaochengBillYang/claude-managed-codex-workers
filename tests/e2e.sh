#!/bin/bash
# End-to-end check of the Claude ⇄ Codex worker setup on this machine (macOS).
# Spends a real Codex run (~1% of the 5h window); --gui adds a Calculator run.
#   tests/e2e.sh [--gui] [--keep]
set -u
GUI=no; KEEP=no
for a in "$@"; do case $a in --gui) GUI=yes;; --keep) KEEP=yes;; *) echo "unknown arg $a"; exit 2;; esac; done

REPO=$(cd "$(dirname "$0")/.." && pwd)
SCRIPTS=$HOME/.claude/skills/codex/scripts
RUNS=$HOME/.claude/codex-runs
WORK=$(mktemp -d "${TMPDIR:-/tmp}/codex-e2e.XXXXXX")
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
check(){ local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
cleanup() { [ $KEEP = yes ] && echo "kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

echo "== 1. Install"
check "jq available" command -v jq
check "skill installed" test -x "$SCRIPTS/codex-run.sh" -a -x "$SCRIPTS/codex-usage.sh"
check "installed skill matches repo" diff -rq "$REPO/skills/codex" "$HOME/.claude/skills/codex"
if command -v claude >/dev/null; then
  check "codex-workers plugin installed and enabled" sh -c 'claude plugin list 2>/dev/null | grep -A3 "codex-workers@" | grep -q enabled'
else bad "claude CLI on PATH"; fi

echo "== 2. Usage budget"
usage=$("$SCRIPTS/codex-usage.sh" 2>&1); status=$(printf '%s\n' "$usage" | tail -1)
check "usage script ends with a STATUS line" sh -c "printf '%s' '$status' | grep -qE '^STATUS=(OK|THROTTLE|BLOCKED|UNKNOWN)'"
echo "     $status"
case $status in STATUS=BLOCKED*) echo "Codex is BLOCKED; skipping live runs."; echo "== $PASS passed, $FAIL failed"; exit 1;; esac

echo "== 3. Live worker (low effort, workspace-write)"
cat > "$WORK/brief-e2e.md" <<'EOF'
# Task
Create a file named e2e.txt in the current directory containing exactly the single line: worker-ok
Then run `cat e2e.txt`.
# Constraints
Touch nothing else. Do not commit.
# Report back
The output of `cat e2e.txt`.
EOF
CODEX_BATCH="e2e" "$SCRIPTS/codex-run.sh" low workspace-write "$WORK" "$WORK/brief-e2e.md" > "$WORK/run.out" 2>&1
rc=$?
check "codex-run.sh exited 0" test $rc -eq 0
check "worker wrote the file" sh -c "[ \"\$(cat '$WORK/e2e.txt' 2>/dev/null)\" = worker-ok ]"
check "result file is non-empty" test -s "$WORK/brief-e2e.md.result"
check "event stream has thread.started" grep -q '"thread.started"' "$WORK/brief-e2e.md.events.jsonl"
check "event stream has turn.completed" grep -q '"turn.completed"' "$WORK/brief-e2e.md.events.jsonl"
rec=$(grep -l "\"brief\": \"$WORK/brief-e2e.md\"" "$RUNS"/*.json 2>/dev/null | head -1)
check "run record written" test -n "$rec"
[ -n "$rec" ] && check "run record: batch=e2e, status=done, exit_code=0" \
  jq -e '.batch=="e2e" and .status=="done" and .exit_code==0 and .ended_at!=null' "$rec"
check "wrapper printed usage afterwards" grep -q '^STATUS=' "$WORK/run.out"

if [ $GUI = yes ]; then
  echo "== 4. GUI (Calculator, always-allowed)"
  cat > "$WORK/brief-gui.md" <<'EOF'
# Task
Using computer use (cua.getApp for Calculator), compute 1234 × 56 by clicks or keystrokes, read the display, then quit Calculator. Do not use shell commands for the math.
# Report back
Only the number shown on the display, digits only, no separators. If blocked, the exact error.
EOF
  CODEX_BATCH="e2e" "$SCRIPTS/codex-run.sh" low workspace-write "$WORK" "$WORK/brief-gui.md" > "$WORK/gui.out" 2>&1
  check "Calculator shows 69104" grep -q '69,\?104' "$WORK/brief-gui.md.result"
fi

if command -v claude >/dev/null; then
  echo "== 5. Plugin self-test"
  check "claude plugin test plugins/codex-workers" claude plugin test "$REPO/plugins/codex-workers"
fi

echo "== $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
