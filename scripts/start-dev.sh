#!/usr/bin/env bash
# workbuddy-switch 本地开发一键启动
#
# 解决的问题：浏览器跑完整功能需要「前端 Vite(1420) + 后端 wb-switch server(57890)」
# 两个进程，且 dev 前端与后端跨源，必须靠 vite 代理（已落到 vite.config.ts）。
# 手动一个个起容易漏后端、串版本、踩 CORS。这个脚本把全套判断封装好，
# 任何智能体或用户打开本文件夹后一行命令即可全部起好。
#
# 用法:
#   bash scripts/start-dev.sh            # 起一次就跑，脚本自己退出
#   bash scripts/start-dev.sh --watch    # 保活：常驻轮询，端口掉线自动重新拉起
#
# 行为:
#   - 自动读 package.json 的 version 作为后端版本号，避免前后端版本不一致
#   - 端口已在监听则跳过（不会重复起）
#   - 有 cargo 走源码编译；否则用 npm 预编译包（自动安装到 .dev-backend/）
#   - 后端就绪后才退出提示
# 保活:
#   --watch 会让脚本本身常驻（WATCH_INTERVAL 秒，默认 10），每轮调用一次
#   start_backend/start_frontend；这两个函数先探端口、在跑就跳过，所以重复调用安全。
#   日志: .dev-watch.log（保活进程自身）、.dev-frontend.log、.dev-backend.log
# 停止: kill 保活进程（.dev-watch.log 里记了 PID），再 kill 两个端口进程；
#       或手动 lsof -nP -iTCP:1420 -sTCP:LISTEN / -iTCP:57890 后 kill

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FRONTEND_PORT=1420
BACKEND_PORT=57890
WB_VERSION="$(node -p "require('./package.json').version" 2>/dev/null || echo "0.1.37")"

log() { printf '\033[36m[start-dev]\033[0m %s\n' "$*"; }
err() { printf '\033[31m[start-dev]\033[0m %s\n' "$*" >&2; }
# 保活轮询里「在跑就跳过」是常态，每 10s 记一行会把日志刷爆（实测 ~1MB/天），
# 所以 QUIET_SKIP=1 时只静默跳过；真正重新拉起仍然照常打日志。
log_skip() { [ "${QUIET_SKIP:-0}" = "1" ] || log "$*"; }

port_listen() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }
wait_backend() {
  for _ in $(seq 1 30); do
    if curl -s -o /dev/null "http://127.0.0.1:${BACKEND_PORT}/api/status"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

start_backend() {
  if port_listen "$BACKEND_PORT"; then
    log_skip "后端 ${BACKEND_PORT} 已在运行，跳过"
    return
  fi
  log "启动后端 (端口 ${BACKEND_PORT}, 版本 ${WB_VERSION}) ..."
  if command -v cargo >/dev/null 2>&1; then
    log "检测到 cargo，使用源码编译启动"
    nohup cargo run -p wb-switch-server -- serve --no-open >"${ROOT}/.dev-backend.log" 2>&1 &
  else
    local BE_DIR="${ROOT}/.dev-backend"
    mkdir -p "$BE_DIR"
    if [ ! -x "${BE_DIR}/node_modules/workbuddy-switch/bin/workbuddy-switch.js" ]; then
      log "安装 workbuddy-switch@${WB_VERSION} 到 ${BE_DIR} ..."
      (cd "$BE_DIR" && npm install "workbuddy-switch@${WB_VERSION}")
    fi
    nohup node "${BE_DIR}/node_modules/workbuddy-switch/bin/workbuddy-switch.js" serve --no-open >"${ROOT}/.dev-backend.log" 2>&1 &
  fi
}

start_frontend() {
  if port_listen "$FRONTEND_PORT"; then
    log_skip "前端 ${FRONTEND_PORT} 已在运行，跳过"
    return
  fi
  log "启动前端 Vite (端口 ${FRONTEND_PORT}) ..."
  nohup npm run dev >"${ROOT}/.dev-frontend.log" 2>&1 &
}

start_backend
start_frontend

if wait_backend; then
  log "后端已就绪 (http://127.0.0.1:${BACKEND_PORT}/api/status)"
else
  err "后端未在 30s 内就绪，查看 ${ROOT}/.dev-backend.log"
fi
log "完成 → 前端: http://localhost:${FRONTEND_PORT}/   后端: http://127.0.0.1:${BACKEND_PORT}"

if [ "${1:-}" = "--watch" ] || [ "${WATCH:-0}" = "1" ]; then
  WATCH_INTERVAL="${WATCH_INTERVAL:-10}"
  log "保活模式开启 (PID $$，每 ${WATCH_INTERVAL}s 检查一次；停保活: kill $$)"
  QUIET_SKIP=1
  while true; do
    sleep "$WATCH_INTERVAL"
    start_backend
    start_frontend
  done
fi
