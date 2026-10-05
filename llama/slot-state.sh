#!/usr/bin/env bash
#
# Save or restore llama-server slot KV state on disk.
#
# llama-server keeps each slot's KV in RAM. With long agent contexts that is
# ~9 GB per slot, and a restart loses all of it: every conversation then pays a
# cold prefill (minutes each at 100K), and concurrent cold prefills starve each
# other's decode. Saving slot state to disk and restoring it after a restart
# turns that back into warm turns, trading disk I/O for GPU prefill.
#
# Requires llama-server started with --slot-save-path (set in llama-server.plist).
# See llama/README.md.
#
# Usage: slot-state.sh save|restore
#
#   LLAMA_BASE_URL    server base URL       (default http://127.0.0.1:8080)
#   LLAMA_SLOT_DIR    slot state directory  (default ~/.local/state/llama/slots)
#   LLAMA_SLOT_TIMEOUT per-slot timeout, s  (default 300)
#   LLAMA_SLOT_BUDGET  total save budget, s (default 150; keeps a pathological
#                      slot from blocking llama-stop indefinitely)

set -u

ACTION="${1:-}"
BASE_URL="${LLAMA_BASE_URL:-http://127.0.0.1:8080}"
SLOT_DIR="${LLAMA_SLOT_DIR:-$HOME/.local/state/llama/slots}"
TIMEOUT="${LLAMA_SLOT_TIMEOUT:-300}"
# Bound the whole save so a slot that wedges cannot block llama-stop forever.
BUDGET="${LLAMA_SLOT_BUDGET:-150}"

log() { printf '[slot-state] %s\n' "$*" >&2; }

case "$ACTION" in
  save|restore) ;;
  *) log "usage: slot-state.sh save|restore"; exit 2 ;;
esac

mkdir -p "$SLOT_DIR"

# Slots are saved under their own id; on restore a request is matched to a slot
# by longest-common-prefix, so which agent was in which slot does not matter.
#
# Emits: <id> <is_processing:0|1> <n_prompt_tokens>
slot_info() {
  curl -sf --max-time 10 "$BASE_URL/slots" 2>/dev/null | python3 -c '
import json, sys
for slot in json.load(sys.stdin):
    print(slot["id"], int(bool(slot.get("is_processing"))),
          slot.get("n_prompt_tokens") or 0)
'
}

if [ "$ACTION" = save ]; then
  if ! info="$(slot_info)"; then
    log "cannot reach $BASE_URL/slots"
    exit 1
  fi
  if [ -z "$info" ]; then
    log "no slots reported"
    exit 1
  fi
  # Only idle, non-empty slots are worth saving. A busy slot's save blocks until
  # it finishes, which must never hold up a restart; an empty one is just a
  # header. Busy/empty slots simply start cold next time.
  saved=0
  rc=0
  started=$(date +%s)
  while read -r id busy tokens; do
    [ -n "$id" ] || continue
    if [ "$busy" = 1 ]; then
      log "slot $id busy; skipping"
      continue
    fi
    if [ "${tokens:-0}" -eq 0 ]; then
      log "slot $id empty; skipping"
      continue
    fi
    remaining=$(( BUDGET - ($(date +%s) - started) ))
    if (( remaining <= 0 )); then
      log "save budget (${BUDGET}s) exhausted; skipping remaining slots"
      break
    fi
    slot_timeout=$TIMEOUT
    (( remaining < slot_timeout )) && slot_timeout=$remaining
    if curl -sf --max-time "$slot_timeout" -o /dev/null \
         -X POST "$BASE_URL/slots/$id?action=save" \
         -H 'Content-Type: application/json' \
         -d "{\"filename\": \"slot-$id.bin\"}"; then
      log "saved slot $id ($tokens tokens)"
      saved=$((saved + 1))
    else
      log "slot $id save failed"
      rc=1
    fi
  done <<< "$info"
  log "save complete: $saved saved"
  exit $rc
fi

# restore
found=0
rc=0
for f in "$SLOT_DIR"/slot-*.bin; do
  [ -e "$f" ] || continue
  found=1
  name="$(basename "$f")"
  id="${name#slot-}"
  id="${id%.bin}"
  if curl -sf --max-time "$TIMEOUT" -o /dev/null \
       -X POST "$BASE_URL/slots/$id?action=restore" \
       -H 'Content-Type: application/json' \
       -d "{\"filename\": \"$name\"}"; then
    log "restored slot $id"
  else
    # Stale format (e.g. after a llama.cpp upgrade that changed it), or the
    # slot was already taken. Cold start for that slot; not fatal.
    log "slot $id restore failed; ignoring"
    rc=1
  fi
done

[ "$found" = 1 ] || log "no saved slot state"
exit $rc
