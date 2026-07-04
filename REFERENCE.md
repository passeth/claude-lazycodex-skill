# LazyCodex Pane Reference

This reference keeps operational details out of `SKILL.md` while preserving the
exact rules needed to run Codex safely from a Claude-managed tmux pane.

## Command Surface

`scripts/codex-pane.sh` is the only supported control surface for the Codex pane.
It owns one pane per tmux window and stores that pane id under
`${TMPDIR:-/tmp}/lazycodex-pane`.

```bash
codex-pane.sh doctor
codex-pane.sh start [prompt]
codex-pane.sh send "<text>"
codex-pane.sh peek [lines]
codex-pane.sh status
codex-pane.sh wait "<regex>" [timeout]
codex-pane.sh wait-idle [timeout]
codex-pane.sh keys <keys...>
codex-pane.sh stop
```

## Setup Checks

Run `doctor` before starting work. It checks:

- `tmux` is installed.
- Claude is running inside a tmux session.
- `codex` is installed.
- `omo@sisyphuslabs` is present in `${CODEX_HOME:-$HOME/.codex}/config.toml`.
- The current tmux window already has a managed Codex pane, if any.

If LazyCodex is missing, install it with:

```bash
npx lazycodex-ai install
```

## Dispatch Notes

Use `start [prompt]` for the first command when possible. The script launches
plain `codex`, waits for a TUI ready marker, and only then pastes the prompt. This
avoids shell quoting problems with long `$ulw-loop` prompts.

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
that begin with `›`, which prevents the echoed user prompt from self-matching.

## Monitor And Recovery

Use this loop until verified:

```bash
codex-pane.sh wait 'ORCHESTRATION COMPLETE|LCX_DONE_AUTH' 570
codex-pane.sh status
codex-pane.sh peek 80
```

If `wait` times out:

- If the pane still shows active work, wait again.
- If Codex asks a question or prints `BLOCKED:`, answer through `send`.
- If `status` is `IDLE` without a marker, inspect `peek 120` and either send a
  follow-up or treat the run as done-claimed and verify independently.
- If `status` is `NO_PANE`, tell the user. Recovery may require starting a new
  pane with `codex resume --last`.

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
responsible for interpreting state and verifying the final result.
