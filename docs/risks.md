# 风险与限制

最后核对：2026-10-27 07:56（Asia/Shanghai）

## 统计口径

- 当前菜单栏口径是**三个 WorkBuddy 账号合计**；不要给它加单个账号前缀，也不要按账号拆分显示。
- 仅扫 `~/.workbuddy`（CN）；国际版 `~/.workbuddy-ai`、CodeBuddy CLI、CodeBuddy IDE 不计入。切国际版时标题会偏小/为 0。
- 代码里保留了按 `/api/sessions/account` 的 `sessionIds` 过滤能力（单账号口径），但当前未启用；启用前先问用户。
- 本地合计应与 `/api/token-stats` 的 workbuddy 今日 total 一致；不一致时先查日志扫描/去重，不要直接改用接口值糊弄。

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
