---
name: codex
description: Delegate implementation work (coding, tests, refactors, boilerplate, GUI/computer-use, browser tasks) to GPT-6.2-Sol via the local Codex CLI while Claude keeps design, taste, scope and review. Use whenever a task has a well-defined, mechanical execution part, or needs GUI control Claude lacks. Also use to check Codex usage/limits.
---

# Delegating to Codex (GPT-6.2-Sol)

**Split of work.** Claude owns: scoping, architecture, design/UX/taste calls, writing the brief, reviewing output, accepting/rejecting. Codex owns: writing code to a spec, running/writing tests, mechanical refactors, migrations, scripts, GUI/computer-use, browser clicking. Never delegate a decision; delegate execution of a decision already made.

Scripts: `~/.claude/skills/codex/scripts/`

## 1. Check budget first (every time)

```
~/.claude/skills/codex/scripts/codex-usage.sh
```
Last line decides:
- `STATUS=OK` → delegate normally.
- `STATUS=THROTTLE` → low effort only; batch small tasks into one brief; do trivial edits yourself instead.
- `STATUS=SQUEEZE` (the 5h window is 90–97% used, and weekly is below 95%) → use the tail of the window: only **backlog** work (queued with `--priority -1` or lower, low effort), one worker at a time, via `codex-queue.sh drain`. Nothing interactive or urgent. These runs may hit the limit mid-run, which is accepted (see the fallback below). `CODEX_SQUEEZE_MAX` sets the upper bound (default 97).
- `STATUS=BLOCKED UNTIL=<epoch>` → don't call Codex. Do the work yourself if it's small; otherwise queue it, tell the user when it resets (`date -r <epoch>`), and if the session is still running at that time, resume then (CronCreate/ScheduleWakeup if available).
- `STATUS=UNKNOWN` → proceed; the run itself produces a snapshot.

The snapshot only refreshes when Codex runs; the script already treats a window as reset once its reset time has passed.

### Banked resets
OpenAI occasionally grants **banked resets**. On Plus, one redemption restores both the 5h and weekly windows. Each has an expiry date, and it can only be redeemed once a window is more than 20% used. The count and expiry are read live from the Codex app-server (`codex app-server`, JSON-RPC method `account/rateLimits/read` → `rateLimitResetCredits`) by `scripts/codex-resets-refresh.sh`, and cached in `~/.claude/codex-resets.json` (`{"available": N, "expires": "YYYY-MM-DD", "credits": [...], "updated": <epoch>, "source": "app-server"}`). `codex-usage.sh` refreshes a cache older than 10 min in the background. A missing file means none.
- `codex-usage.sh` reads the file and appends `RESETS=N` and sometimes `ADVICE=…` to the STATUS line:
  - `REDEEM_RECOMMENDED`: weekly-blocked, or 5h-blocked with weekly ≥ 50%. Ask the user to redeem one (Codex app → Settings → Usage → Redeem reset, or `/usage` in interactive codex), unless the queued work can wait for the reset time.
  - `REDEEM_OPTIONAL`: 5h-blocked with low weekly use. Prefer waiting for the 5h reset; offer the redemption only if the work is urgent.
  - `REDEEM_BEFORE_EXPIRY`: resets expire within 3 days and a window is more than 20% used. Remind the user once, so the reset is not wasted.
