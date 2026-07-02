# claude-lazycodex-skill

A [Claude Code](https://claude.com/claude-code) skill that lets **Claude orchestrate
[Codex](https://developers.openai.com/codex) + the [LazyCodex](https://github.com/code-yeongyu/lazycodex) harness**
in a live tmux pane — same session, same window.

Claude stays the orchestrator: it dispatches a task to Codex's LazyCodex commands
(`$ulw-plan`, `$start-work`, `$ulw-loop`, `$teammode`), watches progress, answers
Codex's questions, and independently verifies the result before reporting back. Codex
does the actual code editing under its strong agent harness; Claude never writes product
code while a run is active.

```
┌─ tmux window ─────────────────────────────────────────────┐
│  Claude Code (orchestrator)   │  Codex + LazyCodex (exec)  │
│  • picks the harness command  │  $ulw-loop "..."           │
│  • dispatches via tmux paste  │  → plans, edits, tests     │
│  • monitors / unblocks        │  → runs until verified     │
│  • verifies (git diff, build) │                            │
└───────────────────────────────┴────────────────────────────┘
        pane A  ◄── codex-pane.sh controls ──►  pane B
```

## Why

LazyCodex gives Codex a serious agent harness (project memory, planning, verified
completion, team mode). This skill wires that power under a Claude orchestrator so you
get **two models cooperating**: Claude's judgment and context management on top, Codex's
LazyCodex execution loop underneath — coordinated through a plain tmux pane, no extra
daemon.

## Requirements

- **Claude Code** running **inside a tmux session** (the skill drives a sibling pane).
- **[Codex CLI](https://developers.openai.com/codex)** installed and authenticated (`codex` on PATH).
- **[LazyCodex](https://github.com/code-yeongyu/lazycodex)** installed into Codex:
  ```bash
  npx lazycodex-ai install
  ```
- `tmux` (3.x+).

## Install

Clone into your Claude Code skills directory:

```bash
git clone https://github.com/passeth/claude-lazycodex-skill.git \
  ~/.claude/skills/lazycodex
chmod +x ~/.claude/skills/lazycodex/scripts/codex-pane.sh
```

The skill auto-registers on your next Claude Code session (verify with `/skills` or by
asking Claude to "list skills").

## Usage

Start Claude Code **inside tmux**, then just ask in natural language:

- `codex한테 시켜서 ulw-loop로 이 버그 고쳐줘`
- `run this refactor with codex teammode`
- `lazycodex로 이 기능 계획부터 세워줘`

Claude will:
1. **Preflight** — verify tmux + codex + LazyCodex are present.
2. **Pick the harness command** based on the task shape:

   | Task | Codex command | Done signal |
   | --- | --- | --- |
   | Design before code | `$ulw-plan "..."` | plan file in `plans/*.md` |
   | Execute an existing plan | `$start-work <plan>` | `ORCHESTRATION COMPLETE` |
   | Open-ended goal, run until verified | `$ulw-loop "..." --completion-promise=TOKEN` | the token prints |
   | Parallel, coordinated work | `$teammode` | leader summary |

3. **Dispatch** into the Codex pane, **monitor** the run, **answer** Codex's questions.
4. **Verify independently** (git diff, `pnpm build` / tests) — Codex saying "done" is
   never accepted at face value.
5. **Report** what changed, verification evidence, and anything skipped.

The Codex pane is left open so you can inspect the session afterward.

## The pane controller

All tmux interaction goes through `scripts/codex-pane.sh` (never raw tmux against the
Codex pane). One Codex pane per tmux window, tracked via a state file so every call is
idempotent.

```
codex-pane.sh start [prompt]     create pane + launch codex (idempotent); prints pane id
codex-pane.sh send "<text>"      paste text into the codex composer and submit
codex-pane.sh peek [lines]       show last N lines of the pane (default 60)
codex-pane.sh status             BUSY | IDLE | NO_PANE
codex-pane.sh wait "<regex>" [t] block until regex appears in codex OUTPUT (ignores echoed prompts)
codex-pane.sh wait-idle [t]      block until codex stops working
codex-pane.sh keys <keys...>     raw tmux send-keys (Escape, Enter, C-c, ...)
codex-pane.sh stop               interrupt codex and kill the pane
```

`wait` filters out `›`-prefixed lines (Codex's echo of your dispatched prompt), so a
completion token contained in your own command never self-matches.

## Notes & limitations

- Completion tokens for `$ulw-loop` should be short (<30 chars) so they don't line-wrap
  in the TUI, which would break `wait` detection.
- The skill never commits Codex's work without your explicit confirmation.
- Risky actions Codex requests (destructive commands, installs, network) are surfaced to
  you rather than auto-approved.
- Not for quick one-off Codex consultations — use a lighter `/codex`-style skill for those.

## Credits

Built on top of [LazyCodex](https://github.com/code-yeongyu/lazycodex) by
[@code-yeongyu](https://github.com/code-yeongyu), which packages
[oh-my-openagent (OmO)](https://github.com/code-yeongyu/oh-my-openagent) as Codex's agent
harness. This skill is an independent orchestration layer and is not affiliated with those
projects.

## License

MIT — see [LICENSE](LICENSE).
