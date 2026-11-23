# Codex worker visualizer — design

Goal: see Codex (GPT-6.2-Sol) workers live inside Claude Code, as a workflow of workers, like subagents/shells.

Two parts joined by a file contract:
1. **Wrapper** `~/.claude/skills/codex/scripts/codex-run.sh` writes a run record per worker and streams Codex JSON events to a file.
2. **Mod** `codex-workers` (Claude Code plugin) polls those files and draws a pane + a band above the prompt.

Claude launches workers with the Bash tool `run_in_background: true`, so each also appears natively as a background shell task.

## Contract A: run records

Directory: `$CODEX_RUNS_DIR`, default `~/.claude/codex-runs/` (absolute: `/Users/xseven/.claude/codex-runs/`).
One file per run: `<id>.json`, where `id` = `YYYYMMDD-HHMMSS-<pid>`. It is written atomically (write `<id>.json.tmp`, then `mv`).

```json
{
  "id": "20261121-193012-4242",
  "name": "impl",                      // brief basename minus .md
  "batch": "rate-limiter smoke",       // $CODEX_BATCH, else "adhoc"
  "brief": "/abs/path/.codex-briefs/impl.md",
  "workdir": "/abs/path/repo",
  "effort": "low",                     // low | medium
  "sandbox": "workspace-write",        // read-only | workspace-write
  "pid": 4242,                         // pid of the codex process (or the wrapper while codex starts)
  "status": "running",                 // running | done | failed | killed
  "exit_code": null,                   // int once finished
  "started_at": 1795300212,            // epoch seconds
  "ended_at": null,                    // epoch seconds once finished
  "events": "/abs/path/.codex-briefs/impl.md.events.jsonl",
  "result": "/abs/path/.codex-briefs/impl.md.result",
  "log": "/abs/path/.codex-briefs/impl.md.log"
}
```
- `done` = exit 0, `failed` = nonzero exit, `killed` = wrapper got INT/TERM/HUP.
- The wrapper keeps the newest 50 records and deletes older `*.json`.

## Contract B: Codex event stream (`codex exec --json`, JSONL, one object per line)

Observed types:
- `{"type":"thread.started","thread_id":"…"}`
- `{"type":"turn.started"}`
- `{"type":"turn.completed","usage":{"input_tokens":…,"output_tokens":…}}`
- `{"type":"item.started"|"item.completed","item":{"id":"item_1","type":"command_execution","command":"/bin/zsh -lc ls","aggregated_output":"…","exit_code":null|0,"status":"in_progress"|"completed"}}`
- `{"type":"item.completed","item":{"type":"agent_message","text":"…"}}`

Other item types may appear (`reasoning`, `file_change` with `changes:[{path,kind}]`, `mcp_tool_call`, `web_search`, `todo_list`, `error`). Handle unknown types generically.

## Contract C: usage

`~/.claude/skills/codex/scripts/codex-usage.sh` prints:
```
Codex usage (snapshot N min old)
  5-hour window: 9% used, resets Sat Nov 21 23:10
  Weekly window: 16% used (60% of week elapsed), resets Tue Nov 24 14:49
STATUS=OK            (or THROTTLE REASON=… / BLOCKED UNTIL=<epoch> REASON=… / UNKNOWN)
```

## Mod UX

- **Pane** "Codex workers" (id `codex-workers`), a workflow view:
  ```
  ▸ rate-limiter smoke                    2 workers · 1 running
    ⠋ impl    low · ws   01:23   $ ruby -Ilib -e '…'
    ✓ tests   low · ws   00:58   Added 21 black-box tests…
  ▸ adhoc                                  1 worker · done
    ✗ gui     low · ws   00:12   exit 1
  ─────────────────────────────────────────────
  5h  ██░░░░░░░░  9%  resets 23:10   wk ██░░░░░░░░ 16%  resets Tue 14:49   OK
  ```
  - Groups: by `batch`, newest batch first. Workers in start order.
  - Shows runs that are running, or that ended within the last 30 min. If none, show the latest batch.
  - Glyphs: spinner for running, ✓ for done, ✗ for failed, ⊘ for killed, ? for lost (status running but pid dead).
  - Elapsed: mm:ss, or h:mm:ss. Live for running, frozen at `ended_at`.
  - Activity, from the tail of the events file, using the latest meaningful event:
    - `command_execution`: `$ <command>`, with the `/bin/zsh -lc ` prefix and surrounding quotes stripped.
    - `agent_message`: the first line of the text.
    - `file_change`: `edit <paths>`.
    - `reasoning`: `thinking…`.
    - otherwise: the item type.
    - Truncate to the width. When finished, show the first line of the `result` file if it exists, else `exit N`.
  - Usage footer from Contract C, with the THROTTLE/BLOCKED status colored.
