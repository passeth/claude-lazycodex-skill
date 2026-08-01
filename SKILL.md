---
name: lazycodex
description: "Run Codex with the LazyCodex harness ($ulw-plan, $start-work, $ulw-loop, $teammode) in a tmux, herdr, or Orca IDE pane inside the CURRENT session and window, while Claude orchestrates: dispatch the task, monitor progress, answer Codex's questions, verify the result. In Orca, also supports multi-worker A2A via orca orchestration (task dispatch + worker_done). Use when the user says: lazycodex, codex pane, codex한테 시켜, codex로 돌려, ulw-loop, teammode로, codex 하네스, tmux에서 codex, herdr에서 codex, orca에서 codex, orca 워커, a2a로 돌려, and for multi-model pane rosters via the opencodex proxy: 멀티모델, kimi로 돌려, 팬마다 다른 모델, opencodex. NOT for quick codex consultations or reviews — use the /codex skill for those."
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
| Needs decisions/design before code | `$ulw-plan "<what to build>"` | `wait-done` sentinel |
| A plan exists, execute it | `$start-work <plan-name>` | `wait-done` sentinel |
| Open-ended goal, run until verified (the "goal" mode) | `$ulw-loop "<task>" --completion-promise="<TOKEN>"` | `wait-done` sentinel |
| Parallelizable work needing coordination | `$teammode` request (see below) | `wait-done` sentinel |

**Completion is a file, never screen text.** Allocate a sentinel before dispatching and
tell codex to `touch` it as the last step; block on `wait-done`, not `wait`:

```bash
DONE=$($PANE done-file <slug>)      # prints path, clears any stale one
# ...append to the dispatch prompt:
#   "When the work is complete and verified, run exactly: touch $DONE"
$PANE wait-done <slug> 570          # exit 0 = really done | 3 = timeout | 4 = pane died
```

Do **not** use `$PANE wait '<TOKEN>'` to detect a completion promise. Codex wraps a long
prompt across several rendered lines and only the *first* carries the `›` prefix, so the
token sitting in your own dispatched prompt matches immediately — `wait` returns "done"
seconds after dispatch, while codex is still loading. Measured: exit 0 after 6s, zero
files changed. Since this skill also tells you to write long self-contained prompts, the
recommended usage is exactly what triggers it. `wait` remains safe only for markers codex
prints that you never typed (e.g. `ORCHESTRATION COMPLETE`), and even then the sentinel
is the better signal.

- Still pass `--completion-promise` to `$ulw-loop` — it is what makes the harness keep
  iterating until it believes the goal is met. Just don't *detect* on it.
- For teammode, phrase the dispatch as: `$teammode — create a team to <goal>. Members: <one per
  concrete part/ownership area>. Report a final summary when the team's work is merged.`
  On the orca backend, prefer the Orca A2A multi-worker mode (below) over `$teammode`:
  real parallel codex terminals with a tracked lifecycle beat one codex juggling members.
- Big feature = two-phase: dispatch `$ulw-plan`, review the generated `plans/<slug>.md`
  YOURSELF (read the file), relay concerns or approval, then dispatch `$start-work <slug>`.

## Dispatch

```bash
DONE=$($PANE done-file auth)     # allocate the sentinel FIRST
$PANE start "\$ulw-loop \"fix the flaky auth test\" --completion-promise=\"LCX_DONE_AUTH\"
When the work is complete and verified, run exactly: touch $DONE"
```

