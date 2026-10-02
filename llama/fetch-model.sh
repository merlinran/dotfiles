#!/usr/bin/env bash
#
# Fetch the GGUF used by llama-server.
#
# Uses aria2 with 8 parallel connections, and deliberately bypasses any
# configured proxy. ModelScope is a domestic .cn CDN: it is reachable directly
# and a proxy throttles it badly. Measured from this machine:
#
#   modelscope, 8 connections, direct   ~21-28 MB/s
#   modelscope, 1 connection, direct     ~4.3 MB/s
#   modelscope, 1 connection, via proxy  ~1.6 MB/s
#   hf-mirror, 8 connections             ~2 MB/s
#
# The modelscope CLI's --max-workers does not produce this throughput; aria2
# range requests do. Resumable: re-run to continue after an interruption.

set -e

MODEL_DIR="${MODEL_DIR:-$HOME/models/Qwen3.6-35B-A3B-MTP}"
MODEL_FILE="${MODEL_FILE:-Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf}"
REPO="${REPO:-unsloth/Qwen3.6-35B-A3B-MTP-GGUF}"
MIRROR="${MIRROR:-https://www.modelscope.cn/models}"
URL="$MIRROR/$REPO/resolve/master/$MODEL_FILE"

mkdir -p "$MODEL_DIR"

# A completed file has no .aria2 control file alongside it.
if [ -f "$MODEL_DIR/$MODEL_FILE" ] && [ ! -f "$MODEL_DIR/$MODEL_FILE.aria2" ]; then
  echo "fetch-model: already present, nothing to do"
  echo "fetch-model:   $MODEL_DIR/$MODEL_FILE"
  exit 0
fi

echo "fetch-model: $MODEL_FILE"
echo "fetch-model:   from $URL"
echo "fetch-model:   to   $MODEL_DIR"

env -u all_proxy -u ALL_PROXY -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY \
  aria2c -x 8 -s 8 -k 32M -c \
    --file-allocation=none \
    --summary-interval=15 \
    --console-log-level=warn \
    --auto-file-renaming=false \
    -d "$MODEL_DIR" -o "$MODEL_FILE" "$URL"

echo "fetch-model: done"
