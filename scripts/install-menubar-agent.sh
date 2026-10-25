#!/bin/zsh
# 安装/卸载 WorkBuddy Token 菜单栏程序的登录自启（LaunchAgent）。
# 按 ~/.agents/rules/background-services.md：实施前须已在后台服务登记表登记并获用户授权。
set -eu

LABEL="com.local.wb-token.menubar"
ROOT="${0:A:h:h}"
APP="$HOME/Applications/WorkBuddy Token.app"
EXECUTABLE="$APP/Contents/MacOS/WorkBuddyToken"
PLIST_TEMPLATE="$ROOT/menubar/$LABEL.plist.template"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/workbuddy-switch-token-menu.log"
DOMAIN="gui/$(id -u)"

usage() {
    cat <<'TEXT'
用法：
  zsh scripts/install-menubar-agent.sh            安装并立即启动（登录自启、崩溃自动重启）
  zsh scripts/install-menubar-agent.sh --uninstall 停用并移除 LaunchAgent（保留 .app）
  zsh scripts/install-menubar-agent.sh --status    查看当前状态
TEXT
}

status() {
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
        launchctl print "$DOMAIN/$LABEL" | grep -E "state =|pid =|program =|last exit" || true
    else
        echo "未加载：$LABEL"
    fi
    pgrep -fl "WorkBuddyToken" || echo "（无运行中的 WorkBuddyToken 进程）"
}

uninstall() {
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$AGENT"
    echo "已停用并移除 LaunchAgent：$LABEL"
    echo "菜单栏进程若仍在运行，可从菜单「退出」结束；.app 保留在 $APP"
}

install_agent() {
    if [ ! -x "$EXECUTABLE" ]; then
        echo "未找到 $EXECUTABLE，先构建…"
        sh "$ROOT/menubar/build.sh"
    fi

    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
    sed -e "s|__APP_EXECUTABLE__|$EXECUTABLE|g" -e "s|__LOG_PATH__|$LOG|g" \
        "$PLIST_TEMPLATE" > "$AGENT"

    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    launchctl bootstrap "$DOMAIN" "$AGENT"
    launchctl enable "$DOMAIN/$LABEL"
    launchctl kickstart -k "$DOMAIN/$LABEL"

    sleep 1
    status
    echo "日志：$LOG"
}

case "${1:-install}" in
    --uninstall) uninstall ;;
    --status) status ;;
    -h|--help) usage ;;
    *) install_agent ;;
esac
