# Local llama.cpp inference server. See llama/README.md.
#
# Sourced automatically by ~/.zshrc (the dotfiles-wide `**/*.zsh` glob).

export LLAMA_HOST="127.0.0.1"
export LLAMA_PORT="8080"
export LLAMA_BASE_URL="http://${LLAMA_HOST}:${LLAMA_PORT}"
export LLAMA_MODEL_ID="qwen3.6-35b-a3b"
export LLAMA_MODELS_DIR="$HOME/models"
export LLAMA_STATE_DIR="$HOME/.local/state/llama"

export LLAMA_SERVICE_LABEL="local.llama-server"
export LLAMA_SERVICE_PLIST="$HOME/Library/LaunchAgents/${LLAMA_SERVICE_LABEL}.plist"

_llama_domain() { print -r -- "gui/$(id -u)"; }

_llama_pid() { pgrep -f "llama-server.*--port ${LLAMA_PORT}" | head -1; }

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

  # Loading a 27GB model off disk takes a while; poll rather than guess.
  printf 'llama-start: loading %s ' "$LLAMA_MODEL_ID"
  local i
  for i in {1..180}; do
    if curl -sf --max-time 2 "$LLAMA_BASE_URL/health" >/dev/null 2>&1; then
      print " ready"
      return 0
    fi
    printf '.'
    sleep 1
  done
  print ""
  print -u2 "llama-start: timed out after 180s; check 'llama-logs'"
  return 1
}

# Fully unloads the agent (not just kill) so KeepAlive cannot restart it and
# the ~27GB is actually returned to the system.
llama-stop() {
  if launchctl bootout "$(_llama_domain)/$LLAMA_SERVICE_LABEL" 2>/dev/null; then
    print "llama-stop: unloaded, memory freed"
  else
    print "llama-stop: not running"
  fi
}

llama-restart() {
  if launchctl kickstart -k "$(_llama_domain)/$LLAMA_SERVICE_LABEL" 2>/dev/null; then
    printf 'llama-restart: reloading '
    local i
    for i in {1..180}; do
      if curl -sf --max-time 2 "$LLAMA_BASE_URL/health" >/dev/null 2>&1; then
        print " ready"
        return 0
      fi
      printf '.'
      sleep 1
    done
    print ""
    print -u2 "llama-restart: timed out; check 'llama-logs'"
    return 1
  fi
  llama-stop
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
}

llama-logs()  { tail -n 200 -f "$LLAMA_STATE_DIR/server.err.log"; }
llama-ctx()   { curl -sf --max-time 3 "$LLAMA_BASE_URL/props" 2>/dev/null | python3 -m json.tool 2>/dev/null; }
