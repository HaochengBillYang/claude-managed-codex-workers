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
- `STATUS=BLOCKED UNTIL=<epoch>` → don't call Codex. Do the work yourself if it's small; otherwise queue it, tell the user when it resets (`date -r <epoch>`), and if the session is still running at that time, resume then (CronCreate/ScheduleWakeup if available).
- `STATUS=UNKNOWN` → proceed; the run itself produces a snapshot.

The snapshot only refreshes when Codex runs; the script already treats a window as reset once its reset time has passed.

### Banked resets
OpenAI occasionally grants **banked resets**. On Plus, one redemption restores both the 5h and weekly windows. Each has an expiry date, and it can only be redeemed once a window is more than 20% used. The Codex CLI does not expose the count, so it is tracked in `~/.claude/codex-resets.json`: `{"available": N, "expires": "YYYY-MM-DD", "updated": "YYYY-MM-DD"}`. A missing file means none.
- `codex-usage.sh` reads the file and appends `RESETS=N` and sometimes `ADVICE=…` to the STATUS line:
  - `REDEEM_RECOMMENDED`: weekly-blocked, or 5h-blocked with weekly ≥ 50%. Ask the user to redeem one (Codex app → Settings → Usage → Redeem reset, or `/usage` in interactive codex), unless the queued work can wait for the reset time.
  - `REDEEM_OPTIONAL`: 5h-blocked with low weekly use. Prefer waiting for the 5h reset; offer the redemption only if the work is urgent.
  - `REDEEM_BEFORE_EXPIRY`: resets expire within 3 days and a window is more than 20% used. Remind the user once, so the reset is not wasted.
- While resets remain, being ahead of the weekly pace does not THROTTLE, because the effective weekly budget is larger.
- **Never redeem yourself.** It spends a scarce account resource. Only the user redeems.
- After the user says they redeemed, decrement `available` in the file, then run Codex once to refresh the snapshot. When new resets are announced, ask the user for the count and expiry, then update the file.

## 2. Pick effort

- `low`: single-file or mechanical changes, writing tests for existing code, running test suites, renames, boilerplate, simple GUI steps.
- `medium`: multi-file features, debugging with unclear cause, nontrivial GUI flows, anything that failed once at `low`.
- Never higher; if medium fails twice, the task is under-specified — re-scope it yourself.

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

## 5. Run

```
~/.claude/skills/codex/scripts/codex-run.sh <low|medium> <sandbox> <workdir> <brief-file>
```
Always launch with the Bash tool's `run_in_background: true` (one Bash call per worker, description "Codex worker: <name>") so each shows as a native background shell, and prefix `CODEX_BATCH="<workflow name>"` to group parallel workers. The `codex-workers` mod (`/codex-workers` toggles its pane) draws them live from `~/.claude/codex-runs/*.json` and `<brief>.md.events.jsonl`. Output: `<brief>.result` (Codex's final report), `<brief>.log` (full log). The wrapper prints usage afterward.

## 6. Review (never skip)

- Read `git diff` (or the changed files) yourself; run the acceptance commands yourself — don't trust the report.
- Check against scope: no unrequested changes, no design drift.
- Small fixes: do them yourself. Real misses: send a follow-up brief (`codex exec resume --last` is available, but a fresh focused brief is usually better).
- Tell the user what was delegated, at what effort, and what you changed on review.
