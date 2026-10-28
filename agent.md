# 踩坑与排查（agent.md）

最后核对：2026-10-27 07:56（Asia/Shanghai）

## 菜单栏

- 不要用 SwiftUI `MenuBarExtra`：本机 macOS 26 实测启动即退出/被隐藏即退出；用 AppKit `NSStatusItem`。
- 状态项被隐藏/排到屏幕外：先看进程，再查 `CGWindowListCopyWindowInfo` 的 `onscreen/bounds`；菜单栏满或 Hidden Bar 会把它挤出去，腾图标或换 Bundle ID。
- 改 Bundle ID 才能救“进程在但无状态项窗口”的坏记录；旧 plist/defaults 要清。
- `statusItem.menu` 与按钮 action 不要同时想当然：要么菜单，要么自定义点击；混用要处理右键/⌃点击。
- 标题颜色必须用 `attributedTitle`；只改 `title` 不会变红。

## 统计口径

- 当前菜单栏口径 = 三个 WorkBuddy 账号今天合计，标题 `work-总额度-<M>`；不要再加 `199/133/166` 之类账号前缀。
- 数据来源是 `~/.workbuddy/projects/**/*.jsonl` 今日文件，按 usage 记录求和；子代理日志归父会话，复制/分叉会话按指纹去重。
- 单账号口径仍可用 `sessionIds` 过滤（`/api/sessions/account` 拿会话 id），但当前未启用；切换前先问用户。
- `/api/token-stats` 的 `workbuddy.total` 也是三账号合计，且 input 含 cacheRead；历史大用量日可到 400M+，主要是缓存。
- `days=1` 服务端不识别（range 只认 7/30/90），旧代码拿全量 daily 只取今天。
- 日志行只有含 `"usage"` 才解析；usage 优先级 `message.usage` > `providerData.usage` > 顶层 `usage`；cache 字段有多个别名。
- 阈值/告警按当前口径算；口径或标签变化后要清旧的 `lastAlertKey`，否则当天可能不再提醒。

## 构建 / 测试

- `sh menubar/build.sh` 后必须 `sh menubar/test.sh`；夹具用 `WB_TOKEN_API` + `WB_WORKBUDDY_ROOT` 隔离。
- `test.sh` 曾因 `$CODE，` 在旧 bash（`set -u`）被误当变量名中途退出；用 `${CODE}`。
- `--print-once` 同时调 API 和本地扫描；API 慢（5s+）时不要误判为扫描慢。
- 菜单栏刷新默认 60s；30s 会放大日志扫描 CPU。

## 验证限制

- 终端无辅助功能/录屏权限，无法自动点菜单/截图；用 `--print-once` 验证标题字符串，再让用户目视确认。
