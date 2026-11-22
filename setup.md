# Claude ⇄ Codex delegation setup

Last updated: 2026-11-21. Source of truth if a chat is lost or compacted.

## Roles
- **Claude (Opus 5.5, Claude Code)** — project manager: scoping, system design, taste/UX calls, writing briefs, reviewing all output, final verdict. Never delegates a decision.
- **Codex (GPT-6.2-Sol, local Codex CLI)** — worker: implementation to spec, writing/running tests, mechanical refactors, GUI/computer-use. Effort `low` by default, `medium` for multi-file/debugging, never higher.

## Components
| What | Where |
|---|---|
| Codex CLI (bundled in ChatGPT.app, not on PATH) | `/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex` (v0.171.0-alpha.13) |
| Delegation skill (rules, brief template, review checklist) | `~/.claude/skills/codex/SKILL.md` |
| Run wrapper | `~/.claude/skills/codex/scripts/codex-run.sh <low\|medium> <read-only\|workspace-write> <workdir> <brief.md>` → `<brief>.md.result`, `<brief>.md.log` |
| Usage checker | `~/.claude/skills/codex/scripts/codex-usage.sh` (last line: `STATUS=OK\|THROTTLE\|BLOCKED UNTIL=<epoch>\|UNKNOWN`) |
| Permission allow rules for both scripts | `~/.claude/settings.json` (added by user; Claude may not edit its own permissions) |
| Claude memory | `~/.claude/projects/-Users-xseven/memory/` (`codex-delegation.md`, `github-account.md`) |
| GitHub | https://github.com/HaochengBillYang |

## Usage self-management
Codex writes rate limits into every session log (`~/.codex/sessions/**/*.jsonl`, `rate_limits` field): a 5-hour window and a weekly window, each with `used_percent` and `resets_at`. `codex-usage.sh` reads the newest one, treats a window as reset once `resets_at` passes, and decides:
- **BLOCKED**: 5h ≥ 90% or weekly ≥ 95% → no Codex; Claude does small work itself, queues the rest until reset.
- **THROTTLE**: 5h ≥ 70% or weekly use > 15 pts ahead of elapsed-week % → low effort only, batch tasks.
- **OK** otherwise.

## Sandbox
- Use `workspace-write` (writes only inside the workdir) for coding and GUI work, and `read-only` for investigation.
- Never use `--dangerously-bypass-approvals-and-sandbox`. It isn't needed, and Claude's auto-mode safety check blocks it anyway.

## GUI / computer use (verified 2026-11-21)
- Headless `codex exec` can drive only apps on the **Always-allowed** list in the Codex app (Settings → Computer Use). A one-time "Allow" in an app chat does **not** carry over. Forking that thread doesn't help, and neither do `-c computer_use.macos.bundle_ids` overrides.
- Approve a new app: in the Codex app, type `@Computer open <App> …` and choose **Always allow**.
- Currently always-allowed: **Calculator**, **Google Chrome**.
- Browsers: Codex's Browser Use tool fails headless ("browser access host is unavailable"). Briefs must tell Codex to drive Chrome as a native app with `cua.getApp("/Applications/Google Chrome.app")` and keystrokes. Use the full path, because a mounted Chrome installer DMG makes the bundle ID ambiguous.
- Codex reads pages through the accessibility tree and can misreport content. For important checks, get exact text or a screenshot and verify it.

## Machine quirks
- No Xcode Command Line Tools: `python3`/`git`-adjacent dev tools may trigger an install prompt. Available: Ruby 2.6 (with minitest), Perl 5.34, bash/zsh, `jq`. Codex's bundled Node: `~/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node`.

## Seeing workers live (in progress)
- `codex-run.sh` writes a run record per worker to `~/.claude/codex-runs/<id>.json` (status, pid, effort, batch, timings) and streams Codex JSON events to `<brief>.md.events.jsonl`. Set `CODEX_BATCH="<name>"` to group parallel workers into one workflow.
- Launch each worker with the Bash tool's `run_in_background: true` so it shows as a native background shell.
- The `codex-workers` Claude Code mod (being built: `~/.claude/dev-mods/<session>/codex-workers/`, design in `docs/codex-workers-design.md`) draws a workflow pane plus a status row above the prompt from those records. Toggle it with `/codex-workers`.

## Workflow per task
1. Claude: `codex-usage.sh` → check status.
2. Claude: write the spec/design (in the repo), then one brief per worker (`.codex-briefs/<name>.md`) using the template in SKILL.md: task, context, constraints (files it may touch, no commits), acceptance criteria, report-back.
3. Run the workers. Independent workers run in parallel (`codex-run.sh … & codex-run.sh … & wait`).
4. Claude review: run acceptance commands itself, read the diff, **mutation-test the tests** (plant bugs, confirm tests fail), fix small issues directly, and send real misses back with a new brief.
5. Claude reports a verdict to the user. Commit or push only when the user asks.

## Smoke-test record
2026-11-21, repo `claude-project-test`, branch `smoke/rate-limiter`: a token-bucket rate limiter (`DESIGN.md`, `lib/`, `test/`). Two parallel workers built the implementation and black-box tests. 21 tests passed on the first run, 8 of 8 planted bugs were caught, and one spec defect (Float-only `rate`) was fixed by Claude. The run cost about 1% of the 5-hour window.
