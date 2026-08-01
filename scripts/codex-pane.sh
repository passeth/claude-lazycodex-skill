#!/usr/bin/env bash
# codex-pane.sh — manage a Codex TUI pane next to Claude, via tmux, herdr, OR orca.
# One codex pane per tmux window / herdr tab / orca worktree; pane id persisted
# so every subcommand is idempotent. Set LAZYCODEX_PANE_NAME to manage several
# named panes side by side (each name gets its own state file and pane).
#
# Backend auto-detection: $TMUX set → tmux; $ORCA_TERMINAL_HANDLE set + orca CLI
# present → orca; $HERDR_PANE_ID set + herdr CLI present → herdr.
# Override with LAZYCODEX_BACKEND=tmux|herdr|orca.
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

if [ -n "${LAZYCODEX_BACKEND:-}" ]; then
  BACKEND="$LAZYCODEX_BACKEND"
elif [ -n "${TMUX:-}" ]; then
  BACKEND="tmux"
elif [ -n "${ORCA_TERMINAL_HANDLE:-}" ] && command -v orca >/dev/null 2>&1; then
  BACKEND="orca"
elif [ -n "${HERDR_PANE_ID:-}" ] && command -v herdr >/dev/null 2>&1; then
  BACKEND="herdr"
else
  BACKEND=""   # only doctor/help may run without a backend
fi
case "$BACKEND" in tmux|herdr|orca|"") ;; *) die "unknown backend: $BACKEND" ;; esac
[ "$BACKEND" = "orca" ] && ! command -v jq >/dev/null 2>&1 && die "orca backend requires jq"

STATE_DIR="${TMPDIR:-/tmp}/lazycodex-pane"
mkdir -p "$STATE_DIR"
if [ "$BACKEND" = "tmux" ]; then
  KEY="tmux-$(tmux display-message -p '#{session_id}-#{window_id}' | tr -d '$@')"
elif [ "$BACKEND" = "orca" ]; then
  KEY="orca-$(printf '%s' "${ORCA_WORKTREE_ID:-w0}" | cksum | cut -d' ' -f1)"
elif [ "$BACKEND" = "herdr" ]; then
  KEY="herdr-$(printf '%s-%s' "${HERDR_WORKSPACE_ID:-w0}" "${HERDR_TAB_ID:-t0}" | tr -d ':')"
else
  KEY="none"
fi
STATE_FILE="$STATE_DIR/$KEY${LAZYCODEX_PANE_NAME:+-$LAZYCODEX_PANE_NAME}.pane"

# ---------- backend primitives ----------------------------------------------

herdr_pane_id() { grep -o '"pane_id":"[^"]*"' | head -1 | cut -d'"' -f4; }

orca_send() {
  # orca_send <handle> <send-flags...>
  local id="$1"; shift
  orca terminal send --terminal "$id" "$@" --json >/dev/null 2>&1
}

herdr_key() {
  # translate tmux key names to herdr key-combo strings
  case "$1" in
    Enter)  echo "enter" ;;
    Escape) echo "esc" ;;
    Space)  echo "space" ;;
    Tab)    echo "tab" ;;
    Up)     echo "up" ;;
    Down)   echo "down" ;;
    C-?)    echo "ctrl+$(printf '%s' "${1#C-}" | tr '[:upper:]' '[:lower:]')" ;;
    M-?)    echo "alt+$(printf '%s' "${1#M-}" | tr '[:upper:]' '[:lower:]')" ;;
    *)      echo "$1" ;;
  esac
}

be_alive() {
  case "$BACKEND" in
    tmux) tmux list-panes -F '#{pane_id}' 2>/dev/null | grep -qx "$1" ;;
    orca) orca terminal show --terminal "$1" --json 2>/dev/null | jq -e '.ok == true' >/dev/null 2>&1 ;;
    *)    herdr pane get "$1" >/dev/null 2>&1 ;;
  esac
}

