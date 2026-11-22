#!/bin/bash
# Installs the Claude ⇄ Codex delegation setup on this machine (macOS, or Windows under Git Bash).
# Safe to re-run: it updates files in place and backs up what it replaces.
#   ./install.sh               install skill + permissions + codex-workers plugin (from GitHub)
#   ./install.sh --local       install the plugin from this checkout instead of GitHub
#   ./install.sh --no-plugin   skip the plugin install
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
SKILL_DST=$CLAUDE_DIR/skills/codex
SETTINGS=$CLAUDE_DIR/settings.json
STAMP=$(date +%Y%m%d-%H%M%S)
WITH_PLUGIN=yes
PLUGIN_SOURCE=HaochengBillYang/claude-project-test
for arg in "$@"; do
  case $arg in
    --no-plugin) WITH_PLUGIN=no ;;
    --local) PLUGIN_SOURCE=$REPO_DIR
             command -v cygpath >/dev/null 2>&1 && PLUGIN_SOURCE=$(cygpath -m "$REPO_DIR") ;;
    *) printf 'unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!!\033[0m  %s\n' "$*"; }

# 1. Prerequisites -----------------------------------------------------------
JQ=$(command -v jq || true)
if [ -z "$JQ" ] && [ -n "${LOCALAPPDATA:-}" ]; then   # winget's Links alias is invisible to Git Bash
  JQ=$(ls "$LOCALAPPDATA"/Microsoft/WinGet/Packages/jqlang.jq_*/jq.exe 2>/dev/null | head -1 || true)
fi
[ -n "$JQ" ] || { warn "jq is required (macOS ships /usr/bin/jq; else: brew install jq, or on Windows: winget install jqlang.jq)"; exit 1; }
APP_CODEX=/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex
WIN_CODEX=
if [ -n "${LOCALAPPDATA:-}" ]; then   # Windows Codex app: CLI under a per-version hash directory
  WIN_CODEX=$(ls -t "$LOCALAPPDATA"/OpenAI/Codex/bin/*/codex.exe 2>/dev/null | head -1 || true)
fi
if [ -x "$APP_CODEX" ]; then
  say "Codex CLI: $APP_CODEX ($("$APP_CODEX" --version 2>/dev/null || echo '?'))"
elif [ -n "$WIN_CODEX" ]; then
  say "Codex CLI: $WIN_CODEX ($("$WIN_CODEX" --version 2>/dev/null || echo '?'))"
elif command -v codex >/dev/null; then
  say "Codex CLI: $(command -v codex) ($(codex --version 2>/dev/null || echo '?'))"
else
  warn "Codex CLI not found. Install the Codex/ChatGPT desktop app (bundles Codex) or the codex CLI, sign in, then re-run."
fi

# 2. Skill -------------------------------------------------------------------
if [ -d "$SKILL_DST" ] && ! diff -rq "$REPO_DIR/skills/codex" "$SKILL_DST" >/dev/null 2>&1; then
  mv "$SKILL_DST" "$SKILL_DST.bak-$STAMP"
  say "Backed up existing skill to $SKILL_DST.bak-$STAMP"
fi
mkdir -p "$CLAUDE_DIR/skills"
rm -rf "$SKILL_DST"
cp -R "$REPO_DIR/skills/codex" "$SKILL_DST"
chmod +x "$SKILL_DST"/scripts/*.sh
mkdir -p "$HOME/.claude/codex-runs"
say "Installed skill to $SKILL_DST"

# 3. Permission rules so Codex runs don't prompt every time -----------------
RULES='["Bash(~/.claude/skills/codex/scripts/codex-usage.sh)","Bash(~/.claude/skills/codex/scripts/codex-run.sh:*)"]'
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak-$STAMP"
tmp=$(mktemp)
# tr: jq.exe on Windows writes CRLF.
"$JQ" --argjson rules "$RULES" '.permissions.allow = (((.permissions.allow // []) + $rules) | unique)' "$SETTINGS" | tr -d '\r' > "$tmp"
mv "$tmp" "$SETTINGS"
say "Added permission rules to $SETTINGS (backup: $SETTINGS.bak-$STAMP)"

# 4. codex-workers plugin (live worker view) ---------------------------------
if [ "$WITH_PLUGIN" = yes ]; then
  if command -v claude >/dev/null; then
    say "Installing codex-workers plugin from $PLUGIN_SOURCE (user scope, every session)"
    claude plugin install codex-workers --marketplace "$PLUGIN_SOURCE" --scope user \
      || warn "Plugin install failed; run it by hand (see README)."
  else
    warn "claude CLI not on PATH; install the plugin by hand (see README)."
  fi
fi

# 5. Manual steps ------------------------------------------------------------
cat <<'EOF'

Done. Remaining manual steps (see setup.md for details):
  1. Sign in to Codex once (open the Codex/ChatGPT app, or run `codex login`).
  2. For GUI work (verified on macOS only): Codex app → Settings → Computer Use → add apps to
     "Always-allowed" (recommended: Calculator, Google Chrome). On macOS, approve Accessibility +
     Screen Recording for "Codex Computer Use" when asked.
  3. Check the model exists for your account:
       ~/.claude/skills/codex/scripts/codex-usage.sh
     and edit `-m gpt-6.2-sol` in ~/.claude/skills/codex/scripts/codex-run.sh if needed.
  4. Start a new Claude Code session; type /codex-workers to open the worker pane.
EOF
