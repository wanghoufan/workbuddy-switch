#!/bin/zsh
# 安装/卸载菜单栏小工具的登录自启（LaunchAgent）。
# 按 ~/.agents/rules/background-services.md：实施前须已在后台服务登记表登记并获用户授权。
#
# 可用环境变量（默认值是示例，落地必须改）：
#   LABEL      LaunchAgent 标签，默认 com.local.example.metric
#   APP_PATH   .app 路径，默认 $HOME/Applications/My Metric.app
#   BIN_NAME   可执行文件名，默认 MyMetric
#   LOG_PATH   日志路径，默认 $HOME/Library/Logs/example-metric-menu.log
#
# 用法：
#   LABEL=com.local.mymetric APP_PATH="$HOME/Applications/My Metric.app" zsh template_install_agent.sh
#   ... --status
#   ... --uninstall
set -eu

LABEL="${LABEL:-com.local.example.metric}"
APP_PATH="${APP_PATH:-$HOME/Applications/My Metric.app}"
BIN_NAME="${BIN_NAME:-MyMetric}"
LOG_PATH="${LOG_PATH:-$HOME/Library/Logs/example-metric-menu.log}"

ROOT="${0:A:h}"
EXECUTABLE="$APP_PATH/Contents/MacOS/$BIN_NAME"
PLIST_TEMPLATE="$ROOT/template_launch_agent.plist"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

usage() {
    cat <<'TEXT'
用法：
  zsh template_install_agent.sh             安装并立即启动（登录自启、崩溃自动重启）
  zsh template_install_agent.sh --uninstall 停用并移除 LaunchAgent（保留 .app）
  zsh template_install_agent.sh --status    查看当前状态
安装前请确认：backend-services SOP 已读、后台服务登记表已登记、用户已授权。
TEXT
}

status() {
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
        launchctl print "$DOMAIN/$LABEL" | grep -E "state =|pid =|program =|last exit|runs =" || true
    else
        echo "未加载：$LABEL"
    fi
    pgrep -fl "$BIN_NAME" || echo "（无运行中的 $BIN_NAME 进程）"
}

uninstall() {
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$AGENT"
    echo "已停用并移除 LaunchAgent：$LABEL"
    echo "菜单栏进程若仍在运行，可从菜单「退出」结束；.app 保留在 $APP_PATH"
}

install_agent() {
    if [ ! -x "$EXECUTABLE" ]; then
        echo "未找到 $EXECUTABLE，先构建：BUNDLE_ID=$LABEL BIN_NAME=$BIN_NAME APP_NAME=\"${APP_PATH:t:r}\" sh template_build_app.sh" >&2
        exit 1
    fi

    mkdir -p "$HOME/Library/LaunchAgents" "$(dirname "$LOG_PATH")"
    sed -e "s|__LABEL__|$LABEL|g" \
        -e "s|__APP_EXECUTABLE__|$EXECUTABLE|g" \
        -e "s|__LOG_PATH__|$LOG_PATH|g" \
        "$PLIST_TEMPLATE" > "$AGENT"

    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    launchctl bootstrap "$DOMAIN" "$AGENT"
    launchctl enable "$DOMAIN/$LABEL"
    launchctl kickstart -k "$DOMAIN/$LABEL"

    sleep 1
    status
    echo "日志：$LOG_PATH"
}

case "${1:-install}" in
    --uninstall) uninstall ;;
    --status) status ;;
    -h|--help) usage ;;
    *) install_agent ;;
esac