be_spawn() {
  # be_spawn "<shell command>" → create pane running command, print pane id
  local cmd="$1" id
  case "$BACKEND" in
    tmux)
      id="$(tmux split-window -h -d -c "$PWD" -P -F '#{pane_id}' "$cmd")"
      tmux set-option -p -t "$id" remain-on-exit on
      ;;
    orca)
      # new terminal tab in the current worktree, no focus steal
      id="$(orca terminal create --worktree active --title "${LAZYCODEX_PANE_NAME:-codex}" \
            --command "$cmd" --json 2>/dev/null | jq -r '.result.terminal.handle // empty')"
      [ -n "$id" ] || return 1
      ;;
    *)
      id="$(herdr pane split --pane "$HERDR_PANE_ID" --direction right --cwd "$PWD" --no-focus | herdr_pane_id)"
      [ -n "$id" ] || return 1
      sleep 0.5   # let the pane's shell come up before typing into it
      herdr pane run "$id" "$cmd" >/dev/null
      ;;
  esac
  echo "$id"
}

be_paste() {
  # paste text into the pane's composer WITHOUT submitting
  local id="$1" text="$2"
  case "$BACKEND" in
    tmux)
      tmux load-buffer -b lazycodex - <<< "$text"
      tmux paste-buffer -p -b lazycodex -t "$id"
      ;;
    orca) orca_send "$id" --text "$text" ;;
    *)    herdr pane send-text "$id" "$text" >/dev/null ;;
  esac
}

be_keys() {
  local id="$1"; shift
  case "$BACKEND" in
    tmux) tmux send-keys -t "$id" "$@" ;;
    orca)
      # tmux key names → bytes. Unmapped names fall through as literal text, so
      # keep dialog answers to mapped keys or digits. A bare ESC byte can swallow
      # the next char if sent back-to-back, hence the sleep after Escape (arrow
      # CSI sequences are complete and safe).
      local k
      for k in "$@"; do
        case "$k" in
          Enter)  orca_send "$id" --enter ;;
          Escape) orca_send "$id" --text "$(printf '\033')"; sleep 0.3 ;;
          C-c)    orca_send "$id" --interrupt ;;
          Tab)    orca_send "$id" --text "$(printf '\t')" ;;
          Space)  orca_send "$id" --text ' ' ;;
          Up)     orca_send "$id" --text "$(printf '\033[A')" ;;
          Down)   orca_send "$id" --text "$(printf '\033[B')" ;;
          Right)  orca_send "$id" --text "$(printf '\033[C')" ;;
          Left)   orca_send "$id" --text "$(printf '\033[D')" ;;
          BSpace) orca_send "$id" --text "$(printf '\177')" ;;
          *)      orca_send "$id" --text "$k" ;;
        esac
      done
      ;;
    *)
      local k; local args=()
      for k in "$@"; do args+=("$(herdr_key "$k")"); done
      herdr pane send-keys "$id" "${args[@]}" >/dev/null
      ;;
  esac
}

ensure_proxy() {
  # A live opencodex proxy is required when the pane pins a routed model
  # (-m provider/model) or the codex config routes through the proxy
  # (openai_base_url injection) — a dead proxy then fails every request.
  command -v ocx >/dev/null 2>&1 || return 0
  ocx health >/dev/null 2>&1 && return 0
  echo "opencodex proxy down — starting (ocx ensure)…" >&2
  # cold-start can exit unhealthy while the daemon is still warming up, so
  # poll health instead of trusting the exit code (measured: ~8s warm-up).
  ocx ensure >/dev/null 2>&1 || true
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    ocx health >/dev/null 2>&1 && { echo "opencodex proxy up" >&2; return 0; }
    sleep 1
  done
  # last resort: ocx start runs in the foreground by design, so detach it.
  (nohup ocx start >/dev/null 2>&1 &)
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    ocx health >/dev/null 2>&1 && { echo "opencodex proxy up" >&2; return 0; }
    sleep 1
  done
  die "opencodex proxy failed to start — run 'ocx start' manually, or 'ocx restore' to detach codex from the proxy"
}

be_screen() {
  # visible screen only (for readiness / busy heuristics)
  case "$BACKEND" in
    tmux) tmux capture-pane -p -t "$1" 2>/dev/null || true ;;
    orca) orca terminal read --terminal "$1" --json 2>/dev/null | jq -r '.result.terminal.tail[]? // empty' || true ;;
    *)    herdr pane read "$1" --source visible 2>/dev/null || true ;;
  esac
}