Launching with the prompt in one shot is preferred for the first command (it avoids the
composer paste entirely). For follow-ups use `$PANE send '<text>'`.

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
$PANE wait-done auth 570   # THE completion signal: 0 = done | 3 = timeout | 4 = pane died
$PANE status               # BUSY | IDLE | BLOCKED (herdr only) | NO_PANE
$PANE peek 80              # read recent output to summarize progress for the user
```

`status` is deliberately biased toward BUSY: any working marker on codex's own screen
(`esc to interrupt`, `Working (…)`, `Waiting for agents`) wins over the backend's idle
probe. That asymmetry is the point — a false BUSY costs one wasted poll, a false IDLE
lets you edit a tree codex is still writing. On orca the native `tui-idle` probe reports
*idle* while `$ulw-loop` blocks on fanned-out subagents, so the screen is right and the
probe is wrong; never trust the probe over visible work. On herdr, `status` can also
return `BLOCKED` — codex is waiting on an approval or a question; triage it like the
"codex asked a question" case below.

**`IDLE` is not `done`.** Only the sentinel means done. An idle pane with no sentinel is
a codex that stopped early, is between subagent phases, or is waiting on you.

Loop protocol:
1. `wait-done` for the sentinel. On exit 3 (timeout), `peek` and triage:
   - Still working (spinner, new output since last peek) → report progress to the user
     in one line, `wait-done` again.
   - Codex asked a question or is `BLOCKED:` → answer it via `$PANE send '...'`.
     Decisions you can make from repo context, make; genuine user decisions, surface.
   - Pane is IDLE without the sentinel → codex may have stopped early. `peek 120`, read
     what happened, and either `send` a follow-up instruction (including a reminder to
     `touch` the sentinel when done) or stop the pane and re-dispatch.
   - Exit 4 (pane died) → tell the user; `codex resume --last` can recover the session.
2. Repeat. No fixed iteration cap — the harness itself caps ulw-loop iterations.

## Concurrency: the repo has one writer

While the codex pane is alive, **codex owns the working tree. You do not touch it.**
No edits, no `git checkout/stash/commit`, no build-fixing "while we wait" — not even a
file codex isn't looking at. Codex re-reads the tree as it works, and it is executing an
older brief than the conversation you are in.

This is not theoretical. A user changed requirements mid-run, the orchestrator edited the
files to match, and codex — faithfully serving its stale brief — reverted those edits
twice as "requirement violations". It was caught by luck just before commit. Under a
false-completion signal (above), the orchestrator starts editing *while codex is still
writing*, and the human's newest decision silently loses.

- **Changed your mind mid-run?** `$PANE stop` → make the edits → re-dispatch with a fresh
  brief. Never edit around a live pane.
- **Verification happens after the sentinel**, never before. That is the whole reason
  completion detection has to be trustworthy.
- **Prefer isolation for long runs.** On orca, give `$ulw-loop` its own checkout
  (`orca worktree create --name <slug> --agent codex --json`). Then codex writes to its
  own tree, and a bad completion signal degrades to "I read a stale diff" instead of two
  writers silently clobbering each other.

## Multi-model panes (opencodex)

Panes can run **different models per worker** — design on a strong model, mechanical
work on a cheap one, review on a different family. Codex ≥0.146 removed
`wire_api = "chat"`, so non-OpenAI providers (Kimi, DeepSeek, xAI, …) **require the
[opencodex](https://github.com/lidge-jun/opencodex) proxy** (`ocx`) to translate the
Responses API — native `model_providers` config no longer works for them (verified:
Moonshot has no `/v1/responses`, and a `wire_api = "chat"` entry makes codex refuse to
load its config at all). Mixing at the *pane* level also sidesteps opencodex's known
in-codex cross-model delegation bug (opencodex#92).

Per-pane model pinning (verified end-to-end with sentinel completion):

```bash
LAZYCODEX_PANE_NAME=worker-arch LAZYCODEX_CODEX_ARGS="-m gpt-5.5 -c mcp_servers={}" \
  $PANE start "\$ulw-loop ... touch <sentinel-a>"
LAZYCODEX_PANE_NAME=worker-impl LAZYCODEX_CODEX_ARGS="-m moonshot/kimi-k3 -c mcp_servers={}" \
  $PANE start "\$ulw-loop ... touch <sentinel-b>"
