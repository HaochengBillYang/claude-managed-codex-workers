# Claude ⇄ Codex delegation setup

Last updated: 2026-11-21. Source of truth if a chat is lost or compacted.

## Roles
- **Claude (Opus 5.5, Claude Code)** — project manager: scoping, system design, taste/UX calls, writing briefs, reviewing all output, final verdict. Never delegates a decision.
- **Codex (GPT-6.2-Sol, local Codex CLI)** — worker: implementation to spec, writing/running tests, mechanical refactors, GUI/computer-use. Effort `low` by default, `medium` for multi-file/debugging, never higher.

## Components
| What | Where |
|---|---|
| Codex CLI | Bundled in ChatGPT.app at `/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex` (not on PATH; v0.171.0-alpha.13 here). The wrapper falls back to `codex` on PATH, or `$CODEX_BIN`. |
| Delegation skill (rules, brief template, review checklist) | `~/.claude/skills/codex/SKILL.md`. Source: `skills/codex/` in this repo; `install.sh` copies it over. |
| Run wrapper | `~/.claude/skills/codex/scripts/codex-run.sh <low\|medium> <read-only\|workspace-write> <workdir> <brief.md>` → `<brief>.md.result`, `<brief>.md.log`, `<brief>.md.events.jsonl`, plus a run record in `~/.claude/codex-runs/` |
| Usage checker | `~/.claude/skills/codex/scripts/codex-usage.sh` (last line: `STATUS=OK\|THROTTLE\|BLOCKED UNTIL=<epoch>\|UNKNOWN`) |
| Claude writer budget | `~/.claude/skills/codex/scripts/claude-budget.sh <reserve\|settle\|status> [label]`, reading `~/.claude/claude-usage.json` (written by the `codex-workers` plugin) and keeping `~/.claude/claude-writer-ledger.json` |
| Permission allow rules for the three scripts (usage, run, Claude budget) | `~/.claude/settings.json`. Added by the user or by `install.sh`; Claude may not edit its own permissions. |
| Worker visualizer plugin | `codex-workers`, installed at user scope from this repo's marketplace. Source: `plugins/codex-workers/`. |
| Claude memory | `~/.claude/projects/-Users-xseven/memory/` (`codex-delegation.md`, `github-account.md`) |
| GitHub | https://github.com/HaochengBillYang |