be_capture() {
  # be_capture <id> <lines> — last N lines including scrollback.
  # herdr: codex's TUI renders on the alternate screen, which `recent` does not
  # include — so append `visible` (current screen) after the scrollback.
  case "$BACKEND" in
    tmux) tmux capture-pane -p -t "$1" -S "-$2" 2>/dev/null || true ;;
    orca) orca terminal read --terminal "$1" --limit "$2" --json 2>/dev/null | jq -r '.result.terminal.tail[]? // empty' || true ;;
    *)
      {
        herdr pane read "$1" --source recent --lines "$2" 2>/dev/null
        herdr pane read "$1" --source visible 2>/dev/null
      } || true
      ;;
  esac
}

screen_busy() {
  # Does the codex screen itself claim to be working? A false BUSY only costs a
  # wasted poll; a false IDLE lets the orchestrator edit a tree codex is writing.
  # So any busy evidence wins over a backend probe that says idle.
  # 'Waiting for agents' matters: $ulw-loop fans out subagents, and while the
  # parent blocks on them orca's tui-idle probe reports idle even though the run
  # is very much alive.
  be_screen "$1" | grep -qiE 'esc to interrupt|Working \(|Waiting for agents|Waiting for subagent'
}

be_status() {
  # BUSY | IDLE | BLOCKED (BLOCKED only detectable on herdr)
  local id="$1" st
  # Screen evidence of work outranks every backend probe (see screen_busy).
  if screen_busy "$id"; then echo "BUSY"; return 0; fi

  if [ "$BACKEND" = "herdr" ]; then
    st="$(herdr pane get "$id" 2>/dev/null | grep -o '"agent_status":"[^"]*"' | cut -d'"' -f4 || true)"
    case "$st" in
      working)   echo "BUSY";    return 0 ;;
      blocked)   echo "BLOCKED"; return 0 ;;
      idle|done) echo "IDLE";    return 0 ;;
    esac
    # agent_status unknown → fall through to screen heuristic
  fi
  if [ "$BACKEND" = "orca" ]; then
    st="$(orca terminal show --terminal "$id" --json 2>/dev/null | jq -r '.result.terminal.status // empty')"
    if [ -n "$st" ] && [ "$st" != "running" ]; then echo "IDLE"; return 0; fi
    if orca terminal wait --terminal "$id" --for tui-idle --timeout-ms 1500 --json 2>/dev/null \
        | jq -e '.ok == true' >/dev/null 2>&1; then
      echo "IDLE"
    else
      echo "BUSY"
    fi
    return 0
  fi
  echo "IDLE"
}

be_kill() {
  case "$BACKEND" in
    tmux) tmux kill-pane -t "$1" 2>/dev/null || true ;;
    orca) orca terminal close --terminal "$1" --json >/dev/null 2>&1 || true ;;
    *)    herdr pane close "$1" >/dev/null 2>&1 || true ;;
  esac
}

# ---------- state ------------------------------------------------------------

done_path() {
  # done_path <slug> — sentinel file for one dispatch. Deterministic so the
  # orchestrator and codex agree on it without passing state around.
  local slug="$1"
  printf '%s/%s%s-%s.done' "$STATE_DIR" "$KEY" "${LAZYCODEX_PANE_NAME:+-$LAZYCODEX_PANE_NAME}" "$slug"
}

get_pane() {
  [ -f "$STATE_FILE" ] || return 1
  local id
  id="$(cat "$STATE_FILE")"
  be_alive "$id" || { rm -f "$STATE_FILE"; return 1; }
  echo "$id"
}

# ---------- subcommands -------------------------------------------------------

cmd="${1:-help}"
shift || true

case "$cmd" in
  doctor|help|--help|-h) ;;
  *) [ -n "$BACKEND" ] || die "not inside tmux, orca, or herdr — this skill requires Claude to run in a tmux/orca/herdr terminal" ;;
esac

