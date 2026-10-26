# 风险与限制

最后核对：2026-10-26 23:36（Asia/Shanghai）

## 账号归属

- 当前账号用量依赖 `/api/sessions/account` 的会话列表；若接口缺会话（新建/极旧/异常），本次统计会少算。
- 仅扫 `~/.workbuddy`（CN）；国际版 `~/.workbuddy-ai`、CodeBuddy CLI、CodeBuddy IDE 不计入。用户切国际版时标题可能为 0/偏小。
- WorkBuddy 日志目录共享；不要退回 `/api/token-stats` 的 workbuddy total 当单账号用量（三账号合计，约 98% 缓存）。

## 性能

- 每次刷新扫今天修改的日志（约 35 文件 / 36MB），实测 CPU 1–2s/次；默认 60s。日志量增长或调 30s 会放大。
- `--print-once` 仍会调用 `/api/token-stats`（实测 5s+），只用于回归。

## 权限 / 验证

- 终端无辅助功能/录屏权限，无法自动打开菜单或截图；标题只能靠 `--print-once` 同代码路径核对。
- 菜单栏状态项可能被系统排到屏幕外（菜单栏满、Hidden Bar）；排查见 `agent.md`。

## 服务端

- 本机无 Rust 工具链，不能改 `bin/wb-switch-darwin-arm64`；服务端 per-account token 拆分需另装工具链/发布新版。
- 不要随意重启 Node 代理/生产服务；改动前先确认 `com.workbuddy-switch.server` 状态。

## 数据 / 隐私

- `/api/accounts` 响应含 access/refresh token；菜单栏只解码 id/uid/nickname，不打印/落盘。
- 日志扫描只读 usage 计数，不读正文/参数；不要扩展为返回正文。
