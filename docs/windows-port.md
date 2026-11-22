# Windows port: scope

Branch: `windows`. Goal: the same Claude ⇄ Codex setup (see `setup.md`) works on Windows 10/11, and macOS keeps working unchanged. Merge to `main` by pull request. The project manager (Claude) reviews before merge.

## Approach (decided)
- **Keep the bash scripts and make them portable. Don't rewrite them in PowerShell.** Claude Code on Windows already needs Git for Windows, and its Bash tool runs in Git Bash. One set of scripts then serves both platforms.
- New dependency on Windows: `jq` (`winget install jqlang.jq`).
- Add an `install.ps1` that does the same as `install.sh`. A bash `install.sh` run from Git Bash is also acceptable if it handles Windows paths.

## Work items
1. **`skills/codex/scripts/codex-usage.sh`**: replace BSD-only commands with portable ones (detect via `date --version`):
   - `stat -f %m` → `stat -c %Y` on GNU;
   - `date -r <epoch>` → `date -d @<epoch>`;
   - `date -j -f … +%s` → `date -d … +%s`.
2. **`skills/codex/scripts/codex-run.sh`**:
   - Find the Codex binary on Windows. Order: `CODEX_BIN`, then the Codex/ChatGPT desktop app's bundled CLI (find where it lives), then `codex` / `codex.exe` on PATH.
   - Check that `$!` and `wait` capture the child process and its exit code under Git Bash.
   - Run records must still be valid JSON with absolute paths. Pick one path style and document it; the plugin must be able to read it.
3. **`plugins/codex-workers`** (bump to `0.3.0`). Every host call goes through `$.process.run` / `$.fs`, with no shell:
   - Home dir: `/usr/bin/printenv HOME` doesn't exist on Windows. Detect the platform, fall back to `USERPROFILE`, and normalise the path separator.
   - Usage: Windows can't execute a `.sh` directly. Run `bash <codex-usage.sh>` (Git Bash's `bash.exe`) on Windows.
   - Liveness: `/bin/kill -0 <pid>` is mac-only. The pid in the run record is a Git Bash pid on Windows, so either check it via `bash -c 'kill -0 <pid>'`, or have the wrapper record the Windows PID and use `tasklist /FI "PID eq <pid>"`. Pick one and justify it.
   - Keep the existing mac behaviour. Add tests for the Windows branches (mock the platform and the process results).
4. **Computer use (GUI)**: document how to always-allow apps on Windows. The docs point to `[computer_use.windows] always_allowed_app_ids` in `%USERPROFILE%\.codex\config.toml`, but openai/codex#49484 says the desktop app writes a different shape. Verify which one headless `codex exec` actually honours, and record the result in `setup.md`.
5. **Docs**: add a Windows section to `README.md` (install) and `setup.md` (paths, quirks, verified GUI apps).

## Acceptance (on a real Windows machine)
- `install.ps1` (or `install.sh` in Git Bash) installs the skill, the permission rules and the plugin. Running it twice is safe.
- `codex-usage.sh` prints correct windows and reset times in local time.
- A two-worker batch (`CODEX_BATCH=… codex-run.sh low read-only …`, launched as background shells) shows live in the `codex-workers` pane, with the always-on row showing Claude and Codex usage. A killed worker shows ⊘, and a worker whose process disappears shows `?`.
- GUI smoke test: Codex computes 1234 × 56 in Calculator headlessly (expected 69,104).
- On macOS: `claude plugin test plugins/codex-workers` passes, `claude plugin validate .` passes, and a mac run still works.
- The PR description lists what was verified on Windows, with screenshots of the pane.

## Out of scope
- Linux (welcome later, but it isn't required).
- Changing the delegation policy, the effort/sandbox rules or the usage thresholds. Raise an issue instead.
