// ============================================================================
// 参考实现（macOS 菜单栏指标小工具）
//
// 来源：2026-10-26 在本机实测通过的 WorkBuddy Token 菜单栏实现；这里作为模板，
//      逻辑未改动，只加了 ADAPT 标注。落地时按下面的顺序改，改完用 template_test.sh 验。
//
// ADAPT 顺序：
//   1. TokenAPI.defaultEndpoint    —— 换成本机只读接口（只允许 127.0.0.1）
//   2. TokenStatsResponse 等模型    —— 换成你的 JSON 结构
//   3. TokenSnapshot.make          —— 怎么挑出「今天 / 当前」那一条
//   4. NumberFormat.compact        —— 单位格式（1.2M / 85% / 12 个）
//   5. DisplaySource               —— 口径候选（哪个产品 / 哪些分组）
//   6. RefreshInterval             —— 刷新间隔候选
//   7. thresholdChoices            —— 阈值候选（百万数示例，换成你的单位）
//   8. 菜单文案（今日/输入/输出…）   —— 换成你的业务说法
//
// 不要改的部分：
//   - AppKit NSStatusItem 而不是 SwiftUI MenuBarExtra（原因见 SKILL.md §5）
//   - 单实例 flock（目录按 Bundle ID 派生，多个小工具可共存）、isFetching 防重入
//   - 失败保留上次数值
//   - BannerNotifier（无边框 NSPanel、不抢焦点、20 秒淡出、点击即关）
//   - --print-once（验收与回归都靠它）
// ============================================================================

//! WorkBuddy Token 菜单栏小程序。
//!
//! 只读本机生产服务 `http://127.0.0.1:57890/api/token-stats` 的聚合结果，
//! 不读日志、不写业务数据、不监听端口。标题显示所选口径的今日 Token 总量
//! （`work-25.9M`），菜单里给出输入/输出/缓存命中率以及口径与刷新间隔切换。
//!
//! 用 AppKit 的 `NSStatusItem` 而不是 SwiftUI `MenuBarExtra`：后者在本机
//! （macOS 26）一旦状态项被系统判为隐藏就会直接结束进程，且自定义 label 与
//! `.menu` 菜单内容都会让程序启动即退出（均已实测）。

import AppKit
import Darwin

// MARK: - API models

// ADAPT 2：JSON 结构（字段名对齐服务端；可能为空的值用 Optional）
struct TokenStatsResponse: Decodable {
    let generatedAt: Int?
    let rangeDays: Int?
    let sources: [TokenSource]
}

struct TokenSource: Decodable {
    let source: String
    let daily: [DailyUsage]
    let summary: UsageSummary
}

struct DailyUsage: Decodable {
    let key: String
    let total: Int
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    let records: Int
    let cacheHitRate: Double?
}

struct UsageSummary: Decodable {
    let total: Int
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    let records: Int
    let cacheHitRate: Double?
}

// MARK: - API client

enum TokenAPIError: LocalizedError {
    case badStatus(Int)
    case unreachable

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "服务返回 HTTP \(code)"
        case .unreachable: return "无法连接本机服务 127.0.0.1:57890"
        }
    }
}

enum TokenAPI {
    // ADAPT 1：本机只读接口（不要写成远端地址）
    static let defaultEndpoint = "http://127.0.0.1:57890/api/token-stats"
    static let console = URL(string: "http://127.0.0.1:57890/")!

    /// `WB_TOKEN_API` 仅用于测试与隔离验证，生产不设置该变量。
    static var endpoint: URL {
        if let raw = ProcessInfo.processInfo.environment["WB_TOKEN_API"],
           let url = URL(string: raw) {
            return url
        }
        return URL(string: defaultEndpoint)!
    }

    static func fetchSync(timeout: TimeInterval = 20) throws -> TokenStatsResponse {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        items.append(URLQueryItem(name: "days", value: "1"))
        components?.queryItems = items
        guard let url = components?.url else { throw TokenAPIError.unreachable }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<TokenStatsResponse, Error> = .failure(TokenAPIError.unreachable)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(error)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                result = .failure(TokenAPIError.unreachable)
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                result = .failure(TokenAPIError.badStatus(http.statusCode))
                return
            }
            guard let data else {
                result = .failure(TokenAPIError.unreachable)
                return
            }
            do {
                result = .success(try JSONDecoder().decode(TokenStatsResponse.self, from: data))
            } catch {
                result = .failure(error)
            }
        }.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 5)
        return try result.get()
    }
}

