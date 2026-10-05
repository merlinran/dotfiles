# Local llama.cpp inference server. See llama/README.md.
#
# Sourced automatically by ~/.zshrc (the dotfiles-wide `**/*.zsh` glob).

export LLAMA_HOST="127.0.0.1"
export LLAMA_PORT="8080"
export LLAMA_BASE_URL="http://${LLAMA_HOST}:${LLAMA_PORT}"
export LLAMA_MODEL_ID="qwen3.6-35b-a3b"
export LLAMA_MODELS_DIR="$HOME/models"
export LLAMA_STATE_DIR="$HOME/.local/state/llama"
export LLAMA_SLOT_DIR="$LLAMA_STATE_DIR/slots"
export LLAMA_LIBEXEC="$HOME/.local/share/llama"

export LLAMA_SERVICE_LABEL="local.llama-server"
export LLAMA_SERVICE_PLIST="$HOME/Library/LaunchAgents/${LLAMA_SERVICE_LABEL}.plist"

_llama_domain() { print -r -- "gui/$(id -u)"; }

_llama_pid() { pgrep -f "^/opt/homebrew/bin/llama-server .*--port ${LLAMA_PORT}" | head -1; }

# Save/restore live slot KV state by hand (start/stop do it automatically).
_llama_slot_state() {
  if [[ ! -x "$LLAMA_LIBEXEC/slot-state.sh" ]]; then
    print -u2 "llama: $LLAMA_LIBEXEC/slot-state.sh missing (run script/install)"
    return 1
  fi
  LLAMA_BASE_URL="$LLAMA_BASE_URL" LLAMA_SLOT_DIR="$LLAMA_SLOT_DIR" \
    "$LLAMA_LIBEXEC/slot-state.sh" "$@"
}
llama-save() { _llama_slot_state save }
llama-restore() { _llama_slot_state restore }

# Wait for /health. Model load takes a while; poll rather than guess.
_llama_wait_health() {
  local label="$1" i
  printf '%s: loading ' "$label"
  for i in {1..900}; do
    if curl -sf --max-time 2 "$LLAMA_BASE_URL/health" >/dev/null 2>&1; then
      print " ready"
      return 0
    fi
    printf '.'
    sleep 1
  done
  print ""
  print -u2 "$label: timed out waiting for health; check 'llama-logs'"
  return 1
}

llama-start() {
  if [[ ! -f "$LLAMA_SERVICE_PLIST" ]]; then
    print -u2 "llama-start: no plist at $LLAMA_SERVICE_PLIST (run script/install)"
    return 1
  fi
  if [[ -n "$(_llama_pid)" ]]; then
    print "llama-start: already running"
    return 0
  fi

  launchctl bootstrap "$(_llama_domain)" "$LLAMA_SERVICE_PLIST" 2>/dev/null \
    || launchctl kickstart -k "$(_llama_domain)/$LLAMA_SERVICE_LABEL"

  _llama_wait_health "llama-start" || return 1
  # Warm the slots from the last session's saved state. Disk I/O, not prefill.
  # NOTE: currently a no-op on this hybrid model; see the README.
  _llama_slot_state restore >/dev/null 2>&1 || true
}

# Fully unloads the agent (not just kill) so KeepAlive cannot restart it and
# the ~27GB is actually returned to the system.
llama-stop() {
  if ! launchctl print "$(_llama_domain)/$LLAMA_SERVICE_LABEL" >/dev/null 2>&1; then
    print "llama-stop: not running"
    return 0
  fi

  # Save before stopping: the server must still be up to serialize its slots,
  # and there is no time pressure here (unlike on SIGTERM).
  print "llama-stop: saving slot state"
  _llama_slot_state save >/dev/null 2>&1 || true

  launchctl bootout "$(_llama_domain)/$LLAMA_SERVICE_LABEL" 2>/dev/null || true

  printf 'llama-stop: unloading '
  local i
  for i in {1..240}; do
    if [[ -z "$(_llama_pid)" ]]; then
      print " done, memory freed"
      return 0
    fi
    printf '.'
    sleep 1
  done
  print ""
  print -u2 "llama-stop: server still up after 240s; check 'llama-logs'"
  return 1
}

# Stop then start, so llama-stop can save slot state while the server is still
# up (kickstart -k would kill it first, skipping the save).
llama-restart() {
  llama-stop || true
  # bootout is async; wait for the job to disappear before bootstrapping.
  local i
  for i in {1..40}; do
    launchctl print "$(_llama_domain)/$LLAMA_SERVICE_LABEL" >/dev/null 2>&1 || break
    sleep 0.5
  done
  llama-start
}

llama-status() {
  local pid
  pid="$(_llama_pid)"
  if [[ -z "$pid" ]]; then
    print "llama-server: stopped"
    return 1
  fi

  local rss
  rss="$(ps -o rss= -p "$pid" | tr -d ' ')"
  printf 'llama-server: running (pid %s, %s MB resident)\n' "$pid" "$(( rss / 1024 ))"

  if curl -sf --max-time 3 "$LLAMA_BASE_URL/health" >/dev/null 2>&1; then
    print "  health: ok"
  else
    print "  health: still loading or unreachable"
    return 1
  fi

  curl -sf --max-time 3 "$LLAMA_BASE_URL/v1/models" 2>/dev/null \
    | python3 -c 'import json,sys; print("  models:", ", ".join(m["id"] for m in json.load(sys.stdin).get("data", [])))' 2>/dev/null

  local files=("$LLAMA_SLOT_DIR"/slot-*.bin(N))
  if (( $#files )); then
    print "  saved  : ${#files} slot state file(s) in $LLAMA_SLOT_DIR"
  else
    print "  saved  : none"
  fi
}

llama-logs()  { tail -n 200 -f "$LLAMA_STATE_DIR/server.err.log"; }
llama-ctx()   { curl -sf --max-time 3 "$LLAMA_BASE_URL/props" 2>/dev/null | python3 -m json.tool 2>/dev/null; }
