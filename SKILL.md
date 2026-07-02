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

## Preflight (once per run)

1. `[ -n "$TMUX" ]` — must be inside tmux. If not, stop and tell the user to launch
   Claude inside tmux.
2. `command -v codex` — codex CLI must exist.
3. `grep -q 'omo@sisyphuslabs' ~/.codex/config.toml` — LazyCodex must be installed.
   If missing, offer: `npx lazycodex-ai install`.

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
$PANE status        # quick BUSY/IDLE check
$PANE peek 80       # read recent output to summarize progress for the user
```

Loop protocol:
1. `wait` for the done marker. On exit 3 (timeout), `peek` and triage:
   - Still working (spinner, new output since last peek) → report progress to the user
     in one line, `wait` again.
   - Codex asked a question or is `BLOCKED:` → answer it via `$PANE send '...'`.
     Decisions you can make from repo context, make; genuine user decisions, surface.
   - Pane is IDLE without the marker → codex may have stopped early. `peek 120`, read
     what happened, and either `send` a follow-up instruction or treat as done-claimed.
2. Repeat. No fixed iteration cap — the harness itself caps ulw-loop iterations.

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

- One codex pane per tmux window (the script enforces this via its state file).
- Never `tmux kill-pane` on anything except the id the script owns; never send keys to
  other panes.
- If the pane dies mid-run (`status` → NO_PANE), tell the user; `codex resume --last`
  via `$PANE start` args can recover the session if they want to continue.
- If codex requests approval for a risky action (destructive command, network, install),
  relay it to the user instead of auto-approving.