// MARK: - Display model

enum DayKey {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()

    static func today(_ date: Date = Date()) -> String {
        formatter.string(from: date)
    }
}

enum NumberFormat {
    // ADAPT 4：单位格式
    static func compact(_ value: Int) -> String {
        let number = Double(value)
        if number >= 1_000_000_000 { return String(format: "%.2fB", number / 1_000_000_000) }
        if number >= 1_000_000 { return String(format: "%.1fM", number / 1_000_000) }
        if number >= 1_000 { return String(format: "%.1fK", number / 1_000) }
        return "\(value)"
    }

    static func percent(_ ratio: Double?) -> String {
        guard let ratio, ratio.isFinite else { return "—" }
        return String(format: "%.1f%%", ratio * 100)
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

// ADAPT 5：口径候选
enum DisplaySource: String, CaseIterable {
    case workbuddy
    case codebuddyCLI = "codebuddy-cli"
    case codebuddyIDE = "codebuddy-ide"
    case all

    var label: String {
        switch self {
        case .workbuddy: return "WorkBuddy"
        case .codebuddyCLI: return "CodeBuddy CLI"
        case .codebuddyIDE: return "CodeBuddy IDE"
        case .all: return "三产品合计"
        }
    }
}

// ADAPT 6：刷新间隔候选（接口贵就把默认调长）
enum RefreshInterval: Int, CaseIterable {
    case thirty = 30
    case sixty = 60
    case fiveMinutes = 300
    case tenMinutes = 600
    case manual = 0

    var label: String {
        switch self {
        case .thirty: return "30 秒"
        case .sixty: return "1 分钟"
        case .fiveMinutes: return "5 分钟"
        case .tenMinutes: return "10 分钟"
        case .manual: return "手动刷新"
        }
    }
}

struct TokenSnapshot {
    let day: String
    let bySource: [String: DailyUsage]
    let updatedAt: Date

    // ADAPT 3：怎么从响应里挑出「今天 / 当前」那一条
    static func make(from response: TokenStatsResponse, at date: Date = Date()) -> TokenSnapshot {
        let day = DayKey.today(date)
        var bySource: [String: DailyUsage] = [:]
        for source in response.sources {
            if let usage = source.daily.first(where: { $0.key == day }) {
                bySource[source.source] = usage
            }
        }
        return TokenSnapshot(day: day, bySource: bySource, updatedAt: date)
    }

    func total(for source: DisplaySource) -> Int {
        switch source {
        case .all: return bySource.values.reduce(0) { $0 + $1.total }
        default: return bySource[source.rawValue]?.total ?? 0
        }
    }

    func input(for source: DisplaySource) -> Int {
        switch source {
        case .all: return bySource.values.reduce(0) { $0 + $1.input }
        default: return bySource[source.rawValue]?.input ?? 0
        }
    }

    func output(for source: DisplaySource) -> Int {
        switch source {
        case .all: return bySource.values.reduce(0) { $0 + $1.output }
        default: return bySource[source.rawValue]?.output ?? 0
        }
    }

    func cacheHitRate(for source: DisplaySource) -> Double? {
        if case .all = source {
            let input = input(for: .all)
            guard input > 0 else { return nil }
            let read = bySource.values.reduce(0) { $0 + $1.cacheRead }
            return Double(read) / Double(input)
        }
        return bySource[source.rawValue]?.cacheHitRate
    }
}

// MARK: - Menu bar controller

@MainActor
final class MenuController: NSObject {
    private enum Keys {
        static let source = "displaySource"
        static let interval = "refreshInterval"
        static let compact = "compactTitle"
        static let threshold = "alertThresholdMillion"
        static let lastAlert = "lastAlertKey"
    }

    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let headerItem = NSMenuItem()
    private let detailItem = NSMenuItem()
    private let errorItem = NSMenuItem()
    private let updatedItem = NSMenuItem()
    private let sourceMenu = NSMenu()
    private var thresholdItem: NSMenuItem?
    private let intervalMenu = NSMenu()
    private let thresholdMenu = NSMenu()

    /// 可选阈值（百万 Token），0 表示关闭提醒。
    // ADAPT 7：阈值候选（百万数示例，0＝关闭）
    private let thresholdChoices: [Double] = [0, 30, 50, 90, 120]

    private var snapshot: TokenSnapshot?
    private var errorText: String?
    private var isFetching = false
    private var timer: Timer?
    private let notifier = BannerNotifier()

    private var displaySource: DisplaySource {
        didSet {
            UserDefaults.standard.set(displaySource.rawValue, forKey: Keys.source)
            render()
            refresh()
        }
    }

    private var interval: RefreshInterval {
        didSet {
            UserDefaults.standard.set(interval.rawValue, forKey: Keys.interval)
            restartTimer()
        }
    }

    /// 菜单栏放不下 `work-` 前缀时，可切到只显示数字。
    private var compactTitle: Bool {
        didSet {
            UserDefaults.standard.set(compactTitle, forKey: Keys.compact)
            render()
        }
    }

    /// 提醒阈值（百万 Token，0＝关闭）。达到后标题变红并弹一次提醒。
    private var thresholdMillion: Double {
        didSet {
            UserDefaults.standard.set(thresholdMillion, forKey: Keys.threshold)
            render()
        }
    }

    override init() {
        let defaults = UserDefaults.standard
        displaySource = DisplaySource(rawValue: defaults.string(forKey: Keys.source) ?? "") ?? .workbuddy
        let stored = defaults.object(forKey: Keys.interval) as? Int
        interval = RefreshInterval(rawValue: stored ?? RefreshInterval.sixty.rawValue) ?? .sixty
        compactTitle = defaults.bool(forKey: Keys.compact)
        thresholdMillion = defaults.object(forKey: Keys.threshold) as? Double ?? 90

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.systemFontSize,
            weight: .regular
        )
        statusItem.button?.title = "work-…"

        buildMenu()
        statusItem.menu = menu

        restartTimer()
        refresh()
    }

    // MARK: menu

    private func buildMenu() {
        for item in [headerItem, detailItem, errorItem, updatedItem] {
            item.isEnabled = false
        }

        for (index, source) in DisplaySource.allCases.enumerated() {
            let item = NSMenuItem(title: source.label, action: #selector(selectSource(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            sourceMenu.addItem(item)
        }

        for (index, value) in RefreshInterval.allCases.enumerated() {
            let item = NSMenuItem(title: value.label, action: #selector(selectInterval(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            intervalMenu.addItem(item)
        }

        for (index, value) in thresholdChoices.enumerated() {
            let title = value == 0 ? "关闭" : "\(Int(value))M"
            let item = NSMenuItem(title: title, action: #selector(selectThreshold(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            thresholdMenu.addItem(item)
        }

        let sourceItem = NSMenuItem(title: "显示口径", action: nil, keyEquivalent: "")
        sourceItem.submenu = sourceMenu
        let intervalItem = NSMenuItem(title: "刷新间隔", action: nil, keyEquivalent: "")
        intervalItem.submenu = intervalMenu
        thresholdItem = NSMenuItem(title: "提醒阈值", action: nil, keyEquivalent: "")
        thresholdItem?.submenu = thresholdMenu

        let refreshNow = NSMenuItem(title: "立即刷新", action: #selector(refreshNow), keyEquivalent: "r")
        refreshNow.target = self
        let openConsole = NSMenuItem(title: "打开主界面", action: #selector(openConsole), keyEquivalent: "o")
        openConsole.target = self
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self

        menu.addItem(headerItem)
        menu.addItem(detailItem)
        menu.addItem(errorItem)
        menu.addItem(.separator())
        menu.addItem(sourceItem)
        menu.addItem(intervalItem)
        if let thresholdItem { menu.addItem(thresholdItem) }
        menu.addItem(.separator())
        menu.addItem(refreshNow)
        menu.addItem(openConsole)
        let compactItem = NSMenuItem(title: "紧凑标签（只显示数字）", action: #selector(toggleCompact), keyEquivalent: "t")
        compactItem.target = self
        menu.addItem(compactItem)
        menu.addItem(updatedItem)
        menu.addItem(.separator())
        menu.addItem(quit)
    }

    private func render() {
        var overThreshold = false
        if let snapshot {
            let total = snapshot.total(for: displaySource)
            overThreshold = thresholdMillion > 0 && Double(total) >= thresholdMillion * 1_000_000
            setStatusTitle(menuBarTitle(NumberFormat.compact(total)), overThreshold: overThreshold)
            headerItem.title = "今日 \(displaySource.label) \(NumberFormat.compact(snapshot.total(for: displaySource)))"
            detailItem.title = "输入 \(NumberFormat.compact(snapshot.input(for: displaySource)))"
                + " · 输出 \(NumberFormat.compact(snapshot.output(for: displaySource)))"
                + " · 缓存命中 \(NumberFormat.percent(snapshot.cacheHitRate(for: displaySource)))"
            updatedItem.title = "更新于 \(NumberFormat.time(snapshot.updatedAt))"
            statusItem.button?.toolTip = headerItem.title
        } else {
            setStatusTitle(menuBarTitle(errorText == nil ? "…" : "—"), overThreshold: false)
            headerItem.title = errorText == nil ? "正在读取 Token 统计…" : "无法读取 Token 统计"
            detailItem.title = ""
            updatedItem.title = ""
            statusItem.button?.toolTip = errorText ?? "正在读取 Token 统计"
        }

        errorItem.title = errorText.map { "刷新失败：\($0)" } ?? ""
        errorItem.isHidden = errorText == nil
        detailItem.isHidden = detailItem.title.isEmpty
        updatedItem.isHidden = updatedItem.title.isEmpty

        for (index, source) in DisplaySource.allCases.enumerated() where index < sourceMenu.items.count {
            sourceMenu.items[index].title = snapshot.map {
                "\(source.label) \(NumberFormat.compact($0.total(for: source)))"
            } ?? source.label
            sourceMenu.items[index].state = source == displaySource ? .on : .off
        }

        for (index, value) in RefreshInterval.allCases.enumerated() where index < intervalMenu.items.count {
            intervalMenu.items[index].state = value == interval ? .on : .off
        }

        thresholdItem?.title = thresholdMillion > 0 ? "提醒阈值 \(Int(thresholdMillion))M" : "提醒阈值（关闭）"
        for (index, value) in thresholdChoices.enumerated() where index < thresholdMenu.items.count {
            thresholdMenu.items[index].state = value == thresholdMillion ? .on : .off
        }

        compactMenuState()

        if overThreshold, let snapshot {
            maybeAlert(total: snapshot.total(for: displaySource))
        }
    }

    // MARK: actions

    private func setStatusTitle(_ text: String, overThreshold: Bool) {
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: overThreshold ? NSColor.systemRed : NSColor.labelColor,
            ]
        )
    }

    /// 同一天、同一口径、同一阈值只提醒一次；跨天或改阈值会重新提醒。
    private func maybeAlert(total: Int) {
        let day = DayKey.today()
        let key = "\(displaySource.rawValue)|\(day)|\(Int(thresholdMillion))"
        guard UserDefaults.standard.string(forKey: Keys.lastAlert) != key else { return }
        UserDefaults.standard.set(key, forKey: Keys.lastAlert)

        notifier.show(
            title: "今日 \(displaySource.label) Token 已达 \(NumberFormat.compact(total))",
            body: "提醒阈值 \(Int(thresholdMillion))M，可在菜单「提醒阈值」里调整或关闭。"
        )
    }

    private func menuBarTitle(_ value: String) -> String {
        compactTitle ? value : "work-\(value)"
    }

    @objc private func toggleCompact() {
        compactTitle.toggle()
        compactMenuState()
    }

    private func compactMenuState() {
        for item in menu.items where item.action == #selector(toggleCompact) {
            item.state = compactTitle ? .on : .off
        }
    }

    @objc private func selectSource(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < DisplaySource.allCases.count else { return }
        displaySource = DisplaySource.allCases[sender.tag]
    }

    @objc private func selectInterval(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < RefreshInterval.allCases.count else { return }
        interval = RefreshInterval.allCases[sender.tag]
    }

    @objc private func selectThreshold(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < thresholdChoices.count else { return }
        thresholdMillion = thresholdChoices[sender.tag]
    }

    @objc private func refreshNow() {
        refresh()
    }

    @objc private func openConsole() {
        NSWorkspace.shared.open(TokenAPI.console)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: fetching

    func refresh() {
        guard !isFetching else { return }
        isFetching = true
        Task { [weak self] in
            let outcome: Result<TokenStatsResponse, Error>
            do {
                outcome = .success(try await Task.detached(priority: .utility) {
                    try TokenAPI.fetchSync()
                }.value)
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return }
            self.isFetching = false
            switch outcome {
            case .success(let response):
                self.snapshot = TokenSnapshot.make(from: response)
                self.errorText = nil
            case .failure(let error):
                self.errorText = error.localizedDescription
            }
            self.render()
        }
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard interval != .manual else { return }
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(interval.rawValue), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
}

/// 右上角通知卡片：不抢焦点、20 秒后淡出，点击可立即关闭。
@MainActor
final class BannerNotifier {
    private var panel: NSPanel?
    private var dismissTask: DispatchWorkItem?

    func show(title: String, body: String, seconds: TimeInterval = 20) {
        dismiss(animated: false)

        let width: CGFloat = 360
        let padding: CGFloat = 14
        let textWidth = width - padding * 2

        let titleLabel = NSTextField(wrappingLabelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.preferredMaxLayoutWidth = textWidth

        let bodyLabel = NSTextField(wrappingLabelWithString: body)
        bodyLabel.font = .systemFont(ofSize: 13)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.preferredMaxLayoutWidth = textWidth

        let stack = NSStackView(views: [titleLabel, bodyLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: padding, left: padding, bottom: padding, right: padding)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let height = stack.fittingSize.height
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(
            x: visible.maxX - width - 16,
            y: visible.maxY - height - 16,
            width: width,
            height: height
        )

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = effect
        panel.alphaValue = 0
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        effect.addGestureRecognizer(click)

        self.panel = panel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }

        let task = DispatchWorkItem { [weak self] in self?.dismiss(animated: true) }
        dismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: task)
    }

    @objc private func handleClick() {
        dismiss(animated: false)
    }

    private func dismiss(animated: Bool) {
        dismissTask?.cancel()
        dismissTask = nil
        guard let panel else { return }
        self.panel = nil
        guard animated else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = MenuController()
    }
}

// MARK: - CLI (test / QA)

enum CLI {
    static func printOnce() -> Int32 {
        do {
            let response = try TokenAPI.fetchSync()
            let snapshot = TokenSnapshot.make(from: response)
            var sources: [String: [String: Any]] = [:]
            for source in response.sources {
                let usage = snapshot.bySource[source.source]
                sources[source.source] = [
                    "total": usage?.total ?? 0,
                    "input": usage?.input ?? 0,
                    "output": usage?.output ?? 0,
                    "cacheRead": usage?.cacheRead ?? 0,
                    "records": usage?.records ?? 0,
                    "cacheHitRate": usage?.cacheHitRate.map { $0 } ?? NSNull(),
                ]
            }
            let payload: [String: Any] = [
                "date": snapshot.day,
                "generatedAt": response.generatedAt ?? 0,
                "all": snapshot.total(for: .all),
                "sources": sources,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}

enum InstanceLock {
    private static var descriptor: Int32 = -1

    /// 只允许一个菜单栏实例；launchd 重启与手动打开同时发生时不重复出现图标。
    /// 目录按 Bundle ID 派生，否则两个不同的菜单栏小工具会互相抢锁。
    static func acquire() -> Bool {
        let identifier = Bundle.main.bundleIdentifier ?? "menu-bar-metric"
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(identifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("instance.lock").path
        descriptor = open(path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return true }
        return flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }
}

@main
struct Main {
    static func main() {
        if CommandLine.arguments.contains("--print-once") {
            exit(CLI.printOnce())
        }
        log("启动：args=\(CommandLine.arguments)")
        guard InstanceLock.acquire() else {
            log("已有实例持有锁，退出")
            exit(0)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
        log("事件循环结束，进程退出")
    }

    static func log(_ message: String) {
        let tag = ProcessInfo.processInfo.processName
        FileHandle.standardError.write(Data("[\(tag)] \(message)\n".utf8))
    }
}
