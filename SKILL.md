---
name: lazycodex
description: "Run Codex with the LazyCodex harness ($ulw-plan, $start-work, $ulw-loop, $teammode) in a tmux, herdr, or Orca IDE pane inside the CURRENT session and window, while Claude orchestrates: dispatch the task, monitor progress, answer Codex's questions, verify the result. In Orca, also supports multi-worker A2A via orca orchestration (task dispatch + worker_done). Use when the user says: lazycodex, codex pane, codex한테 시켜, codex로 돌려, ulw-loop, teammode로, codex 하네스, tmux에서 codex, herdr에서 codex, orca에서 codex, orca 워커, a2a로 돌려. NOT for quick codex consultations or reviews — use the /codex skill for those."
---

# LazyCodex Orchestration

Claude = orchestrator. Codex (+ LazyCodex harness) = executor running in a terminal
pane (tmux, herdr, or Orca IDE) in the same session/window. Claude never writes
product code while a run is active; it dispatches, monitors, unblocks, and
independently verifies.

All pane control goes through the bundled script (never raw tmux/herdr commands
against the codex pane). It auto-detects the backend: `$TMUX` set → tmux;
`$ORCA_TERMINAL_HANDLE` set + `orca` CLI present → orca; `$HERDR_PANE_ID` set +
`herdr` CLI present → herdr. `$PANE backend` prints which one is active;
`LAZYCODEX_BACKEND=tmux|herdr|orca` overrides.

```bash
PANE=~/.claude/skills/lazycodex/scripts/codex-pane.sh
```

For detailed command semantics, backend notes, and recovery, see [REFERENCE.md](REFERENCE.md).

## Preflight (once per run)

Run `$PANE doctor` — it checks the backend (tmux/orca/herdr), the `codex` CLI, and
the LazyCodex plugin (`omo@sisyphuslabs` in `~/.codex/config.toml`) in one shot.
On any FAIL, stop and surface the exact missing prerequisite: if not inside a
supported terminal, tell the user to launch Claude inside tmux, Orca IDE, or herdr
(herdr install: `brew install herdr` or `curl -fsSL https://herdr.dev/install.sh | sh`);
if LazyCodex is missing, offer `npx lazycodex-ai install`.

## Pick the harness command

| Situation | Codex command to dispatch | Done signal |
| --- | --- | --- |
| Needs decisions/design before code | `$ulw-plan "<what to build>"` | plan file appears in `plans/*.md` + pane idle |
| A plan exists, execute it | `$start-work <plan-name>` | text `ORCHESTRATION COMPLETE` |
| Open-ended goal, run until verified (the "goal" mode) | `$ulw-loop "<task>" --completion-promise="LAZYCODEX_DONE_<slug>"` | the completion-promise token |
| Parallelizable work needing coordination | `$teammode` request (see below) | pane idle + leader summary |

- Always pass an explicit `--completion-promise` to `$ulw-loop` so there is a
  deterministic marker to wait for. Use a short (<30 chars, so it never line-wraps in
  the TUI) uppercase token unlikely to appear otherwise. `wait` ignores `›`-prefixed
  lines (echoed prompts), so the token in your own dispatch won't self-match — but it
  must fit on one line in codex's output to be detected.
- For teammode, phrase the dispatch as: `$teammode — create a team to <goal>. Members: <one per
  concrete part/ownership area>. Report a final summary when the team's work is merged.`
  On the orca backend, prefer the Orca A2A multi-worker mode (below) over `$teammode`:
  real parallel codex terminals with a tracked lifecycle beat one codex juggling members.
- Big feature = two-phase: dispatch `$ulw-plan`, review the generated `plans/<slug>.md`
  YOURSELF (read the file), relay concerns or approval, then dispatch `$start-work <slug>`.

## Dispatch

```bash
$PANE start                      # creates the pane (idempotent), prints pane id
$PANE send '$ulw-loop "fix the flaky auth test" --completion-promise="LAZYCODEX_DONE_AUTH"'
```

Or launch with the prompt in one shot (avoids composer paste entirely — preferred
for the first command): `$PANE start '$ulw-loop "..." --completion-promise="..."'`

After every `send`, immediately `$PANE peek 30` to confirm the message was actually
submitted (codex should show it as a user message / start working). If the `$` prefix
opened a skill-picker popup and swallowed the input: `$PANE keys Escape`, then re-send.

Write dispatch prompts in English, self-contained (codex has none of Claude's context):
task, relevant file paths, constraints (e.g. "pnpm only", "must pass pnpm build"),
and what evidence counts as done.

## Monitor loop

Poll with the script — each call blocks up to ~9.5 min, safely under the Bash timeout.
Run waits with `run_in_background: true` so you're re-invoked when they return, and do
other useful work meanwhile (read the plan file, prep verification commands).

```bash
$PANE wait 'ORCHESTRATION COMPLETE|LAZYCODEX_DONE_AUTH' 570   # done marker
$PANE status        # BUSY | IDLE | BLOCKED (herdr only) | NO_PANE
$PANE peek 80       # read recent output to summarize progress for the user
```

On herdr, `status` uses herdr's native agent detection, so it can also return
`BLOCKED` — codex is waiting on an approval or a question. Treat that exactly like
the "codex asked a question" triage case below: `peek`, then answer via `send`.
On orca, `status` uses orca's native `tui-idle` probe (a BUSY/IDLE answer takes
~1.5s); `peek` reads the codex screen via `orca terminal read`, which can garble
the TUI status line — trust `status` over screen-grepping for busy/idle.

