# WorkBuddy Token 菜单栏

macOS 菜单栏常驻显示**当前 WorkBuddy 账号**的**今日** Token 用量，标题形如
`work-<账号前缀>-57.5M`。数据来自本机服务的 `/api/accounts`、`/api/sessions/account`
以及本机 WorkBuddy 日志；不另起端口、不写业务数据。

## 构建

```bash
sh menubar/build.sh
```

产物：`~/Applications/WorkBuddy Token.app`（无 Dock 图标，`LSUIElement`）。

## 回归（隔离夹具，不读真实账号数据）

```bash
sh menubar/test.sh
```

覆盖：接口三产品总量与缓存命中率、当前账号前缀、本地日志统计（子代理归属、排除其他账号）、标题格式、提醒阈值候选；后端不可达时非零退出。

## 登录自启（LaunchAgent）

```bash
zsh scripts/install-menubar-agent.sh            # 安装并启动；登录自启、崩溃自动重启
zsh scripts/install-menubar-agent.sh --status   # 状态
zsh scripts/install-menubar-agent.sh --uninstall# 停用并移除 plist（保留 .app）
```

- Label／plist 文件名／Bundle ID：`com.local.wb-token.menubar`
- 日志：`~/Library/Logs/workbuddy-switch-token-menu.log`
- 单实例锁：`~/Library/Application Support/com.local.wb-token.menubar/instance.lock`（按 Bundle ID 派生，多个菜单栏小工具可共存）

## 菜单

| 项 | 说明 |
|---|---|
| 今日 WorkBuddy（账号 …） | 标题同一数字的落款 |
| 刷新间隔 | 30 秒／1 分钟（默认）／5 分钟／10 分钟／手动刷新 |
| 提醒阈值 | 关闭／30M／50M／90M（默认）／120M／150M／180M／300M／500M；达到后标题变红＋右上角卡片提醒 |
| 立即刷新 / 打开主界面 | 手动刷新；打开 `http://127.0.0.1:57890/` |
| 紧凑标签 | 省略 `work-` 前缀，只显示 `<账号前缀>-57.5M` |
| 更新于 | 最近一次刷新时间 |
| 退出 | 结束进程（LaunchAgent 的 `KeepAlive` 仅在异常退出时拉起，正常退出不复活） |

标题格式 `work-<当前账号手机号前三位>-<今日用量>`，例如 `work-<账号前缀>-57.5M`。
刷新间隔、阈值、紧凑开关会写入 UserDefaults，重启后保持。

## 数字口径

- 标题中间三位 = **当前 WorkBuddy 登录账号**的手机号前三位，
  从本机服务 `/api/accounts` 的 `current` 匹配账号后取 `nickname` 前三位。
  接口不可用时标题退回 `work-<用量>`，不会卡住刷新。
- 标题数字 = **当前账号今天**的 WorkBuddy Token 总量：先用 `/api/sessions/account`
  拿到该账号的会话 id，再扫本机 `~/.workbuddy/projects/**/*.jsonl`，只统计这些会话
  （子代理日志向上归属到父会话）中**今天**的 usage 记录。
- 口径与服务端一致：`input` 已含缓存读取，再追加 output 与 cache write；
  复制/分叉会话按 `(时间戳, input, output, cacheRead, cacheWrite, model)` 去重，避免重复计数。
- 不再使用 `/api/token-stats` 的 `workbuddy` 汇总数（那是三个账号共同日志目录的合计，
  会显示成 400M+）；菜单栏只显示当前账号这一项。WorkBuddy 国际版日志不在此统计内。

## 阈值提醒

- 阈值为**今日 Token 百万数**（`alertThresholdMillion`，0＝关闭），默认 **90M**。
  当前账号今天约 57M，120M / 180M 阈值都在正常范围；300M / 500M 保留给用量大的日子。
- 达到阈值：菜单栏标题变红；同时在鼠标所在屏幕的右上角弹一张通知卡片（无边框 `NSPanel`，不抢焦点），
  **20 秒自动淡出**，点击可立即关闭。
- 同一天／同一账号／同一阈值只提醒一次（`lastAlertKey`）；跨天、改阈值、切账号会重新提醒一次。
- 想立刻验证：`defaults write com.local.wb-token.menubar alertThresholdMillion -float 1` 后
  `launchctl kickstart -k gui/$(id -u)/com.local.wb-token.menubar`，验证完把阈值写回 90。

## 排障（都是实测踩过的坑）

1. **菜单栏里看不到，但进程在跑**：先看菜单栏是否已满。状态项窗口被排到时钟右侧屏幕外时，
   `CGWindowListCopyWindowInfo` 里它的 `onscreen=false`。本机装有 Hidden Bar，隐藏区窗口 X 为负值；
   腾出约 100 pt（隐藏一个不用的图标）后会自动回到可见区。
2. **进程在跑但没有状态项窗口**：多为该 Bundle ID 的历史状态被写坏（反复强杀、隐藏记录残留）。
   换一个干净的 Bundle ID 重新构建即可（本次从 `com.local.workbuddy-switch.token-menu`
   换到 `com.local.wb-token.menubar` 后恢复）。旧 ID 的 plist 与 defaults 已清理。
3. **不要用 SwiftUI `MenuBarExtra`**：本机（macOS 26）实测三点——带
   `@NSApplicationDelegateAdaptor` 启动即退出；自定义 label（HStack/Image）或 `.menu` 自定义菜单内容
   同样启动即退出；状态项被系统判为隐藏时进程直接结束。当前实现用 AppKit `NSStatusItem`。
4. **刷新成本**：每分钟会扫一遍今天修改过的 WorkBuddy 日志（约 35 个文件 / 36MB，
   实测约 1～2 s CPU），故默认 60 秒；不要在没有缓存的情况下把间隔调到 30 秒以下。
