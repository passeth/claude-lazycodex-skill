#!/usr/bin/env bash
# codex-pane.sh — manage a Codex TUI pane in the current tmux window.
# One codex pane per tmux window; pane id persisted so every subcommand is idempotent.
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
[ -n "${TMUX:-}" ] || die "not inside tmux — this skill requires Claude to run in a tmux pane"

STATE_DIR="${TMPDIR:-/tmp}/lazycodex-pane"
mkdir -p "$STATE_DIR"
KEY="$(tmux display-message -p '#{session_id}-#{window_id}' | tr -d '$@')"
STATE_FILE="$STATE_DIR/$KEY.pane"

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

cmd="${1:-help}"
shift || true

case "$cmd" in
  start)
    # start [initial-prompt] — create pane + launch codex; idempotent. Prints pane id.
    if id="$(get_pane)"; then echo "$id"; exit 0; fi
    if [ $# -gt 0 ] && [ -n "${1:-}" ]; then
      id="$(tmux split-window -h -d -c "$PWD" -P -F '#{pane_id}' "codex $(printf '%q' "$1")")"
    else
      id="$(tmux split-window -h -d -c "$PWD" -P -F '#{pane_id}' "codex")"
    fi
    tmux set-option -p -t "$id" remain-on-exit on
    echo "$id" > "$STATE_FILE"
    for _ in $(seq 1 60); do
      out="$(tmux capture-pane -p -t "$id" 2>/dev/null || true)"
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
    # send "<text>" — bracketed-paste into the composer, then submit with Enter.
    id="$(get_pane)" || die "no codex pane; run start first"
    text="${1:?text required}"
    tmux load-buffer -b lazycodex - <<< "$text"
    tmux paste-buffer -p -b lazycodex -t "$id"
    sleep 0.5
    tmux send-keys -t "$id" Enter
    ;;

  peek)
    # peek [lines] — show the last N lines of the codex pane (default 60).
    id="$(get_pane)" || die "no codex pane"
    tmux capture-pane -p -t "$id" -S "-${1:-60}"
    ;;

  status)
    # status — BUSY (codex is working) | IDLE (composer waiting) | NO_PANE
    id="$(get_pane)" || { echo "NO_PANE"; exit 0; }
    out="$(tmux capture-pane -p -t "$id" 2>/dev/null || true)"
    if echo "$out" | grep -qiE 'esc to interrupt'; then echo "BUSY"; else echo "IDLE"; fi
    ;;

  wait)
    # wait "<regex>" [timeout] — block until regex appears in CODEX OUTPUT (default 570s).
    # Lines starting with '›' (echoed user messages / composer) are excluded, so a
    # done-token contained in the dispatched prompt does not self-match.
    # Exit 0 + tail on match, exit 3 on timeout.
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
    id="$(get_pane)" || die "no codex pane"
    timeout="${1:-570}"
    interval=5
    elapsed=0
    idle_count=0
    while [ "$elapsed" -lt "$timeout" ]; do
      out="$(tmux capture-pane -p -t "$id" 2>/dev/null || true)"
      if echo "$out" | grep -qiE 'esc to interrupt'; then
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
    id="$(get_pane)" || die "no codex pane"
    tmux send-keys -t "$id" "$@"
    ;;

  stop)
    # stop — interrupt codex and kill the pane.
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
  start [prompt]            create pane + launch codex (idempotent); prints pane id.
                            optional prompt is submitted on launch.
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
