#!/bin/zsh
set -u

ROOT="${0:A:h:h}"
LOG_DIR="$ROOT/.logs"
SERVICE_LABEL="com.workbuddy-switch.server"
URL="http://127.0.0.1:57890"

mkdir -p "$LOG_DIR"
log() { print -r -- "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_DIR/watchdog.log"; }

page="$(/usr/bin/curl --noproxy '*' --max-time 5 --fail --silent "$URL/" 2>/dev/null || true)"
api_ok=$(/usr/bin/curl --noproxy '*' --max-time 5 --fail --silent -o /dev/null "$URL/api/status" 2>/dev/null; echo $?)
asset="$(print -r -- "$page" | /usr/bin/sed -n 's/.*src="\([^"]*\.js\)".*/\1/p' | /usr/bin/head -1)"
asset_ok=1
if [[ -n "$asset" ]]; then
  /usr/bin/curl --noproxy '*' --max-time 5 --fail --silent -o /dev/null "$URL$asset" 2>/dev/null
  asset_ok=$?
fi

if [[ "$page" == *"workbuddy-switch"* && "$api_ok" -eq 0 && "$asset_ok" -eq 0 ]]; then
  exit 0
fi

log "健康检查失败 page=$( [[ "$page" == *"workbuddy-switch"* ]] && echo ok || echo fail ) api=$api_ok asset=$asset_ok；重启 $SERVICE_LABEL"
/bin/launchctl kickstart -k "gui/$(/usr/bin/id -u)/$SERVICE_LABEL" >> "$LOG_DIR/watchdog.log" 2>&1 || log "kickstart 失败"
