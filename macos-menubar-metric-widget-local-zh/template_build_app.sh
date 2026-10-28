#!/bin/sh
# 编译并组装 macOS 菜单栏小工具的 .app（AppKit 版本）。
#
# 可用环境变量（都有默认值，落地时至少改 BUNDLE_ID）：
#   APP_NAME   应用显示名           默认 My Metric
#   BUNDLE_ID  Bundle ID           默认 com.local.example.metric
#   BIN_NAME   可执行文件名         默认 MyMetric
#   APP_DIR    安装目录             默认 $HOME/Applications
#   SOURCE     源码路径             默认 本脚本同目录 template_menu_bar_app.swift
#
# 用法：
#   BUNDLE_ID=com.local.mymetric BIN_NAME=MyMetric \
#   APP_NAME="My Metric" sh template_build_app.sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
APP_NAME="${APP_NAME:-My Metric}"
BUNDLE_ID="${BUNDLE_ID:-com.local.example.metric}"
BIN_NAME="${BIN_NAME:-MyMetric}"
APP_DIR="${APP_DIR:-$HOME/Applications}"
SOURCE="${SOURCE:-$ROOT/template_menu_bar_app.swift}"

APP="$APP_DIR/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"

mkdir -p "$MACOS" "$CONTENTS/Resources"

swiftc -parse-as-library -swift-version 5 -O "$SOURCE" -o "$MACOS/$BIN_NAME"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$BIN_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

/usr/bin/codesign --force --sign - "$APP" >/dev/null

printf 'Built: %s\n' "$APP"