case "$cmd" in
  doctor)
    # doctor — print readiness checks without mutating panes.
    ok=1
    if [ -n "$BACKEND" ]; then
      echo "PASS backend: $BACKEND"
      if [ "$BACKEND" = "orca" ] && ! command -v jq >/dev/null 2>&1; then
        echo "FAIL jq: required for the orca backend"
        ok=0
      fi
    else
      echo "FAIL backend: not inside tmux, orca, or herdr"
      ok=0
    fi

    if command -v codex >/dev/null 2>&1; then
      echo "PASS codex: $(codex --version 2>/dev/null || echo installed)"
    else
      echo "FAIL codex: not found"
      ok=0
    fi

    config="${CODEX_HOME:-$HOME/.codex}/config.toml"
    if [ -f "$config" ] && grep -q 'omo@sisyphuslabs' "$config"; then
      echo "PASS lazycodex-plugin: omo@sisyphuslabs configured"
    else
      echo "FAIL lazycodex-plugin: omo@sisyphuslabs not found in $config"
      echo "HINT install with: npx lazycodex-ai install"
      ok=0
    fi

    # opencodex proxy (multi-model panes). Injected config + dead proxy means
    # EVERY codex request fails, so that combination is a hard FAIL.
    if grep -q '^openai_base_url' "$config" 2>/dev/null; then
      if command -v ocx >/dev/null 2>&1 && ocx health >/dev/null 2>&1; then
        echo "PASS opencodex: proxy healthy, injection present"
      else
        echo "FAIL opencodex: $config routes codex through the proxy but 'ocx health' fails — all codex requests will fail"
        echo "HINT run: ocx start   (or 'ocx restore' to detach codex from the proxy)"
        ok=0
      fi
      # orca copies ~/.codex/config.toml over CODEX_HOME on terminal create,
      # silently erasing the injection if only the account home was synced.
      if [ "$BACKEND" = "orca" ] && [ -f "$HOME/.codex/config.toml" ] \
         && ! grep -q '^openai_base_url' "$HOME/.codex/config.toml"; then
        echo "WARN opencodex: ~/.codex/config.toml lacks the injection — orca will erase it on the next terminal create"
        echo "HINT run: env -u CODEX_HOME ocx sync"
      fi
    elif command -v ocx >/dev/null 2>&1 && ocx health >/dev/null 2>&1; then
      echo "WARN opencodex: proxy is running but $config has no injection — routed models (-m provider/model) will not work"
      echo "HINT run: ocx sync"
    fi

    if [ -n "$BACKEND" ]; then
      if id="$(get_pane)"; then
        echo "INFO codex-pane: $id ($(be_status "$id"))"
      else
        echo "INFO codex-pane: none"
      fi
    fi

    [ "$ok" -eq 1 ] || exit 1
    ;;
  start)
    # start [initial-prompt] — create pane + launch codex; idempotent. Prints pane id.
    if id="$(get_pane)"; then echo "$id"; exit 0; fi
    # auto-start the opencodex proxy when this pane needs it
    case " ${LAZYCODEX_CODEX_ARGS:-}" in
      *" -m "*/*) ensure_proxy ;;   # routed model (provider/model) requested
      *) grep -q '^openai_base_url' "${CODEX_HOME:-$HOME/.codex}/config.toml" 2>/dev/null \
           && ensure_proxy ;;       # config already routes through the proxy
    esac
    # LAZYCODEX_CODEX_ARGS injects codex flags, e.g. -c 'mcp_servers={}' to launch
    # without MCP servers (each stdio MCP holds pipes against the codex app-server's
    # 256-fd launchd limit; a heavy MCP config wedges it with EMFILE).
    codex_cmd="codex${LAZYCODEX_CODEX_ARGS:+ $LAZYCODEX_CODEX_ARGS}"
    if [ $# -gt 0 ] && [ -n "${1:-}" ]; then
      launch="$codex_cmd $(printf '%q' "$1")"
    else
      launch="$codex_cmd"
    fi
    id="$(be_spawn "$launch")" || die "failed to create codex pane"
    echo "$id" > "$STATE_FILE"
    if [ "$BACKEND" = "orca" ]; then
      orca terminal wait --terminal "$id" --for tui-idle --timeout-ms 60000 --json 2>/dev/null \
        | jq -e '.ok == true' >/dev/null 2>&1 || true
      # tui-idle is not proof codex is up: orca can start typing --command before
      # the shell finishes init, eating leading chars ("command not found: odex"),
      # and the resulting bare shell is also "idle". Require a real codex marker,
      # and relaunch once inside the live shell if the command got eaten.
      relaunched=0
      for _ in $(seq 1 30); do
        screen="$(be_screen "$id")"
        if echo "$screen" | grep -qiE 'Context .*left|esc to interrupt|Use /skills|Starting MCP'; then
          echo "$id"
          exit 0
        fi
        if [ "$relaunched" -eq 0 ] && echo "$screen" | grep -q 'command not found'; then
          echo "WARN: orca ate the launch command (shell not ready); relaunching in the live shell" >&2
          orca_send "$id" --text "$launch"
          sleep 0.3
          orca_send "$id" --enter
          relaunched=1
        fi
        sleep 2
      done
      echo "$id"
      echo "WARN: codex ready-marker not seen after 60s; verify with: codex-pane.sh peek" >&2
      exit 0
    fi
    for _ in $(seq 1 60); do
      out="$(be_screen "$id")"
      if echo "$out" | grep -qiE 'Context .*left|Use /skills|esc to interrupt'; then
        echo "$id"
        exit 0
      fi
      sleep 1
    done
    echo "$id"
    echo "WARN: codex ready-marker not seen after 60s; verify with: codex-pane.sh peek" >&2
    ;;

  send)
    # send "<text>" — paste into the composer, then submit with Enter.
    id="$(get_pane)" || die "no codex pane; run start first"
    text="${1:?text required}"
    be_paste "$id" "$text"
    sleep 0.5
    be_keys "$id" Enter
    ;;

  peek)
    # peek [lines] — show the last N lines of the codex pane (default 60).
    id="$(get_pane)" || die "no codex pane"
    be_capture "$id" "${1:-60}"
    ;;

  status)
    # status — BUSY (working) | IDLE (composer waiting) | BLOCKED (herdr) | NO_PANE
    id="$(get_pane)" || { echo "NO_PANE"; exit 0; }
    be_status "$id"
    ;;

  done-file)
    # done-file <slug> — print the sentinel path for a dispatch, clearing any stale
    # one first. Call this BEFORE dispatching, and put the printed path in the prompt:
    #   "When the work is complete and verified, run: touch <path>"
    # Then block on `wait-done <slug>`. A file cannot be forged by the TUI echoing
    # your own prompt back — which is exactly how text-marker `wait` gives a false
    # completion (codex wraps a long prompt across lines; only the first carries '›').
    slug="${1:?slug required}"
    p="$(done_path "$slug")"
    rm -f "$p"
    echo "$p"
    ;;

  wait-done)
    # wait-done <slug> [timeout] — block until codex touches the sentinel (default 570s).
    # Exit 0 on completion, 3 on timeout, 4 if the pane died before completing.
    slug="${1:?slug required}"
    timeout="${2:-570}"
    p="$(done_path "$slug")"
    id="$(get_pane)" || die "no codex pane"
    elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
      if [ -e "$p" ]; then
        echo "DONE: $p"
        echo "---"
        be_capture "$id" 40
        exit 0
      fi
      if ! be_alive "$id"; then
        echo "PANE DIED before completing (sentinel $p never appeared)"
        exit 4
      fi
      sleep 5
      elapsed=$((elapsed + 5))
    done
    echo "TIMEOUT after ${timeout}s — sentinel not created. status=$(be_status "$id"). last output:"
    echo "---"
    be_capture "$id" 40
    exit 3
    ;;

  wait)
    # wait "<regex>" [timeout] — block until regex appears in CODEX OUTPUT (default 570s).
    #
    # WARNING: only safe for markers codex prints but YOU never typed (e.g.
    # 'ORCHESTRATION COMPLETE' from $start-work). It CANNOT reliably detect a
    # --completion-promise token: codex wraps long prompts across several lines and
    # only the first line carries the '›' prefix, so the token sitting in your own
    # dispatched prompt matches immediately and `wait` returns while codex is still
    # starting up. For completion, use done-file + wait-done instead.
    #
    # Exit 0 + tail on match, exit 3 on timeout.
    id="$(get_pane)" || die "no codex pane"
    pattern="${1:?pattern required}"
    timeout="${2:-570}"
    interval=5
    elapsed=0
    out=""
    while [ "$elapsed" -lt "$timeout" ]; do
      out="$(be_capture "$id" 300)"
      if echo "$out" | grep -vE '^[[:space:]]*›|^[[:space:]]*codex[[:space:]]' | grep -qE "$pattern"; then
        echo "MATCHED: $pattern"
        echo "---"
        echo "$out" | tail -40
        exit 0
      fi
      sleep "$interval"
      elapsed=$((elapsed + interval))
    done
    echo "TIMEOUT after ${timeout}s — last output:"
    echo "---"
    echo "$out" | tail -40
    exit 3
    ;;

  wait-idle)
    # wait-idle [timeout] — block until codex stops working (3 consecutive non-busy checks).
    id="$(get_pane)" || die "no codex pane"
    timeout="${1:-570}"
    interval=5
    elapsed=0
    idle_count=0
    st="IDLE"
    while [ "$elapsed" -lt "$timeout" ]; do
      st="$(be_status "$id")"
      if [ "$st" = "BUSY" ]; then
        idle_count=0
      else
        idle_count=$((idle_count + 1))
      fi
      if [ "$idle_count" -ge 3 ]; then
        echo "$st"
        echo "---"
        be_capture "$id" 80
        exit 0
      fi
      sleep "$interval"
      elapsed=$((elapsed + interval))
    done
    echo "TIMEOUT: still busy after ${timeout}s"
    exit 3
    ;;

  keys)
    # keys <keys...> — send keys using tmux names (Escape, Enter, C-c, ...);
    # translated automatically on herdr.
    id="$(get_pane)" || die "no codex pane"
    be_keys "$id" "$@"
    ;;

  stop)
    # stop — interrupt codex and kill the pane.
    id="$(get_pane)" || { echo "no pane"; exit 0; }
    be_keys "$id" C-c
    sleep 0.5
    be_keys "$id" C-c
    sleep 1
    be_kill "$id"
    rm -f "$STATE_FILE"
    rm -f "$STATE_DIR/$KEY${LAZYCODEX_PANE_NAME:+-$LAZYCODEX_PANE_NAME}"-*.done
    echo "stopped"
    ;;

  focus)
    # focus — reveal the codex pane in the UI (orca/tmux; no-op on herdr).
    id="$(get_pane)" || die "no codex pane"
    case "$BACKEND" in
      tmux) tmux select-pane -t "$id" ;;
      orca) orca terminal switch --terminal "$id" --json >/dev/null 2>&1 ;;
      *)    echo "focus not supported on herdr" >&2 ;;
    esac
    ;;

  backend)
    # backend — print which backend is active (tmux | herdr | orca).
    echo "$BACKEND"
    ;;

  *)
    cat <<'EOF'
usage: codex-pane.sh <subcommand>          (backend: tmux, herdr, or orca — auto-detected)
  start [prompt]            create pane + launch codex (idempotent); prints pane id.
                            optional prompt is submitted on launch.
  doctor                    readiness checks (backend, codex CLI, LazyCodex plugin)
  send "<text>"             paste text into codex composer and submit
  peek [lines]              show last N lines of the pane (default 60)
  status                    BUSY | IDLE | BLOCKED (herdr only) | NO_PANE
  done-file <slug>          print (and clear) the sentinel path for a dispatch
  wait-done <slug> [timeout]  block until codex touches the sentinel — THE completion
                            signal. exit 3 timeout, exit 4 pane died.
  wait "<regex>" [timeout]  block until regex appears (default 570s); exit 3 on timeout.
                            UNSAFE for tokens you typed yourself — see wait-done.
  wait-idle [timeout]       block until codex stops working; exit 3 on timeout
  keys <keys...>            send keys, tmux names (Escape, Enter, C-c, ...)
  focus                     reveal the codex pane in the UI (tmux/orca)
  stop                      interrupt codex and kill the pane
  backend                   print active backend (tmux | herdr | orca)

env: LAZYCODEX_BACKEND=tmux|herdr|orca overrides detection.
     LAZYCODEX_PANE_NAME=<name> manages a separate named pane (multi-worker).
EOF
    ;;
esac
