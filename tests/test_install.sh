#!/bin/bash
set -u
set -o pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd) || exit 1
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/codex-install-test.XXXXXX") || exit 1
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

install() {
  local output
  if ! output=$(BASH_ENV="$TEMP/install-env" /bin/bash "$REPO/install.sh" --no-plugin 2>&1); then
    printf '%s\n' "$output"
    return 1
  fi
  if [[ $output != *'codex test stub'* ]]; then
    printf 'Installer did not report the Codex stub:\n%s\n' "$output"
    return 1
  fi
}

scripts_executable() {
  local source installed
  for source in "$REPO"/skills/codex/scripts/*.sh; do
    installed=$SKILL/scripts/${source##*/}
    if [[ ! -f $installed || ! -x $installed ]]; then
      printf 'Missing or non-executable script: %s\n' "$installed"
      return 1
    fi
  done
}

settings_backup_matches() {
  local backup
  for backup in "$SETTINGS".bak-*; do
    if [[ -f $backup ]] && cmp -s "$1" "$backup"; then
      return 0
    fi
  done
  printf 'No settings backup matches %s\n' "$1"
  return 1
}

export HOME="$TEMP/home" TMPDIR="$TEMP" PATH="$TEMP/bin:$PATH"
unset CLAUDE_CONFIG_DIR BASH_ENV
SKILL=$HOME/.claude/skills/codex
SETTINGS=$HOME/.claude/settings.json
mkdir -p "$HOME" "$TEMP/bin" || exit 1
# Hide the bundled binary from the installer's absolute-path probe so it
# reaches the PATH stub even on Macs with ChatGPT installed.
cat > "$TEMP/install-env" <<'STUB' || exit 1
function [ {
  if [[ $# -eq 3 && $1 == -x &&
        $2 == /Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex &&
        $3 == ']' ]]; then
    return 1
  fi
  builtin [ "$@"
}
STUB
cat > "$TEMP/bin/codex" <<'STUB' || exit 1
#!/bin/bash
[[ $# -eq 1 && $1 == --version ]] || exit 1
echo 'codex test stub'
STUB
cat > "$TEMP/bin/claude" <<'STUB' || exit 1
#!/bin/bash
touch "$HOME/claude-called"
exit 1
STUB
chmod +x "$TEMP/bin/codex" "$TEMP/bin/claude" || exit 1

# Expected rules come from install.sh itself, so adding a rule there doesn't break this test.
rules=$(sed -n "s/^RULES='\(.*\)'$/\1/p" "$REPO/install.sh")
jq -e 'type == "array" and length > 0' <<< "$rules" >/dev/null || { echo "could not read RULES from install.sh"; exit 1; }
printf '{}\n' > "$TEMP/empty-settings.json" || exit 1

echo '== Fresh install'
check 'install.sh --no-plugin succeeds with a fresh HOME' install
[[ $FAIL -eq 0 ]] || exit 1
check 'installed skill is identical to skills/codex' diff -r "$REPO/skills/codex" "$SKILL"
check 'installed shell scripts are executable' scripts_executable
check 'settings.json is created with all installer allow rules' jq -e --argjson rules "$rules" \
  '(.permissions.allow | sort) == ($rules | sort)' "$SETTINGS"
check 'fresh settings backup contains the initial empty object' settings_backup_matches "$TEMP/empty-settings.json"
check '~/.claude/codex-runs exists' test -d "$HOME/.claude/codex-runs"

echo '== Repeat install'
# Keep the first run's rules and add user-owned settings before reinstalling.
jq '.theme = "dark" | .env = {CUSTOM: "keep"} |
    .permissions.deny = ["Bash(rm:*)"] | .permissions.allow += ["Bash(git status:*)"]' \
  "$SETTINGS" > "$TEMP/existing-settings.json" &&
  cp "$TEMP/existing-settings.json" "$SETTINGS" || exit 1
check 'install.sh --no-plugin succeeds with existing settings' install
check 'existing top-level keys and permission settings are preserved' jq -e \
  --slurpfile before "$TEMP/existing-settings.json" \
  'del(.permissions.allow) == ($before[0] | del(.permissions.allow))' "$SETTINGS"
check 'existing allow rules are preserved without duplicates' jq -e --argjson rules "$rules" \
  '(.permissions.allow | sort) == (($rules + ["Bash(git status:*)"]) | sort)' "$SETTINGS"
check 'repeat settings backup matches the pre-install settings' settings_backup_matches "$TEMP/existing-settings.json"
check '--no-plugin skips the Claude CLI on both runs' test ! -e "$HOME/claude-called"

echo "== $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