```

Setup (once): `npm i -g @bitkyc08/opencodex` → `ocx start` → `ocx provider add <name>
--api-key ...` → **`ocx restart`** → `ocx sync`. The restart is not optional: a running
proxy does not load a newly added provider into memory, and requests then silently
pass through to OpenAI as `openai/<provider>/<model>` (visible in `ocx observe logs`,
which is also how you verify routing: correct entries look like `<provider>/<model>`).

Hard-won rules:

- **Preflight**: `$PANE start` auto-starts a dead proxy (`ocx ensure` + health polling,
  detached `ocx start` as fallback) whenever the pane pins a routed model or the config
  is proxy-injected — no manual `ocx start` needed. It still pays to know the proxy is a
  shared single point of failure: if it dies mid-run, every routed pane fails at once,
  and `doctor` reports the exact state.
- **Never `ocx stop` while panes are live** — it restores native codex config out from
  under them. Treat it like editing the shared tree.
- **Orca rewrites its codex config from `~/.codex/config.toml`.** Orca copies that file
  into its per-account `CODEX_HOME` (`~/Library/Application Support/orca/codex-accounts/
  <id>/home/`) when creating terminals, silently erasing the proxy injection. Inject
  BOTH: `env -u CODEX_HOME ocx sync` (the source orca copies) and `ocx sync` (the live
  account home). After any routing failure, `grep openai_base_url` both configs first.
- **`ocx sync --restart-codex` SIGTERMs every codex app-server on the machine** — all
  homes, including ChatGPT.app's. Check for live runs (`ps -o %cpu -p <pids>`) before
  using it; idle app-servers respawn harmlessly on next launch.
- **Roster only non-deprecated models.** A deprecated `-m` model (e.g. gpt-5.4-mini)
  triggers a blocking switch dialog at startup that eats the dispatched prompt.
- **Provider add can be lost** (config.json observed rewritten once). After add, confirm
  with `jq '.providers|keys' ~/.opencodex/config.json` and `ocx provider test <name>`.
- A provider-side 429/400 shows up in `ocx observe logs` with the provider prefix — that
  means routing worked and the problem is upstream (quota, billing, budget caps).
- `-c mcp_servers={}` clears only top-level MCP servers; plugin-scoped ones
  (`[plugins."...".mcp_servers.*]`) still start. The fd-exhaustion warning below stands.

### Orca pane input quirks (any model)

`$PANE keys` on the orca backend maps `Enter`, `Escape`, `C-c`, `Tab`, `Space`, the
arrow keys, and `BSpace` — any other name is sent as **literal text** into the
composer. So:

- Answer codex dialogs (model switch, hooks trust) by sending the option **digit** as
  text then `Enter` — it is one keypress and immune to mapping gaps. Arrows work too,
  but verify with `peek` before `Enter`.
- Never use `Escape` to "clear the composer" while codex is working — it interrupts the
  turn and pauses the harness goal (recover with `$PANE send '/goal resume'`).
- **Hook-trust resets per pane.** Orca's config rewrite (see above) also resets codex's
  hooks-trust state, so the "Hooks need review" dialog can reappear on any new pane.
  Answer it with `2` + `Enter` (Trust all — they are the user's own omo plugin hooks).
- Orca can start typing the launch command before the shell finishes init, eating
  leading characters (`command not found: odex`). `start` now detects this and relaunches
  in the live shell automatically; readiness is judged by real codex markers, not
  `tui-idle` (which is also true for a bare shell).

## Orca A2A multi-worker mode

Backend is orca AND the work splits into 2+ independent parts → skip `$teammode`
and use orca's native orchestration: one codex terminal per part, tracked
task/dispatch lifecycle, `worker_done` as the done signal. Each worker still runs
the LazyCodex harness inside its own dispatch, so you get harness autonomy *and*
deterministic completion. Keep it to 3–4 workers; deeper DAGs aren't worth
coordinating. Workers must not share files — split by ownership, or give truly
independent work its own worktree.

```bash
# 0) state check
orca status --json && orca worktree ps --json && orca terminal list --json

# 1) one worker per part — same worktree (shares uncommitted state).
#    ALWAYS launch workers with MCP off: codex's app-server inherits launchd's
#    256-fd limit, and each stdio MCP server holds pipes against it. A few parallel
#    MCP-laden workers wedge the shared app-server with "Too many open files
#    (os error 24)" — which silently kills the run (see the warning below).
orca terminal create --worktree active --title "worker-<part>" \
  --command "codex -c 'mcp_servers={}'" --json          # → .result.terminal.handle
#    OR isolated checkout (only for truly independent work; no uncommitted deps):
orca worktree create --name <part> --agent codex --json  # → .result.startupTerminal.handle

# 2) readiness gate — tui-idle alone is NOT enough (see below)
orca terminal wait --terminal <handle> --for tui-idle --timeout-ms 60000 --json
orca terminal show --terminal <handle> --json | jq -r '.result.terminal.preview'
#    Composer ready → preview contains "Context ... left" / "esc to interrupt" / "/model to change".
#    Login screen  → preview contains "Sign in" / "device code" / "code_challenge": DO NOT dispatch.
#    Neither yet   → codex is still painting; re-poll every 3s (takes ~2 polls in practice).

# 3) task + dispatch (--inject sends spec + lifecycle preamble into codex)
orca orchestration task-create --spec "<self-contained brief>" --task-title "<short>" --json  # → task id
orca orchestration dispatch --task <task_id> --to <handle> --inject --json

# 4) confirm the worker actually took the task before you start waiting
orca terminal read --terminal <handle> --limit 80 --json   # expect the spec echoed + "Working"

