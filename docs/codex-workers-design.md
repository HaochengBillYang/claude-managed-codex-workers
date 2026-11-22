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