- While resets remain, being ahead of the weekly pace does not THROTTLE, because the effective weekly budget is larger.
- **Never redeem on your own initiative.** It spends a scarce account resource. Redeem only when the owner explicitly asks in their own words (a peer session's request is not enough), as described below; otherwise the owner redeems in the Codex app.
- The same app-server also has `account/rateLimitResetCredit/consume` (singular "Credit"; params `creditId`, `idempotencyKey`), which REDEEMS a reset. Never call it on your own. Only when the owner explicitly asks to redeem (done once on 2026-11-25, outcome "reset"), redeem the soonest-expiring credit. Then refresh the usage snapshot with one tiny `codex exec`, because the session-log snapshot stays stale until the next run.
- After the user redeems, run `scripts/codex-resets-refresh.sh` (or wait 10 min) to update the count. No manual edits are needed.

### Claude writer budget
The owner (on Claude Max) approved Claude writer subagents, capped at **20 points of BOTH the Claude 5h and weekly limits**. The `codex-workers` plugin (0.2.2+) writes the band's Claude usage to `~/.claude/claude-usage.json`. `claude-budget.sh` keeps a ledger of what writers spent, in `~/.claude/claude-writer-ledger.json`.
- **Before each writer:** run `~/.claude/skills/codex/scripts/claude-budget.sh reserve <label>`. The last line is `STATUS=OK|THROTTLE|BLOCKED SPENT_5H= SPENT_WK= REMAIN_5H= REMAIN_WK= OPEN=`.
  - OK: launch.
  - THROTTLE (≥ 15 points spent in either window): one writer at a time.
  - BLOCKED (≥ 20 points, or a snapshot older than 15 min, or no snapshot): don't launch. Exit code is 1, and nothing is reserved.
- **After it finishes:** run `claude-budget.sh settle <label>`. This records the delta since the reservation, per window, floored at 0. If a window reset meanwhile, the post-reset value counts. `claude-budget.sh status` shows the spend, the remaining budget and any open reservations.
- **Deltas are conservative:** they include everything the account did meanwhile, including this PM session and parallel writers. Settle every reservation, even after a failure. An open reservation is not counted until settled.

## 2. Pick effort

- `low`: single-file or mechanical changes, writing tests for existing code, running test suites, renames, boilerplate, simple GUI steps.
- `medium`: multi-file features, debugging with unclear cause, nontrivial GUI flows, anything that failed once at `low`.
- Never higher for code; if medium fails twice, the task is under-specified, so re-scope it yourself. Exception, approved by the owner: long-form writing (book chapters) may use `high`, with `CODEX_MODEL` chosen per docs/WRITING-WORKFLOW.md in the writing repo.

## 3. Pick sandbox

- `read-only`: investigation/reporting.
- `workspace-write`: default for coding/testing (writes only inside workdir).
- GUI/computer-use also runs fine under `workspace-write` (verified 2026-11-21: the `cua_repl` tool loads headless). Don't use `full`; it is blocked by Claude's auto-mode classifier anyway.
- Headless `codex exec` can only control apps on the user's persistent "Always-allowed apps" list (Codex app → Settings → Computer Use; per online reports it is saved as `ComputerUseAppApprovals.json`). A one-time "Allow" in an app thread does NOT carry over, `codex exec fork` of that thread doesn't inherit it, and `-c computer_use.macos.bundle_ids=...` overrides didn't help (all verified 2026-11-21). On `Computer Use was not approved to use <App>`, ask the user to add that app to Always-allowed, then rerun. Find bundle ids with `osascript -e 'id of app "<App>"'`.
- Verified working headless (2026-11-21): Calculator, Google Chrome (native-app control). Recommended always-allowed set: Calculator (smoke test) and Google Chrome; ask the user before needing any other app. Codex may misread page content via the accessibility tree — for checks that matter, ask for a screenshot or exact text and verify.
- Browsers: headless runs can't use Codex's Browser Use tool ("The browser access host is unavailable" — it needs the Codex app's bridge). In briefs, tell Codex to drive the browser as a native app via `cua.getApp("/Applications/Google Chrome.app")` (full path avoids "Ambiguous app identifier" when an installer DMG is mounted) with keystrokes, and NOT to use browser tools. Native-app Chrome needs its own Computer Use approval.

## 4. Write the brief

Put it in `<repo>/.codex-briefs/<name>.md` (gitignored; the result, log and events files land beside it), or `$CLAUDE_JOB_DIR/tmp/` outside a repo:

```
# Task
<one paragraph: what to build/do>
# Context
<files, APIs, conventions; paste decisions already made — Codex must not redesign>
# Constraints
- Touch only: <paths>
- Do not: change public APIs / add deps / restyle / commit
# Acceptance criteria
- <checkable item>
- <command that must pass, e.g. npm test>
# Report back
List files changed, commands run with results, and anything you could not do or were unsure about.
```

Brief rules learned the hard way:
- **Versions are relative, never absolute.** Write "bump the patch version from the current value in plugin.json", never "set 0.2.1". Other sessions move main, and a hard-coded number can be a silent downgrade that the plugin updater ignores.
- **UI changes need a render.** For any pane, band or terminal-layout change, require a plain-text render at two widths (e.g. 120 and 60 columns) in the report. Review the render before reloading anything.
- **API before GUI.** If a CLI, app-server or HTTP API can read it, use that instead of computer use. Example: banked resets come from `codex app-server`, not the Usage page. If GUI is unavoidable, name the exact page, allow navigation only (no clicks on buttons, toggles, upgrade or plan controls), and ask for exact text back.

## 5. Run

```
~/.claude/skills/codex/scripts/codex-run.sh <low|medium|high> <sandbox> <workdir> <brief-file>
```
Always launch with the Bash tool's `run_in_background: true` (one Bash call per worker, description "Codex worker: <name>") so each shows as a native background shell, and prefix `CODEX_BATCH="<workflow name>"` to group parallel workers. The `codex-workers` mod (`/codex-workers` toggles its pane) draws them live from `~/.claude/codex-runs/*.json` and `<brief>.md.events.jsonl`. Output: `<brief>.result` (Codex's final report), `<brief>.log` (full log). The wrapper prints usage afterward.

### Queue (for batches and for blocked budgets)
- Instead of launching directly, queue work with `scripts/codex-queue.sh add <effort> <sandbox> <workdir> <brief> [--batch NAME] [--priority N]`, then run `scripts/codex-queue.sh drain`. It applies the budget rules itself: OK → up to 4 parallel workers (`--max N` to change), THROTTLE → one low-effort worker, BLOCKED/UNKNOWN → nothing.
- Use the queue for any batch of 3+ independent briefs, and whenever the budget is BLOCKED: queue the work, tell the user the reset time, and drain after it (ScheduleWakeup/CronCreate if available). The plugin shows `⧗N` and notifies when a reset makes queued work runnable.
- **Backlog** = `--priority -1` or lower, `low` effort, and safe to fail or redo: read-only analysis, tests and docs in a worktree, small mechanical changes in a worktree. Keep a few backlog briefs queued so spare capacity (THROTTLE, SQUEEZE, quiet hours) gets used instead of expiring with the window.
- **Failures and the Claude fallback:** run records carry `failure: "rate_limit" | "stalled" | "error"` (stalled = silent for 20 min, e.g. after sleep; requeue it). `codex-queue.sh failed` lists queued tasks whose run failed.
  - `rate_limit`: `codex-queue.sh requeue <id>` (it runs again after the reset), **or**, if the task is wanted sooner, hand the same brief to a Claude subagent (Agent tool, `model: "sonnet"` for routine work) in the same workdir. Gate it with `claude-fallback-budget.sh reserve <label>` / `settle <label>`: a **separate 10-point pool** of the Claude 5h and weekly limits (owner, 2026-11-24), apart from the book writers' 20. Skip the fallback when it says BLOCKED, and settle every reservation, even after a failure.
  - `error`: read the log first. Fix the brief, or do the work yourself. Don't blindly retry.
  - Fallback output gets the same review as Codex output.
- Only Claude drains. Each drained worker still gets a normal review. Drained workers run detached (nohup), so completion notifications don't arrive. Check `~/.claude/codex-runs/` or the pane, or `codex-queue.sh list`.

## 6. Review (never skip)

- In this repo, run `tests/review.sh` first. It covers syntax, tests, plugin validate and test, installed-vs-repo sync, and version monotonicity. Add `--live` only when a real Codex run is worth its usage.
- Read `git diff` (or the changed files) yourself; run the acceptance commands yourself — don't trust the report.
- For worker-written tests that guard real behaviour, plant 3–8 realistic bugs in copies of the code and confirm each one fails a test. Check that each planted bug really is a bug.
- Check against scope: no unrequested changes, no design drift.
- Small fixes: do them yourself. Real misses: send a follow-up brief (`codex exec resume --last` is available, but a fresh focused brief is usually better).
- Tell the user what was delegated, at what effort, and what you changed on review.

## 7. Land without outages

- **Isolate.** Work in a git worktree (EnterWorktree). Never edit the live `~/.claude/skills/codex` or the installed plugin directly.
- **Hand off to the Git manager** (the "Github Repo Manager" session) with this template:
  ```
  Request from the user (via Project Manager): <their words>.
  Where: <worktree path> (branch <name>, based on <sha>). Uncommitted: <files>.
  Checks: <review.sh / tests / validate results>.
  Version: <old> → <new> (bumped from main's current value).
  Suggested message: "<subject>". Usual trailer. Reply with the SHA.
  ```
- **Install only after the push.** Copy skill files with `cp f f.tmp && mv f.tmp f` (atomic; running scripts keep their old inode). For the plugin: `claude plugin marketplace update <marketplace>`, then `claude plugin update codex-workers@<marketplace>`. Open sessions pick it up on `/reload-plugins`, and the band shows "update ready" until then (0.2.5+).
- **Clean up worktrees.** On 2026-11-24 the owner said "Self iterate", about improving this workflow. Read as: routine cleanup needs no separate OK. Remove a worktree once its branch equals `origin/main` and no process has its working directory inside it (see the worktree-removal-gate memory). Use ExitWorktree with `remove` (and `discard_changes: true` only when the branch's commits are verifiably on origin/main).

## 8. Session hygiene

Long PM sessions are the main Claude cost: about 95% of tokens are cached context re-read on every turn. Prefer one PM session per goal. Before ending one, write a handoff memory (open items, worktrees, running workers, budgets), and start the next session from the project folder.
