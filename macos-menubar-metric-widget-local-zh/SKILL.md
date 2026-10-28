---
name: macos-menubar-metric-widget-local-zh
description: 在本机做一个 macOS 菜单栏常驻小工具，实时显示某个本机服务的指标数字（用量、额度、队列数、在线数等），点开可看明细与切换口径，支持阈值变红＋右上角 20 秒自动消失的提醒，并按中央后台服务规范安装为登录自启。适用于「不想一直开着网页，但想随时看到这个数」的需求；内含 SwiftUI MenuBarExtra 在本机不可用的实测结论、状态项被系统隐藏或写坏时的排障路径，以及可直接改用的 AppKit 参考实现、构建脚本与验收脚本。
metadata:
  version: 1.0.0
  created: 2026-10-26
---

# macOS 菜单栏指标小工具

把「本机某个服务里的一个数」搬到菜单栏常驻显示。典型场景：Token/额度消耗、任务队列长度、在线数、未读数。

本 Skill 沉淀的是一套**已验证可跑通**的做法，包含三个非显然的结论：

1. **不要用 SwiftUI `MenuBarExtra`**（本机 macOS 26 + Swift 6.3 实测有四种「启动即退出/被隐藏就退出」的失败模式，见 §5）。
2. **菜单栏项「进程在跑但看不见」有两种完全不同的病**：窗口存在但被挤出屏幕（菜单栏满），与窗口根本没注册（Bundle ID 的状态记录被写坏）。处理方式相反，必须先分辨（§6）。
3. **通知不要用模态 `NSAlert`**：它会阻塞主线程并抢焦点；用无边框 `NSPanel` 贴右上角、20 秒淡出、点击即关（§4.3）。

## 1. 什么时候用

用：

- 用户说「能不能在菜单栏显示 XX」「常驻显示这个数」「不想开网页看」。
- 这个数由**本机已有服务**提供（HTTP 接口、本地 JSON 文件、命令输出任一）。
- 需要顺带一眼判断「是不是用超了」——阈值变红 + 一次性提醒。

不用：

- 指标在远端、需要登录态或跨网访问 → 这是浏览器/网页的活，不是菜单栏的活。
- 只是想要一个分组快捷入口（打开某网页、跑某命令）→ 用系统「快捷指令」或启动器即可。
- 要做完整界面、图表、多页交互 → 做正经的桌面/网页 App，不要塞进菜单栏。

## 2. 动手前的三个判断

| 判断 | 怎么量 | 结论怎么用 |
|---|---|---|
| 数据从哪来 | 先看服务有没有**只读**接口；能直接读文件就不必加接口 | 优先只读接口，别为小工具去改后端 |
| 刷新有多贵 | `curl -w '%{time_total}'` 连打 2～3 次；同时看返回体积 | 一次调用 >1 秒或 >100 KB，就要定较长的默认间隔，并把这一点写进说明 |
| 显示哪个数 | 让用户说清单位与口径（今日/总计、哪个产品、是否含缓存） | 标题只放**一个**最关键的数；口径切换放进菜单 |

经验值：本机接口一次全量扫描 2～4 秒时，默认 **60 秒**刷新是合适的；30 秒只适合极轻的接口。

## 3. 实现选型

**用 AppKit `NSStatusItem`**。理由不是审美，是这三个坑：

- SwiftUI `MenuBarExtra` 在状态项被系统判为隐藏时会**直接结束进程**；
- 自定义 label（`HStack`/`Image` 组合）会让程序启动即退出；
- `.menu` 风格里放自定义菜单内容同样启动即退出。

AppKit 实现即使被隐藏也活着，菜单栏腾出空间后能自己回到可见区。

骨架（完整可跑版本见 `template_menu_bar_app.swift`）：

```swift
let app = NSApplication.shared
app.setActivationPolicy(.accessory)          // 无 Dock 图标；Info.plist 里也写 LSUIElement
let delegate = AppDelegate()
app.delegate = delegate
withExtendedLifetime(delegate) { app.run() }
```

- 状态项：`NSStatusBar.system.statusItem(withLength: .variableLength)`，`font` 用 `monospacedDigitSystemFont`（数字不跳动）。
- 变色：`button.attributedTitle = NSAttributedString(string:..., attributes: [.foregroundColor: .systemRed])`。**不要**只改 `title` 再指望颜色。
- 单实例：对 `~/Library/Application Support/<Bundle ID>/instance.lock` 做 `flock(LOCK_EX|LOCK_NB)`，第二个实例直接 `exit(0)`。**目录必须按 Bundle ID 派生**，否则两套菜单栏小工具会互相抢锁（本次实战踩到，已修进模板）。
- 刷新：`Timer.scheduledTimer` + `isFetching` 防重入；失败保留上次数值并显示「刷新失败：…」，从未成功过则显示占位符。
- 自检：加一个 `--print-once` 参数，走同一套请求与解析、把结果打成 JSON 到 stdout 后退出，验收和回归都靠它（不必点界面）。

