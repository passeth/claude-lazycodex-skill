#!/usr/bin/env bash
# codex-pane.sh — manage a Codex TUI pane in the current tmux window.
# One codex pane per tmux window; pane id persisted so every subcommand is idempotent.
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN: $*" >&2; }

cmd="${1:-help}"
shift || true

STATE_FILE=""

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_tmux_session() {
  [ -n "${TMUX:-}" ] || die "not inside tmux — this skill requires Claude to run in a tmux pane"
}

init_state() {
  require_cmd tmux
  require_tmux_session
  local state_dir key
  state_dir="${TMPDIR:-/tmp}/lazycodex-pane"
  mkdir -p "$state_dir"
  key="$(tmux display-message -p '#{session_id}-#{window_id}' | tr -d '$@')"
  STATE_FILE="$state_dir/$key.pane"
}

pane_alive() {
  tmux list-panes -F '#{pane_id}' 2>/dev/null | grep -qx "$1"
}

get_pane() {
  [ -f "$STATE_FILE" ] || return 1
  local id
  id="$(cat "$STATE_FILE")"
  pane_alive "$id" || { rm -f "$STATE_FILE"; return 1; }
  echo "$id"
}

submit_text() {
  local id text
  id="${1:?pane id required}"
  text="${2:?text required}"
  tmux load-buffer -b lazycodex - <<< "$text"
  tmux paste-buffer -p -b lazycodex -t "$id"
  sleep 0.5
  tmux send-keys -t "$id" Enter
}

is_busy_output() {
  grep -qiE 'esc to interrupt|press esc to interrupt'
}

wait_ready() {
  local id out
  id="${1:?pane id required}"
  for _ in $(seq 1 60); do
    out="$(tmux capture-pane -p -t "$id" 2>/dev/null || true)"
    if echo "$out" | grep -qiE 'Context .*left|Use /skills|esc to interrupt|press esc to interrupt'; then
      return 0
    fi
    sleep 1
  done
  return 1
}

case "$cmd" in
  doctor)
    # doctor — print local readiness checks without mutating panes.
    ok=1
    if command -v tmux >/dev/null 2>&1; then
      echo "PASS tmux: $(tmux -V)"
    else
      echo "FAIL tmux: not found"
      ok=0
    fi

    if [ -n "${TMUX:-}" ]; then
      echo "PASS tmux-session: inside tmux"
    else
      echo "FAIL tmux-session: not inside tmux"
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

    if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
      init_state
      if id="$(get_pane)"; then
        echo "INFO codex-pane: $id"
        "$0" status
      else
        echo "INFO codex-pane: none"
      fi
    fi

    [ "$ok" -eq 1 ] || exit 1
    ;;

  start)
    # start [initial-prompt] — create pane + launch codex; idempotent. Prints pane id.
    init_state
    require_cmd codex
    if id="$(get_pane)"; then echo "$id"; exit 0; fi
    initial_prompt="${1:-}"
    id="$(tmux split-window -h -d -c "$PWD" -P -F '#{pane_id}' "codex")"
    tmux set-option -p -t "$id" remain-on-exit on
    echo "$id" > "$STATE_FILE"
    echo "$id"
    if wait_ready "$id"; then
      if [ -n "$initial_prompt" ]; then
        submit_text "$id" "$initial_prompt"
      fi
    else
      warn "codex ready-marker not seen after 60s; verify with: codex-pane.sh peek"
    fi
    ;;

  send)
    # send "<text>" — bracketed-paste into the composer, then submit with Enter.
    init_state
    id="$(get_pane)" || die "no codex pane; run start first"
    [ $# -gt 0 ] || die "text required"
    submit_text "$id" "$*"
    ;;

  peek)
    # peek [lines] — show the last N lines of the codex pane (default 60).
    init_state
    id="$(get_pane)" || die "no codex pane"
    tmux capture-pane -p -t "$id" -S "-${1:-60}"
    ;;

  status)
    # status — BUSY (codex is working) | IDLE (composer waiting) | NO_PANE
    init_state
    id="$(get_pane)" || { echo "NO_PANE"; exit 0; }
    out="$(tmux capture-pane -p -t "$id" 2>/dev/null || true)"
    if echo "$out" | is_busy_output; then echo "BUSY"; else echo "IDLE"; fi
    ;;

  wait)
    # wait "<regex>" [timeout] — block until regex appears in CODEX OUTPUT (default 570s).
    # Lines starting with '›' (echoed user messages / composer) are excluded, so a
    # done-token contained in the dispatched prompt does not self-match.
    # Exit 0 + tail on match, exit 3 on timeout.
    init_state
    id="$(get_pane)" || die "no codex pane"
    pattern="${1:?pattern required}"
    timeout="${2:-570}"
    interval=5
    elapsed=0
    out=""
    while [ "$elapsed" -lt "$timeout" ]; do
      out="$(tmux capture-pane -p -t "$id" -S -300 2>/dev/null || true)"
      if echo "$out" | grep -vE '^[[:space:]]*›' | grep -qE "$pattern"; then
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
    # wait-idle [timeout] — block until codex stops working (3 consecutive idle checks).
    init_state
    id="$(get_pane)" || die "no codex pane"
    timeout="${1:-570}"
    interval=5
    elapsed=0
    idle_count=0
    while [ "$elapsed" -lt "$timeout" ]; do
      out="$(tmux capture-pane -p -t "$id" 2>/dev/null || true)"
      if echo "$out" | is_busy_output; then
        idle_count=0
      else
        idle_count=$((idle_count + 1))
      fi
      if [ "$idle_count" -ge 3 ]; then
        echo "IDLE"
        echo "---"
        tmux capture-pane -p -t "$id" -S -80
        exit 0
      fi
      sleep "$interval"
      elapsed=$((elapsed + interval))
    done
    echo "TIMEOUT: still busy after ${timeout}s"
    exit 3
    ;;

  keys)
    # keys <keys...> — raw tmux send-keys passthrough (e.g. Escape, Enter, C-c).
    init_state
    id="$(get_pane)" || die "no codex pane"
    [ $# -gt 0 ] || die "keys required"
    tmux send-keys -t "$id" "$@"
    ;;

  stop)
    # stop — interrupt codex and kill the pane.
    init_state
    id="$(get_pane)" || { echo "no pane"; exit 0; }
    tmux send-keys -t "$id" C-c
    sleep 0.5
    tmux send-keys -t "$id" C-c
    sleep 1
    tmux kill-pane -t "$id" 2>/dev/null || true
    rm -f "$STATE_FILE"
    echo "stopped"
    ;;

  *)
    cat <<'EOF'
usage: codex-pane.sh <subcommand>
  doctor                    check tmux, codex, LazyCodex config, and pane state
  start [prompt]            create pane + launch codex (idempotent); prints pane id.
                            optional prompt is submitted after codex is ready.
  send "<text>"             paste text into codex composer and submit
  peek [lines]              show last N lines of the pane (default 60)
  status                    BUSY | IDLE | NO_PANE
  wait "<regex>" [timeout]  block until regex appears (default 570s); exit 3 on timeout
  wait-idle [timeout]       block until codex stops working; exit 3 on timeout
  keys <keys...>            raw tmux send-keys (Escape, Enter, C-c, ...)
  stop                      interrupt codex and kill the pane
EOF
    ;;
esac