- **Band above prompt**, shown while any run is running or ended within 60 s: `Codex ⠋ 2 running · 1 done │ 5h 9% · wk 16% │ /codex-workers`.
- **Command** `/codex-workers`: toggles the pane.
- **Auto-open:** the pane opens automatically when a run starts that the mod hasn't seen before.
- **Polling:**
  - `$.clock.every(1000)`: list the dir and read the records.
  - Tail events only for running runs: read at most the last 64 KiB by byte range, and drop a partial first line.
  - Liveness check every 5 s for running runs: `kill -0 <pid>` via `$.process.run`.
  - Usage via `$.process.run` every 30 s and immediately after any run finishes.
  - Never throw out of the timer, and tolerate missing or partial files.
- **State:** `$.state` atoms declared in `types/index.d.ts` (runs view-model, usage, seen ids, pane open).

## v0.2 changes (2026-11-21)

### Band is always visible
- The band above the prompt renders at all times (not only while workers run), unless `e.props.hasSurvey`.
- Layout, widest form:
  `Claude 5h 23% · wk 41% · ctx 38% │ Codex idle · 5h 17% · wk 17% │ /codex-workers`
  - While workers are current (running, or ended < 60 s ago), `idle` is replaced by the existing worker summary: `⠋ 2 running · 1 done`.
  - Missing figures show `—`. If Claude has no rate-limit windows (API key, not subscription), show only `ctx`.
- Narrowing order, applied until it fits `bodyColumns`:
  1. drop ` · ctx N%`;
  2. drop the `/codex-workers` hint;
  3. compact form `C 23%/41% │ X idle 17%/17%`;
  4. truncate.
- Color each percentage: yellow ≥ 70, red ≥ 90 (Codex `THROTTLE`/`BLOCKED` status also colors the `Codex` label yellow/red). Use separate `<Text>` segments inside a row `<Box>`.

### Claude usage source
- `$.session.usage()` (free) → `{ context: { percent? }, rateLimits: [{ kind: 'five_hour'|'seven_day'|…, percentUsed, resetsAt? (ISO) }], cost?: { … } }`. Read once at `session.start`, and on every `session.measure` event (observe, then `return next(e)`). Also refresh every 30 s on the existing timer as a fallback.
- Store it in a new `$.state` atom `claudeUsage` declared in `types/index.d.ts`: `{ fiveHour: { percent, resetsAt } | null, weekly: … | null, contextPercent: number | null, costUsd: number | null }`. Check the real `SessionCost` type for the cost field name.

### Pane footer
- Two usage rows under the rule:
  `Claude  5h ██░░░░░░░░ 23%  resets 23:10   wk ████░░░░░░ 41%  resets Tue 14:49   ctx 38%`
  `Codex   5h ██░░░░░░░░ 17%  resets 23:10   wk ██░░░░░░░░ 17%  resets Tue 14:49   OK`
- Claude reset times come from ISO timestamps. Format them in local time: `HH:MM` when within 24 h, else `Ddd HH:MM`. Use the same bar and colour rules as the band. If the pane is narrow, stack the windows vertically as it does today.

### Version
- `plugin.json` version `0.2.0`.

## v0.2.3 (banked resets)

Contract C can include a `Banked resets:` line with a count and optional expiry.
The status line can include `RESETS=N` and `ADVICE=` before `REASON=`. The
banked line takes precedence for the count. The band keeps the count as it
narrows, and the pane shows the count, expiry when available, and redemption
advice. Advice highlights the reset indicator in yellow.

## v0.2.4 (footer grid)

The pane footer uses fixed columns: an 8-character label, then window cells of fixed width (bar, percent padded to 4, reset text padded to 16). Missing values render as same-width placeholders, so the Claude and Codex rows align. Banked resets always get their own indented line, and on a narrow pane the advice moves to a further line instead of being clipped. Claude has no banked-reset credits: its usage data exposes only window reset times.