## Usage self-management
Codex writes rate limits into every session log (`~/.codex/sessions/**/*.jsonl`, `rate_limits` field): a 5-hour window and a weekly window, each with `used_percent` and `resets_at`. `codex-usage.sh` reads the newest one, treats a window as reset once `resets_at` passes, and decides:
- **BLOCKED**: 5h ≥ 90% or weekly ≥ 95% → no Codex; Claude does small work itself, queues the rest until reset.
- **THROTTLE**: 5h ≥ 70% or weekly use > 15 pts ahead of elapsed-week % → low effort only, batch tasks.
- **OK** otherwise.
- **Banked resets**: read live from the Codex app-server (`account/rateLimits/read` → `rateLimitResetCredits`: count, plus each credit's title, status and expiry) by `codex-resets-refresh.sh`, and cached in `~/.claude/codex-resets.json`. A cache older than 10 min is refreshed in the background, so the usage check never waits. The app-server also has a redeem method (`account/rateLimitResetCredits/consume`). Claude never calls it. On Plus, each one restores both windows. While any remain, the weekly-pace rule does not throttle. The script adds `RESETS=N` and `ADVICE=REDEEM_RECOMMENDED|REDEEM_OPTIONAL|REDEEM_BEFORE_EXPIRY`. Only the user redeems (Codex app → Settings → Usage → Redeem reset). Details are in `skills/codex/SKILL.md`.
- **Claude writer budget** (Claude Max, owner-approved 2026-11-23): Claude writer subagents may use at most 20 points of each Claude window (5h and weekly).
  - **Usage file:** from version 0.2.2, the `codex-workers` plugin writes `~/.claude/claude-usage.json` as `{"five_hour_pct","five_hour_resets_at","weekly_pct","weekly_resets_at","updated_at"}` (epoch seconds), from the same data as its band. It writes atomically (temp file, then `mv`), only when both windows are known, and on change or at least every 5 minutes.
  - **Ledger:** `claude-budget.sh reserve <label>` records a baseline, and `settle <label>` records the delta per window. Spend counts in the window whose reset time (±5 min) matches the current one.
  - **Status:** BLOCKED at ≥ 20 points in either window, or when the snapshot is more than 15 minutes old; THROTTLE at ≥ 15 points.
  - **Overrides:** `CLAUDE_WRITER_CAP`, `CLAUDE_WRITER_THROTTLE`, `CLAUDE_USAGE_STALE`, `CLAUDE_USAGE_FILE` and `CLAUDE_WRITER_LEDGER`.
  - The deltas include all other account activity, so the budget is conservative.

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

## Seeing workers live
- `codex-run.sh` writes a run record per worker to `~/.claude/codex-runs/<id>.json` (status, pid, effort, batch, timings) and streams Codex JSON events to `<brief>.md.events.jsonl`. Set `CODEX_BATCH="<name>"` to group parallel workers into one workflow.
- Launch each worker with the Bash tool's `run_in_background: true` so it shows as a native background shell.
- The `codex-workers` plugin (`plugins/codex-workers/`, design in `docs/codex-workers-design.md`) draws a workflow pane from those records. It also draws an always-on status row above the prompt with Claude usage (5h, weekly, context; from `$.session.usage()` and `session.measure`) and Codex usage (from `codex-usage.sh`). Numbers turn yellow at 70% and red at 90%. Versions: 0.1 added the pane and an active-only row; 0.2 made the row always on and added Claude usage; 0.2.1 shows high-effort workers and their model ("high · astra"); 0.2.2 writes `~/.claude/claude-usage.json` for `claude-budget.sh`. Toggle it with `/codex-workers`.

## Workflow per task
1. Claude: `codex-usage.sh` → check status.
2. Claude: write the spec/design (in the repo), then one brief per worker (`.codex-briefs/<name>.md`) using the template in SKILL.md: task, context, constraints (files it may touch, no commits), acceptance criteria, report-back.
3. Run the workers. Independent workers run in parallel (`codex-run.sh … & codex-run.sh … & wait`).
4. Claude review: run `tests/review.sh` first, run acceptance commands itself, read the diff, **mutation-test the tests** (plant bugs, confirm tests fail), fix small issues directly, and send real misses back with a new brief.
5. Claude reports a verdict to the user. Commit or push only when the user asks.

## Smoke-test record
2026-11-21, repo `claude-project-test`, branch `smoke/rate-limiter`: a token-bucket rate limiter (`DESIGN.md`, `lib/`, `test/`). Two parallel workers built the implementation and black-box tests. 21 tests passed on the first run, 8 of 8 planted bugs were caught, and one spec defect (Float-only `rate`) was fixed by Claude. The run cost about 1% of the 5-hour window.

## New machine
1. Install Claude Code and either the ChatGPT desktop app (it bundles Codex) or the standalone `codex` CLI. Sign in to Codex once.
2. `git clone https://github.com/HaochengBillYang/claude-managed-codex-workers.git && cd claude-managed-codex-workers && ./install.sh`. This installs the skill, the permission rules and the plugin (user scope); `--no-plugin` skips the plugin.
3. Check the model: run `~/.claude/skills/codex/scripts/codex-usage.sh` after one Codex run, and look in `~/.codex/models_cache.json` for `gpt-6.2-sol`. If the account lacks it, change `-m` in `codex-run.sh`.
4. GUI: in the Codex app, go to Settings → Computer Use → Always-allowed. Add Calculator and Google Chrome (or type `@Computer open <App>` and choose **Always allow**). Grant macOS Accessibility and Screen Recording to "Codex Computer Use". Smoke test: ask Claude to have Codex compute 1234 × 56 in Calculator (expected 69,104).
   Then verify the whole setup: `tests/e2e.sh --gui` (one real Codex run, plus one GUI run; about 1-2% of the 5h window).
5. Optional: tell Claude about the delegation preference so it is saved to memory. The skill's description already makes Claude pick it up.
6. If Xcode Command Line Tools are missing, avoid `python3` (it triggers an install prompt). The skill only needs bash, jq and the Codex CLI.

## Updating
- Edit the skill or plugin in this repo, then re-run `./install.sh`. For the plugin, run `claude plugin marketplace update claude-managed-codex-workers` (or reinstall) once the change is pushed.
- Git operations (commit, push, repo settings) are handled by the separate **Github Repo Manager** Claude session.