## 4. 五步落地

### 4.1 建程序

把 `template_menu_bar_app.swift` 复制成你的源码，只改标注 `// ADAPT:` 的地方：

1. `TokenAPI.defaultEndpoint`：你的只读接口地址（**只允许 127.0.0.1**）。
2. `TokenStatsResponse` / `DailyUsage`：你的 JSON 结构（字段名对齐；数字用 `Int`，可能为空的用 `?`）。
3. `TokenSnapshot.make`：怎么从响应里挑出「今天」或「当前」那一条。
4. `NumberFormat.compact`：单位格式（`1.2M` / `85%` / `12 个`）。
5. `DisplaySource` / `RefreshInterval`：口径与刷新间隔候选。
6. 菜单文案前缀（示例是 `work-30.5M`，只想要数字就设 `compactTitle`）。

### 4.2 构建

```bash
APP_NAME="My Metric" BUNDLE_ID="com.local.example.metric" BIN_NAME="MyMetric" \
APP_DIR="$HOME/Applications" sh template_build_app.sh
```

脚本产出 `AppDir/My Metric.app`（`LSUIElement`、`NSAllowsLocalNetworking`、ad-hoc 签名）。

> **Bundle ID 一旦开始装就不要随便改**；反过来，若菜单栏项出现「进程在跑但没有窗口」，换一个全新 Bundle ID 重建是本 Skill 里最有效的一招（§6）。

### 4.3 阈值与提醒

- 阈值存 UserDefaults（示例：`alertThresholdMillion`，0 表示关闭），菜单里给固定候选（关闭／30M／50M／90M／120M）。
- 达到阈值：标题变红 + 弹一次提醒。
- 提醒用 `NSPanel`（`styleMask: [.borderless, .nonactivatingPanel]`、`level = .statusBar`、
  `canJoinAllSpaces`/`fullScreenAuxiliary`），定位到**鼠标所在屏幕**的 `visibleFrame` 右上角，
  0.18 秒淡入、**20 秒**后 0.35 秒淡出，`NSClickGestureRecognizer` 点击即关。**不要 `NSApp.activate`**，否则抢焦点。
- 去重键：`口径|日期|阈值` 存 UserDefaults，同日同口径同阈值只弹一次；跨天或改阈值重新提醒。

### 4.4 装成登录自启

先按中央规范登记，再安装（顺序不能反）：

```bash
zsh template_install_agent.sh              # 安装并启动（会先确认 .app 存在）
zsh template_install_agent.sh --status
zsh template_install_agent.sh --uninstall  # bootout + 删 plist，保留 .app
```

`~/Library/LaunchAgents/<LABEL>.plist` 里 **`ProgramArguments` 直接指向 .app 内二进制**
（AppKit 版本可被 launchd 直接执行；SwiftUI 版本不行）。`Label`＝plist 文件名＝登记 ID；
`launchctl print` 的 `program` 要显示可读的二进制名，不能是 `bash`/`zsh`。

### 4.5 验收

```bash
# 1) 数值正确：与接口逐字比对
"$APP/Contents/MacOS/$BIN" --print-once
curl -sS "http://127.0.0.1:<port>/<api>" | head -c 300

# 2) 界面在：辅助功能读取标题与菜单（比截图省事，且能读到不可见项）
osascript -e 'tell application "System Events" to tell process "<BIN>" to get name of menu bar item 1 of menu bar 1'

# 3) 可见性：状态项窗口在不在、在不在屏内
#    owner 固定是「控制中心」，name 是你 App 的 Bundle ID
osascript 无法读窗口列表时，用一个 20 行的 Swift/CoreGraphics 小程序打印
CGWindowListCopyWindowInfo 里 layer==25 且 name==<Bundle ID> 的 bounds 与 onscreen

# 4) 自动刷新：隔 70 秒读两次「更新于」
# 5) 崩溃重启：kill -9 后看 pid 是否换新
launchctl print "gui/$(id -u)/<LABEL>" | grep -E "state = running|pid =|runs ="

# 6) 负例：把接口指到死端口，确认标题变占位符、菜单显示错误、进程不崩
```

截图请**分别截每块屏**（`screencapture -x -D 1|-D 2 ...`），多屏时主屏截图看不到另一块屏的菜单栏。

## 5. 已确认会失败的写法（别再试）

| 写法 | 现象 |
|---|---|
| `@NSApplicationDelegateAdaptor` + `MenuBarExtra` | `didFinishLaunching` 之后立刻 `willTerminate`，退出码 0 |
| `MenuBarExtra { 自定义菜单内容 } label: { HStack{Image;Text} }` | 启动即退出 |
| `.menuBarExtraStyle(.menu)` + 自定义菜单视图 | 启动即退出 |
| 状态项被系统隐藏时的 SwiftUI 版本 | 进程直接结束 |
| 直接 `exec` 二进制运行 SwiftUI 版本 | 不驻留（必须经 LaunchServices `open`） |

