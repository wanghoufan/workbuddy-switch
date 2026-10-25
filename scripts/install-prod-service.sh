#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
AGENT_DIR="$HOME/Library/LaunchAgents"
UID_VALUE="$(/usr/bin/id -u)"
NODE_BIN="$(command -v node || true)"
if [[ -z "$NODE_BIN" || ! -x "$NODE_BIN" ]]; then
  print -u2 "找不到 node，请先安装 Node.js。"
  exit 1
fi
NODE_DIR="${NODE_BIN:h}"

mkdir -p "$AGENT_DIR" "$ROOT/.logs"
for label in com.workbuddy-switch.server com.workbuddy-switch.watchdog; do
  /bin/launchctl bootout "gui/$UID_VALUE/$label" 2>/dev/null || true
done

/usr/bin/sed \
  -e "s|__PROJECT_ROOT__|$ROOT|g" \
  -e "s|__NODE_DIR__|$NODE_DIR|g" \
  "$ROOT/launchd/com.workbuddy-switch.server.plist.template" \
  > "$AGENT_DIR/com.workbuddy-switch.server.plist"
/usr/bin/sed \
  -e "s|__PROJECT_ROOT__|$ROOT|g" \
  "$ROOT/launchd/com.workbuddy-switch.watchdog.plist.template" \
  > "$AGENT_DIR/com.workbuddy-switch.watchdog.plist"

/usr/bin/plutil -lint "$AGENT_DIR/com.workbuddy-switch.server.plist"
/usr/bin/plutil -lint "$AGENT_DIR/com.workbuddy-switch.watchdog.plist"
/bin/launchctl bootstrap "gui/$UID_VALUE" "$AGENT_DIR/com.workbuddy-switch.server.plist"
/bin/launchctl bootstrap "gui/$UID_VALUE" "$AGENT_DIR/com.workbuddy-switch.watchdog.plist"
/bin/launchctl kickstart -k "gui/$UID_VALUE/com.workbuddy-switch.server"
/bin/launchctl kickstart -k "gui/$UID_VALUE/com.workbuddy-switch.watchdog"
print "生产服务与 watchdog 已安装。"
print "登录后自动启动；访问：http://127.0.0.1:57890/"
