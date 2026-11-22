# claude-project-test

A setup where **Claude Code is the project manager and Codex (GPT) is the worker**. Claude scopes, designs, reviews and gives the verdict. Codex workers implement, test and do GUI tasks. You can watch them run live in Claude Code.

| Path | What |
|---|---|
| `setup.md` | Full setup notes: roles, usage self-management, sandbox and GUI rules, machine quirks, workflow |
| `skills/codex/` | Claude Code skill: delegation rules, brief template, review checklist, `codex-run.sh` / `codex-usage.sh` |
| `plugins/codex-workers/` | Claude Code plugin (v0.2): an always-on status row above the prompt with Claude and Codex usage, and a live workflow pane of running Codex workers |
| `.claude-plugin/marketplace.json` | Makes this repo a plugin marketplace |
| `install.sh` | One-shot installer for a new machine |
| `tests/e2e.sh` | End-to-end check: install, usage budget, a live Codex worker, run records, optional Calculator GUI (`--gui`), plugin tests |
| `docs/codex-workers-design.md` | Design of the worker visualizer |
| `DESIGN.md`, `lib/`, `test/` | Smoke-test project (token-bucket rate limiter) built by two Codex workers |

## Install on a new machine (macOS)

Requirements: [Claude Code](https://claude.com/claude-code), plus the ChatGPT desktop app (which bundles the Codex CLI) or the standalone `codex` CLI, signed in.

```bash
git clone https://github.com/HaochengBillYang/claude-project-test.git
cd claude-project-test
./install.sh
```

`install.sh` does three things:
- copies the skill to `~/.claude/skills/codex`;
- adds two permission rules to `~/.claude/settings.json`, after backing it up;
- installs the `codex-workers` plugin at user scope, so it loads in every session.

It is safe to re-run. The manual steps it prints are covered in [setup.md](setup.md#new-machine).

To install only the plugin, use one of these:

At the prompt of a terminal Claude Code session:

```
/plugin install codex-workers --marketplace HaochengBillYang/claude-project-test
```

From a shell:

```bash
claude plugin install codex-workers --marketplace HaochengBillYang/claude-project-test
```

In the desktop app, click **+** next to the prompt box, then **Plugins**, then **Add marketplace** with `HaochengBillYang/claude-project-test`, then **Add plugin**.

## Use

Just give Claude tasks. It checks Codex usage, writes a brief per worker, and launches each worker as a background shell. The **Codex workers** pane opens automatically. Type `/codex-workers` to toggle it.

The row above the prompt is always visible:

```
Claude 5h 23% · wk 41% · ctx 38% │ Codex idle · 5h 17% · wk 17% │ /codex-workers
```

It shows Claude's 5-hour and weekly limits and context fill, then Codex's worker status and limits. Numbers turn yellow at 70% and red at 90%.