排查技巧：`Main.log()` 打到 stderr，用 launchd 的 `StandardErrorPath` 收集；
崩溃点落在 `App.main()` 返回前且退出码 0，基本就是 SwiftUI 场景装配失败。

## 6. 排障：进程在跑，但菜单栏看不见

按顺序判，**不要猜**：

```text
1) 有进程吗          pgrep -fl <BIN>
2) 有状态项窗口吗    CGWindowListCopyWindowInfo → layer==25 且 name==<Bundle ID>
   ├── 没有窗口 → 该 Bundle ID 的状态记录被写坏（反复强杀/隐藏残留）
   │               ⇒ 换全新 Bundle ID 重建（改 build 脚本里的 Bundle ID），
   │                 清掉旧 plist 与 defaults 域，最有效
   └── 有窗口 → 看 onscreen / bounds
       ├── onscreen=false 或 X 为负 / 超出屏宽 → 菜单栏已满（或装了 Hidden Bar 之类分割器）
       │   ⇒ 让用户腾出约 100 pt（隐藏一个不用的图标）；程序无法控制排序
       └── onscreen=true 但截图里没有 → 多半在另一块屏，用 -D <n> 分别截图确认
```

其他已验证的现象：

- 多屏时 `System Events` 的 `position` 与 `CGWindowList` 的坐标口径不一致，**不要用坐标反推位置**，用窗口列表的 `bounds`。
- `NSStatusItem VisibleCC Item-0 = 0` 表示系统记录了「隐藏」，强写 `true` 会被立刻改回；换 Bundle ID 比对抗它省事。
- 新建项永远排在时钟左侧的末尾；**菜单栏排满时**会被放到时钟右侧屏幕外。

## 7. 后台服务登记（中央规范要点）

- 涉及「任务结束后仍运行 / 登录自启 / 自动重启」⇒ 必须先读 `~/.agents/rules/background-services.md`，
  **先在登记表登记再安装**（登记簿：电脑治理仓库根目录 `后台服务登记表.md`）。
- 登记字段：唯一 ID、可读名称、项目/路径、创建来源与目的、运行方式与启停条件、端口（本类工具**不监听端口**）、
  数据/日志位置、启停与健康检查、授权依据、状态、最近核验时间；变更写变更记录。
- `Label` ＝ plist 文件名 ＝ 登记 ID；`program` 必须是可读名。
- 只读本机回环接口时，登记里要写清「不监听端口、不写业务数据、不碰凭据、不触发账号类副作用」。

## 8. 随包文件

| 文件 | 用途 |
|---|---|
| `template_menu_bar_app.swift` | AppKit 参考实现（含 `--print-once` 自检、阈值、变红、右上角卡片） |
| `template_build_app.sh` | 编译并组装 `.app`（`APP_NAME`/`BUNDLE_ID`/`BIN_NAME`/`APP_DIR` 环境变量） |
| `template_test.sh` | 夹具回归：固定 JSON 验解析与口径；后端不可达验退出码 |
| `template_fixture.json` | 夹具（`__TODAY__` 占位符由脚本替换） |
| `template_launch_agent.plist` | LaunchAgent 模板（`__APP_EXECUTABLE__`/`__LOG_PATH__`/`__LABEL__`） |
| `template_install_agent.sh` | 安装／`--status`／`--uninstall` |

模板里的路径全部走 `$HOME`/环境变量，不含机器专属路径；示例 Bundle ID 一律 `com.local.example.metric`，落地时必须换掉。

## 9. 交付前自检

- [ ] `--print-once` 与接口数值逐字一致
- [ ] 菜单栏可见（截图 + 窗口列表 `onscreen=true`）
- [ ] 菜单能切口径、切刷新间隔，重启后保持
- [ ] 自动刷新按设定间隔发生（间隔 70 秒实测两次）
- [ ] `kill -9` 后 launchd 自动拉起（pid 变化）
- [ ] 接口不可达时有可见错误，不崩不退
- [ ] 阈值触发：标题变红 + 卡片出现在右上角 + 20 秒后消失 + 同日不重复
- [ ] 登录自启已登记、`launchctl print` 为 running
- [ ] 无人值守副作用为零（不监听端口、不写业务数据、不触发账号任务）

## 10. 调用提示词

```text
按 macos-menubar-metric-widget-local-zh 的做法，给我做一个菜单栏常驻小工具：
数据来自 <本机接口/文件>，显示 <要看的数>，口径 <今日/总计/…>，阈值 <N> 达到后变红并提醒。
装成登录自启前先按后台服务规范登记。
```
