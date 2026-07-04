---
name: lazycodex
description: "Run Codex with the LazyCodex harness ($ulw-plan, $start-work, $ulw-loop, $teammode) in a tmux pane inside the CURRENT session and window, while Claude orchestrates: dispatch the task, monitor progress, answer Codex's questions, verify the result. Use when the user says: lazycodex, codex pane, codex한테 시켜, codex로 돌려, ulw-loop, teammode로, codex 하네스, tmux에서 codex. NOT for quick codex consultations or reviews — use the /codex skill for those."
---

# LazyCodex Orchestration

Claude = orchestrator. Codex (+ LazyCodex harness) = executor running in a tmux pane
in the same session/window. Claude never writes product code while a run is active;
it dispatches, monitors, unblocks, and independently verifies.

All pane control goes through the bundled script (never raw tmux against the codex pane):

```bash
PANE=~/.claude/skills/lazycodex/scripts/codex-pane.sh
```

For detailed command semantics and recovery notes, see [REFERENCE.md](REFERENCE.md).

## Preflight (once per run)

Run the setup check first:

```bash
$PANE doctor
```

If it reports a failure, stop and surface the exact missing prerequisite. Do not start
a pane until tmux, `codex`, and `omo@sisyphuslabs` are ready. If LazyCodex is missing,
offer: `npx lazycodex-ai install`.

## Pick the harness command

| Situation | Codex command to dispatch | Done signal |
| --- | --- | --- |
| Needs decisions/design before code | `$ulw-plan "<what to build>"` | plan file appears in `plans/*.md` + pane idle |
| A plan exists, execute it | `$start-work <plan-name>` | text `ORCHESTRATION COMPLETE` |
| Open-ended goal, run until verified (the "goal" mode) | `$ulw-loop "<task>" --completion-promise="LAZYCODEX_DONE_<slug>"` | the completion-promise token |
| Parallelizable work needing coordination | `$teammode` request (see below) | pane idle + leader summary |

- Always pass an explicit `--completion-promise` to `$ulw-loop`. Use a short
  uppercase token under 30 chars so it does not wrap in the TUI.
- For teammode, phrase the dispatch as: `$teammode — create a team to <goal>. Members: <one per
  concrete part/ownership area>. Report a final summary when the team's work is merged.`
- Big feature = two-phase: dispatch `$ulw-plan`, review the generated `plans/<slug>.md`
  YOURSELF (read the file), relay concerns or approval, then dispatch `$start-work <slug>`.

## Dispatch

```bash
$PANE start                      # creates the pane (idempotent), prints pane id
$PANE send '$ulw-loop "fix the flaky auth test" --completion-promise="LAZYCODEX_DONE_AUTH"'
```

Or launch with the prompt in one shot. The script starts plain `codex`, waits for the
TUI, then pastes the prompt after readiness:
`$PANE start '$ulw-loop "..." --completion-promise="..."'`

Write dispatch prompts in English, self-contained (codex has none of Claude's context):
task, relevant file paths, constraints (e.g. "pnpm only", "must pass pnpm build"),
and what evidence counts as done.

## Monitor loop

Use the smallest useful status surface:

```bash
$PANE wait 'ORCHESTRATION COMPLETE|LAZYCODEX_DONE_AUTH' 570   # done marker
$PANE status        # quick BUSY/IDLE check
$PANE peek 80       # read recent output to summarize progress for the user
```

On timeout, inspect with `peek`: wait again, answer through `send`, or treat an idle
pane as done-claimed and verify. Surface only genuine user decisions.

## Verify (Claude's job, never skipped)

Codex saying done ≠ done. After the done signal:

- `git -C <repo> status && git diff --stat` — what actually changed.
- Run the project's checks yourself.
- Spot-read the changed files against the original ask.

If verification fails, send the failure evidence back:
`$PANE send 'Verification failed: <exact error>. Fix it. The completion promise stands.'`
and re-enter the monitor loop.

## Wrap up

Report the task, changed files, verification evidence, and skipped checks. Leave
the pane open by default. Never commit Codex's work without explicit user confirmation.

## Safety rails

- One codex pane per tmux window (the script enforces this via its state file).
- Use `$PANE doctor` instead of hand-rolled setup checks; it reports missing commands,
  tmux state, LazyCodex config, and existing pane state without mutating the pane.
- If the pane dies mid-run (`status` → NO_PANE), tell the user; `codex resume --last`
  via `$PANE start` args can recover the session if they want to continue.
- If codex requests approval for risky actions, relay it instead of auto-approving.
