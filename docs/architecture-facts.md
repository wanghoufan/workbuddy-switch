# 架构与构建事实

最后核对：2026-10-27 07:56（Asia/Shanghai）

## 服务拓扑

- 生产服务：Node 代理 `scripts/serve-prod-webui.mjs`（launchd `com.workbuddy-switch.server`），监听 `127.0.0.1:57890`，转发到 `bin/wb-switch-darwin-arm64 serve --port 57891`。
- `bin/wb-switch-darwin-arm64` 是预编译 Rust 二进制；本机无 `cargo`/`rustc`，不能本地重编服务端。
- Web UI 与菜单栏共用同机回环接口，不另起端口。

## 菜单栏数据流

1. 扫 `~/.workbuddy/projects/**/*.jsonl`，只处理 mtime ≥ 本机今日 00:00 的文件；子代理日志归父会话。
2. 行内含 `"usage"` 才解析；usage 优先级 `message.usage` > `providerData.usage` > 顶层 `usage`；字段别名含 `input_tokens/inputTokens/prompt_tokens`、`output_tokens/outputTokens/completion_tokens`、缓存读取别名、cache_write 别名（含 `rawUsage` 兜底）。
3. 仅保留 timestamp 落在本地今天（`yyyy-MM-dd`）的记录；按 `(timestamp,input,output,cacheRead,cacheWrite,model)` 去重；总量 = `input + output + cacheWrite`（input 含缓存读取）。
4. 标题：常规 `work-总额度-<compact total>`；紧凑模式 `work-<整数>m`（如 `work-364m`）；扫描失败时显示错误。
5. 代码保留 `sessionIds` 过滤参数（按 `/api/sessions/account` 归属），当前不传，即统计三个账号合计；以后可随时切回单账号口径。

## 当前运行状态

- App：`~/Applications/WorkBuddy Token.app`，Bundle ID `com.local.wb-token.menubar`，`LSUIElement`。
- LaunchAgent label `com.local.wb-token.menubar`；日志 `~/Library/Logs/workbuddy-switch-token-menu.log`；单实例锁 `~/Library/Application Support/com.local.wb-token.menubar/instance.lock`。
- 2026-10-27 07:50 实测：标题 `work-总额度-6.1M`（本地统计 6,084,517）；`/api/token-stats` workbuddy total 同为 6,084,517（三账号合计，含缓存）。
- 菜单项：标题落款、刷新间隔、提醒阈值、立即刷新、打开主界面、紧凑标签、更新于、退出。
- 阈值候选 `[0,30,50,90,120,150,180,300,500]`，当前存储 180。

## 构建与回归

- `sh menubar/build.sh` → Swift AppKit 编译 + ad-hoc codesign。
- `sh menubar/test.sh` → 隔离夹具（token-stats、accounts、sessions、本地日志）；两条 PASS 才算过。当前 accounts/sessions 夹具仅保留，不再参与标题统计。
- `WB_TOKEN_API` 覆盖接口地址（夹具用）；`WB_WORKBUDDY_ROOT` 覆盖日志根（夹具用）。
- `--print-once` 输出 API 汇总、`scope=workbuddy-all-accounts`、本地合计、`title`、阈值候选，供回归/对数。

## 服务端统计口径

- `/api/token-stats`：`workbuddy` 源按共享日志目录汇总，无账号维度；`total = input + output + cacheWrite`，input 含 cacheRead。
- `days=1` 未被识别（range 仅 7/30/90 生效），实际返回全量 daily；菜单栏旧代码只取今天 key。
- 官方 per-account 数据只有积分（`/api/credits/stats`），没有 token。
