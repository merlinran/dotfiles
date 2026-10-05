#!/usr/bin/env bash
#
# Install the llama-server launchd agent from llama/llama-server.plist.
#
# Run directly, or via script/install (which runs every */install.sh).

set -e

DOTFILES_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

LABEL="local.llama-server"
STATE_DIR="$HOME/.local/state/llama"
SLOT_DIR="$STATE_DIR/slots"
LIBEXEC_DIR="$HOME/.local/share/llama"
AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST="$AGENTS_DIR/$LABEL.plist"
MODEL_DIR="$HOME/models/Qwen3.6-35B-A3B-MTP"
MODEL_FILE="Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf"
MODEL="$MODEL_DIR/$MODEL_FILE"

mkdir -p "$STATE_DIR" "$SLOT_DIR" "$LIBEXEC_DIR" "$AGENTS_DIR"

if [ ! -f "$MODEL" ]; then
  echo "llama: model missing, skipping agent install"
  echo "llama:   $MODEL"
  echo "llama: fetch it with:"
  echo ""
  echo "  $DOTFILES_ROOT/llama/fetch-model.sh"
  echo ""
  echo "llama: then re-run: $DOTFILES_ROOT/llama/install.sh"
  exit 0
fi

sed -e "s|__HOME__|$HOME|g" -e "s|__MODEL__|$MODEL|g" \
  "$DOTFILES_ROOT/llama/llama-server.plist" > "$PLIST"
echo "llama: wrote $PLIST"

# slot-state.sh does on-demand save/restore (llama-save/llama-restore, and
# llama-stop/llama-start); install it outside the repo so the shell functions
# do not depend on the repo path.
install -m 0755 "$DOTFILES_ROOT/llama/slot-state.sh" "$LIBEXEC_DIR/slot-state.sh"
echo "llama: installed $LIBEXEC_DIR/slot-state.sh"
echo "llama: slot state dir $SLOT_DIR"

# Reload so edits to the template take effect.
#
# bootout is asynchronous: bootstrap immediately afterwards can fail with
# "Bootstrap failed: 5: Input/output error" while the old job is still tearing
# down, leaving the OLD config running. Wait for the job to disappear, then
# bootstrap with a bounded retry.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
for _ in $(seq 1 40); do
  launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break
  sleep 0.5
done

attempt=1
until launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; do
  if [ "$attempt" -ge 5 ]; then
    echo "llama: bootstrap failed after $attempt attempts" >&2
    exit 1
  fi
  sleep 1
  attempt=$((attempt + 1))
done
echo "llama: bootstrapped $LABEL (loading model; check 'llama-status')"
