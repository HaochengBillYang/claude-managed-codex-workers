#!/bin/bash
# Budget for Claude subagents that pick up Codex tasks which failed on the Codex limit.
# A separate pool from the book-writer budget: at most 10 points (owner, 2026-11-24) of BOTH
# the Claude 5-hour and weekly limits, with its own ledger. Same commands and output as
# claude-budget.sh:
#   claude-fallback-budget.sh reserve <label> | settle <label> | status
export CLAUDE_WRITER_LEDGER=${CLAUDE_FALLBACK_LEDGER:-"$HOME/.claude/claude-fallback-ledger.json"}
export CLAUDE_WRITER_CAP=${CLAUDE_FALLBACK_CAP:-10}
export CLAUDE_WRITER_THROTTLE=${CLAUDE_FALLBACK_THROTTLE:-8}
exec "$(dirname "$0")/claude-budget.sh" "$@"
