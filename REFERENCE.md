# LazyCodex Pane Reference

This reference keeps operational details out of `SKILL.md` while preserving the
exact rules needed to run Codex safely from a Claude-managed terminal pane.

## Backends

`scripts/codex-pane.sh` supports three backends behind one command surface:

| Backend | Detected when | Pane scope (one pane per…) |
| --- | --- | --- |
| `tmux` | `$TMUX` set | tmux window |
| `orca` | `$ORCA_TERMINAL_HANDLE` set + `orca` CLI on PATH (requires `jq`) | Orca worktree |
| `herdr` | `$HERDR_PANE_ID` set + `herdr` CLI on PATH | herdr tab |

Detection order is tmux → orca → herdr; `LAZYCODEX_BACKEND=tmux|orca|herdr`
overrides. `codex-pane.sh backend` prints the active one.

`LAZYCODEX_PANE_NAME=<name>` manages a separate named pane per name (each name
gets its own state file), which is how multiple workers coexist on any backend.

## Command Surface

The script is the only supported control surface for the Codex pane. Pane ids
are persisted under `${TMPDIR:-/tmp}/lazycodex-pane` so every subcommand is
idempotent.

```bash
codex-pane.sh doctor
codex-pane.sh start [prompt]
codex-pane.sh send "<text>"
codex-pane.sh peek [lines]
codex-pane.sh status
codex-pane.sh wait "<regex>" [timeout]
codex-pane.sh wait-idle [timeout]
codex-pane.sh keys <keys...>
codex-pane.sh focus
codex-pane.sh stop
codex-pane.sh backend
```

## Setup Checks

Run `doctor` before starting work. It checks:

- A supported backend is active (tmux session / Orca terminal / herdr pane).
- `jq` is present when the backend is orca.
- `codex` is installed.
- `omo@sisyphuslabs` is present in `${CODEX_HOME:-$HOME/.codex}/config.toml`.
- Whether a managed Codex pane already exists in the current scope.

If LazyCodex is missing, install it with:

```bash
npx lazycodex-ai install
```

## Dispatch Notes

Use `start [prompt]` for the first command when possible. On tmux/herdr the
script launches plain `codex`, waits for a TUI ready marker, and pastes the
prompt; on orca it launches `codex '<prompt>'` as the terminal command and waits
for orca's native `tui-idle` signal. Both avoid shell quoting problems with long
`$ulw-loop` prompts.

After every `send`, run:

```bash
codex-pane.sh peek 30
```

Confirm Codex shows the prompt as a submitted user message. If the `$` prefix
opens a picker or the prompt is swallowed, run:

```bash
codex-pane.sh keys Escape
```

Then send again.

## Completion Markers

For `$ulw-loop`, always include a deterministic marker:

```bash
$ulw-loop "fix the flaky auth test" --completion-promise="LCX_DONE_AUTH"
```

Keep the marker short, uppercase, and under 30 characters. `wait` ignores lines
that begin with `›` (echoed user prompts) and lines that begin with `codex `
(the shell line that launched codex, visible on orca), which prevents the
dispatched prompt from self-matching.

## Monitor And Recovery

Use this loop until verified:

```bash
codex-pane.sh wait 'ORCHESTRATION COMPLETE|LCX_DONE_AUTH' 570
codex-pane.sh status
codex-pane.sh peek 80
```

Backend-specific status notes:

- herdr: `status` can also return `BLOCKED` (native agent detection) — Codex is
  waiting on an approval or question; answer through `send`.
- orca: `status` uses orca's native `tui-idle` probe (~1.5s per call). `peek`
  reads the TUI screen through `orca terminal read`, which can garble the status
  line — trust `status` over screen-grepping for busy/idle.

If `wait` times out:

- If the pane still shows active work, wait again.
- If Codex asks a question or prints `BLOCKED:`, answer through `send`.
- If `status` is `IDLE` without a marker, inspect `peek 120` and either send a
  follow-up or treat the run as done-claimed and verify independently.
- If `status` is `NO_PANE`, tell the user. Recovery may require starting a new
  pane with `codex resume --last`.

## Orca A2A Multi-Worker Mode

On the orca backend, parallel fan-out should use Orca's native orchestration
layer instead of `$teammode` — real parallel codex terminals with a tracked
task/dispatch lifecycle, each running the LazyCodex harness inside its dispatch.
See the "Orca A2A multi-worker mode" section of `SKILL.md` for the full flow:

```bash
orca terminal create --worktree active --title "worker-<part>" \
  --command "codex -c 'mcp_servers={}'" --json
orca terminal wait --terminal <handle> --for tui-idle --timeout-ms 60000 --json
orca terminal show --terminal <handle> --json | jq -r '.result.terminal.preview'  # composer? login?
orca orchestration task-create --spec "<harness-in-spec brief>" --json
orca orchestration dispatch --task <task_id> --to <handle> --inject --json
orca orchestration check --wait --types worker_done,escalation,decision_gate --timeout-ms 570000 --json
```

Key rules:

- **Put the harness inside the spec.** `$ulw-loop "<task>" --completion-promise=<TOKEN>`
  as step 1, `worker_done` as step 2. The harness loop and the dispatch lifecycle run
  sequentially, not nested — verified end-to-end.
- Launch workers with MCP off. Codex's app-server inherits launchd's 256-fd limit and
  each stdio MCP holds pipes against it; MCP-laden parallel workers wedge it with
  `Too many open files (os error 24)`, which takes down codex entirely. Recover by
  killing the app-server process (it respawns on the next codex launch).
- `tui-idle` returns `ok=true` on codex's **login screen** too. Always confirm the
  composer via `terminal show`'s preview before dispatching, and confirm the worker
  echoed the spec before entering the wait loop.
- A `check --wait` timeout is a checkpoint, not a failure. But a silent worker is not
  necessarily a slow worker — `worker_done` is itself a spawned shell command, so a
  worker whose tool execution is broken can never report. Read the terminal.
- Known gap: a `worker_done` sent from inside codex has been observed to go missing
  (CLI returns a message id; the coordinator's inbox stays empty). The same send from a
  plain shell arrives fine, so delivery works — root cause unconfirmed. Never equate a
  missing completion message with a missing result; check the terminal and the report file.
- Answer `decision_gate` messages with `orca orchestration reply`, and verify every
  `worker_done` yourself before accepting it.

## Verification Boundary

Codex completion is not acceptance. Claude must verify from its own pane:

```bash
git -C <repo> status
git -C <repo> diff --stat
```

Run the project checks that match the change, such as typecheck, build, unit
tests, or smoke tests. If verification fails, send the exact failure back to
Codex and keep the original completion promise.

## Design Influence

This skill follows the same operational separation as
`openai/codex-plugin-cc`: setup/status/result style commands stay small,
execution is delegated through a narrow helper surface, and Claude remains
responsible for interpreting state and verifying the final result. The Orca A2A
mode mirrors the official `stablyai/orca` orchestration skill conventions
(task-create → dispatch --inject → check --wait, worker_done authority).