# 5) supervision loop — one message per call; loop once per outstanding worker
orca orchestration check --wait --types worker_done,escalation,decision_gate --timeout-ms 570000 --json
```

**`tui-idle` lies about readiness.** It returns `ok=true` on codex's *login screen* too. Dispatch
then types the whole spec into a sign-in prompt, it vanishes, and the coordinator waits forever for
a `worker_done` that can never come. Always run the readiness gate above, and always confirm receipt
(step 4) before entering the wait loop. A dispatch the worker never saw looks exactly like a slow
worker.

Rules (mirror orca's official orchestration conventions):

- Write each `--spec` self-contained in English, like a `send` dispatch prompt: task,
  file paths, constraints ("pnpm only", "must pass pnpm build"), evidence of done.
- **Put the harness *inside* the spec** — this is the whole point of using this skill
  instead of bare orca orchestration. Structure each spec as two steps:

  ```
  Step 1 - run exactly this harness command in your composer:
  $ulw-loop "<the actual task>" --completion-promise="LCX_DONE_<SLUG>"

  Step 2 - once the harness prints LCX_DONE_<SLUG>, do BOTH, in this order:
    a) run exactly: touch <sentinel path from `$PANE done-file <slug>`>
    b) send worker_done exactly as your dispatch preamble instructs, with reportPath=<path>.
  ```

  The harness loop and the dispatch lifecycle do **not** conflict: `$ulw-loop` runs to its
  own completion promise, and only then does the worker report. Verified end-to-end — the
  worker ran the loop, hit its promise token, wrote its report, and issued a correct
  `worker_done` (matching taskId/dispatchId/coordinator handle).

  The sentinel in (a) is not redundant: `worker_done` has been observed to go missing (see
  below), and it is the only completion signal a coordinator can poll without the message
  bus. Wait on `check --wait` *and* the sentinel files; whichever lands first is the truth.
- Run `check --wait` with `run_in_background: true` (keep `--timeout-ms` ≤ 570000,
  under the Bash timeout). A timeout or `{count:0}` is a checkpoint, NOT a failure —
  coding tasks run 15–60 min. Liveness-check with `orca terminal read`/`tui-idle`,
  then wait again. Never kill a worker just because it hasn't reported yet.
- **Known gap: `worker_done` sent from inside codex can go missing.** Observed once — the
  worker ran `orca orchestration send` as a tool call, the CLI returned a message id, but
  the message never reached the coordinator's inbox and the task stayed `dispatched`. The
  same send from a plain shell terminal arrives instantly, so delivery itself is fine;
  something about codex's sandboxed tool shell drops it. Root cause unconfirmed. Therefore:
  **never treat a missing `worker_done` as a missing result.** When a wait window closes,
  read the worker's terminal — if it shows the completion promise and a "Sent msg_..." line,
  the work is done; take the report from disk (`reportPath`) and close the task yourself
  with `orca orchestration task-update --id <task_id> --status completed`.
- `decision_gate`/`ask` messages: answer with
  `orca orchestration reply --id <msg_id> --body '<answer>' --json`, then keep waiting.
  Decisions you can make from repo context, make; genuine user decisions, surface.
- A valid `worker_done` auto-completes the task — don't follow it with `task-update`.
  Verify each worker's result yourself (section below) before accepting it; on failure,
  re-dispatch with the failure evidence via a fresh `task-create` + `dispatch`, or
  `orca terminal send --terminal <handle> --text '<fix instruction>' --enter --json`.
- Workers created here are yours to close; never `terminal close` handles you didn't
  create. Leave them open after the run unless the user asks to clean up.
- **A silent worker is not a slow worker.** `worker_done` is itself a shell command the
  worker must spawn (`orca orchestration send`), so a worker whose tool execution is
  broken can never report — the coordinator just sees `check --wait` time out forever.
  Before treating a timeout as "still working", confirm the worker is actually alive:
  `orca terminal read --terminal <handle>` and look for real progress, not just a
  spinner. `Too many open files (os error 24)` in a worker means the codex app-server
  hit its 256-fd ceiling: stop dispatching, and see the MCP note above. When workers
  die that way, close them — leaving them retrying only burns more descriptors.
- Single-pane orca runs (one codex, `$ulw-loop` + completion promise) still go through
  `$PANE` — this section is only for parallel fan-out.

## Verify (Claude's job, never skipped)

Codex saying done ≠ done. **Verify only after the sentinel lands** — verifying against a
tree codex is still writing is the race described under Concurrency, and it is worse than
not verifying at all. Re-confirm before you touch anything:

```bash
$PANE wait-done <slug> 570 && $PANE status   # sentinel present AND pane not BUSY
```

Then, from YOUR pane:

- `git -C <repo> status && git diff --stat` — what actually changed.
- Run the project's checks yourself (for this machine's projects typically
  `pnpm tsc --noEmit` / `pnpm build` / tests).
- Spot-read the changed files against the original ask.

If verification fails, do **not** fix it yourself in the shared tree. Send the failure
evidence back and let codex own the edit:
`$PANE send 'Verification failed: <exact error>. Fix it, then touch <sentinel> again.'`
(`$PANE done-file <slug>` first, to clear the old sentinel.) Then re-enter the monitor loop.

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
- **Codex runs unsandboxed and inherits the project environment.** It gets a real shell in
  the repo, with whatever `.env` / credentials that repo carries. In a repo wired to a
  production database, "don't touch the DB" is a sentence in a prompt, not an enforcement
  boundary — nothing stops a harness iteration from running a migration or a destructive
  query against prod. Before dispatching into such a repo: confirm with the user, state in
  the prompt which environments are off-limits, and prefer an isolated worktree with
  non-production credentials. Combined with an unreliable completion signal and a shared
  working tree, the worst case here is not a lost edit.
