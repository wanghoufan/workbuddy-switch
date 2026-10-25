#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
NODE_BIN="${WB_NODE_BIN:-$(command -v node || true)}"
if [[ -z "$NODE_BIN" || ! -x "$NODE_BIN" ]]; then
  print -u2 "找不到 node，无法启动生产 webui。"
  exit 1
fi
exec "$NODE_BIN" "$SCRIPT_DIR/serve-prod-webui.mjs"