Loop protocol:
1. `wait` for the done marker. On exit 3 (timeout), `peek` and triage:
   - Still working (spinner, new output since last peek) → report progress to the user
     in one line, `wait` again.
   - Codex asked a question or is `BLOCKED:` → answer it via `$PANE send '...'`.
     Decisions you can make from repo context, make; genuine user decisions, surface.
   - Pane is IDLE without the marker → codex may have stopped early. `peek 120`, read
     what happened, and either `send` a follow-up instruction or treat as done-claimed.
2. Repeat. No fixed iteration cap — the harness itself caps ulw-loop iterations.

## Orca A2A multi-worker mode

Backend is orca AND the work splits into 2+ independent parts → skip `$teammode`
and use orca's native orchestration: one codex terminal per part, tracked
task/dispatch lifecycle, `worker_done` as the done signal (no completion-promise
tokens needed). Keep it to 3–4 workers; deeper DAGs aren't worth coordinating.

```bash
# 0) state check
orca status --json && orca worktree ps --json && orca terminal list --json

# 1) one worker per part — same worktree (shares uncommitted state):
orca terminal create --worktree active --title "worker-<part>" --command "codex" --json   # → .result.terminal.handle
#    OR isolated checkout (only for truly independent work; no uncommitted deps):
orca worktree create --name <part> --agent codex --json                                    # → .result.startupTerminal.handle
orca terminal wait --terminal <handle> --for tui-idle --timeout-ms 60000 --json

# 2) task + dispatch (--inject sends spec + lifecycle preamble into codex)
orca orchestration task-create --spec "<self-contained brief>" --task-title "<short>" --json  # → task id
orca orchestration dispatch --task <task_id> --to <handle> --inject --json

# 3) supervision loop — one message per call; loop once per outstanding worker
orca orchestration check --wait --types worker_done,escalation,decision_gate --timeout-ms 570000 --json
```

Rules (mirror orca's official orchestration conventions):

- Write each `--spec` self-contained in English, like a `send` dispatch prompt: task,
  file paths, constraints ("pnpm only", "must pass pnpm build"), evidence of done.
  Plain English — do NOT put `$ulw-loop`/harness commands inside a spec; the injected
  preamble already owns the worker lifecycle. Harness commands stay for single-pane mode.
- Run `check --wait` with `run_in_background: true` (keep `--timeout-ms` ≤ 570000,
  under the Bash timeout). A timeout or `{count:0}` is a checkpoint, NOT a failure —
  coding tasks run 15–60 min. Liveness-check with `orca terminal read`/`tui-idle`,
  then wait again. Never kill a worker just because it hasn't reported yet.
- `decision_gate`/`ask` messages: answer with
  `orca orchestration reply --id <msg_id> --body '<answer>' --json`, then keep waiting.
  Decisions you can make from repo context, make; genuine user decisions, surface.
- A valid `worker_done` auto-completes the task — don't follow it with `task-update`.
  Verify each worker's result yourself (section below) before accepting it; on failure,
  re-dispatch with the failure evidence via a fresh `task-create` + `dispatch`, or
  `orca terminal send --terminal <handle> --text '<fix instruction>' --enter --json`.
- Workers created here are yours to close; never `terminal close` handles you didn't
  create. Leave them open after the run unless the user asks to clean up.
- Single-pane orca runs (one codex, `$ulw-loop` + completion promise) still go through
  `$PANE` — this section is only for parallel fan-out.

## Verify (Claude's job, never skipped)

Codex saying done ≠ done. After the done signal, verify from YOUR pane:

- `git -C <repo> status && git diff --stat` — what actually changed.
- Run the project's checks yourself (for this machine's projects typically
  `pnpm tsc --noEmit` / `pnpm build` / tests).
- Spot-read the changed files against the original ask.

If verification fails, send the failure evidence back:
`$PANE send 'Verification failed: <exact error>. Fix it. The completion promise stands.'`
and re-enter the monitor loop.

## Wrap up

- Report to the user: what was asked, what codex changed (files + summary), verification
  evidence, and anything skipped.
- Leave the pane open by default so the user can inspect the codex session; `$PANE stop`
  only when the user asks to clean up.
- Never commit codex's work without explicit user confirmation.

## Safety rails

- One codex pane per tmux window / herdr tab / orca worktree (the script enforces
  this via its state file). Exception: multiple named panes via
  `LAZYCODEX_PANE_NAME=<name> $PANE ...` — each name is its own pane, and Orca A2A
  workers are tracked by orchestration state instead.
- Never `tmux kill-pane` / `herdr pane close` / `orca terminal close` on anything
  except ids the script or this run created; never send keys or text to other panes.
- If the pane dies mid-run (`status` → NO_PANE), tell the user; `codex resume --last`
  via `$PANE start` args can recover the session if they want to continue.
- If codex requests approval for a risky action (destructive command, network, install),
  relay it to the user instead of auto-approving.
