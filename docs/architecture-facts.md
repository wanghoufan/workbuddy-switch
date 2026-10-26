# 架构与构建事实

最后核对：2026-10-26 23:36（Asia/Shanghai）

## 服务拓扑

- 生产服务：Node 代理 `scripts/serve-prod-webui.mjs`（launchd `com.workbuddy-switch.server`），监听 `127.0.0.1:57890`，转发到 `bin/wb-switch-darwin-arm64 serve --port 57891`。
- `bin/wb-switch-darwin-arm64` 是预编译 Rust 二进制；本机无 `cargo`/`rustc`，不能本地重编服务端。
- Web UI 与菜单栏共用同机回环接口，不另起端口。

## 菜单栏数据流

1. `GET /api/accounts` → `current`（账号 id 或 uid）→ 匹配 `accounts[]`，取 id/uid/nickname；nickname 前三位作为标题中段。
2. `GET /api/sessions/account?accountId=<id>&client=workbuddy` → 当前账号会话 id 集合。
3. 扫 `~/.workbuddy/projects/**/*.jsonl`，只处理 mtime ≥ 本机今日 00:00 的文件；文件 stem 或向上祖先目录命中会话 id 才计入（子代理日志归父会话）。
4. 行内含 `"usage"` 才解析；usage 优先级 `message.usage` > `providerData.usage` > 顶层 `usage`；字段别名含 `input_tokens/inputTokens/prompt_tokens`、`output_tokens/outputTokens/completion_tokens`、缓存读取别名、cache_write 别名（含 `rawUsage` 兜底）。
5. 仅保留 timestamp 落在本地今天（`yyyy-MM-dd`）的记录；按 `(timestamp,input,output,cacheRead,cacheWrite,model)` 去重；总量 = `input + output + cacheWrite`（input 含缓存读取）。
6. 标题：`work-<prefix>-<compact total>`；紧凑模式去掉 `work-`；账号/接口失败时退回 `work-<值>` 或显示错误。

## 当前运行状态

- App：`~/Applications/WorkBuddy Token.app`，Bundle ID `com.local.wb-token.menubar`，`LSUIElement`。
- LaunchAgent label `com.local.wb-token.menubar`；日志 `~/Library/Logs/workbuddy-switch-token-menu.log`；单实例锁 `~/Library/Application Support/com.local.wb-token.menubar/instance.lock`。
- 2026-10-26 23:35 实测：标题 `work-<账号前缀>-58.4M`（本地统计约 58M）；`/api/token-stats` workbuddy total 约 448M（三账号合计，约 98% 缓存）。
- 菜单项：标题落款、刷新间隔、提醒阈值、立即刷新、打开主界面、紧凑标签、更新于、退出。
- 阈值候选 `[0,30,50,90,120,150,180,300,500]`，当前存储 180。

## 构建与回归

- `sh menubar/build.sh` → Swift AppKit 编译 + ad-hoc codesign。
- `sh menubar/test.sh` → 隔离夹具（token-stats、accounts、sessions、本地日志）；两条 PASS 才算过。
- `WB_TOKEN_API` 覆盖接口地址（夹具用）；`WB_WORKBUDDY_ROOT` 覆盖日志根（夹具用）。
- `--print-once` 输出 API 汇总、本地当前账号统计、`title`、阈值候选，供回归/对数。

## 服务端统计口径

- `/api/token-stats`：`workbuddy` 源按共享日志目录汇总，无账号维度；`total = input + output + cacheWrite`，input 含 cacheRead。
- `days=1` 未被识别（range 仅 7/30/90 生效），实际返回全量 daily；菜单栏旧代码只取今天 key。
- 官方 per-account 数据只有积分（`/api/credits/stats`），没有 token。
