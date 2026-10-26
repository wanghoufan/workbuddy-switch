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

enum HTTPClient {
    /// 同步 GET；菜单栏的刷新在后台线程调用，避免把 URLSession 回调塞回主线程。
    static func get(_ url: URL, timeout: TimeInterval) throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(TokenAPIError.unreachable)
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
            result = .success(data)
        }.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 5)
        return try result.get()
    }
}

enum TokenAPI {
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

    /// 同端口下其它只读接口（`/api/accounts`）的根地址。
    static var baseURL: URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.path = ""
        components?.query = nil
        components?.fragment = nil
        return components?.url ?? URL(string: "http://127.0.0.1:57890")!
    }

    static func fetchSync(timeout: TimeInterval = 20) throws -> TokenStatsResponse {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        items.append(URLQueryItem(name: "days", value: "1"))
        components?.queryItems = items
        guard let url = components?.url else { throw TokenAPIError.unreachable }

        let data = try HTTPClient.get(url, timeout: timeout)
        return try JSONDecoder().decode(TokenStatsResponse.self, from: data)
    }
}

// MARK: - 当前账号

struct WorkbuddyAccountsResponse: Decodable {
    let accounts: [WorkbuddyAccount]
    let current: String?
}

struct WorkbuddyAccount: Decodable {
    let id: String?
    let uid: String?
    let nickname: String?
}

struct WorkbuddyAccountContext {
    /// 账号库里的 id，用来查「这个账号有哪些会话」。
    let id: String
    let uid: String
    /// 手机号前三位（133 / 166 / 199）。
    let prefix: String
}

enum AccountAPI {
    /// 当前 WorkBuddy 账号：id、uid、手机号前三位。
    /// 只读本机服务的账号列表，不落盘、不写日志；取不到时返回 nil。
    static func currentContext() -> WorkbuddyAccountContext? {
        do {
            let url = TokenAPI.baseURL.appendingPathComponent("api/accounts")
            let data = try HTTPClient.get(url, timeout: 5)
            let response = try JSONDecoder().decode(WorkbuddyAccountsResponse.self, from: data)
            guard let current = response.current,
                  let account = response.accounts.first(where: { $0.id == current || $0.uid == current }),
                  let id = account.id,
                  let uid = account.uid,
                  let nickname = account.nickname else { return nil }
            let digits = nickname.filter { $0.isNumber }
            guard digits.count >= 3 else { return nil }
            return WorkbuddyAccountContext(id: id, uid: uid, prefix: String(digits.prefix(3)))
        } catch {
            return nil
        }
    }
}

// MARK: - 当前账号的今日 WorkBuddy 用量（本地日志按会话归属）

struct WorkbuddySessionsResponse: Decodable {
    let sessions: [WorkbuddySessionRecord]
}

struct WorkbuddySessionRecord: Decodable {
    let id: String?
}

enum SessionsAPI {
    /// 当前账号在 WorkBuddy 里的会话 id 集合。日志文件按会话归属到账号，
    /// 这样就不需要从日志正文里猜账号，也不会把其他账号的用量算进来。
    static func workbuddySessionIds(accountId: String) -> Set<String>? {
        do {
            var components = URLComponents(
                url: TokenAPI.baseURL.appendingPathComponent("api/sessions/account"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "accountId", value: accountId),
                URLQueryItem(name: "client", value: "workbuddy"),
            ]
            guard let url = components?.url else { return nil }
            let data = try HTTPClient.get(url, timeout: 10)
            let response = try JSONDecoder().decode(WorkbuddySessionsResponse.self, from: data)
            return Set(response.sessions.compactMap { $0.id })
        } catch {
            return nil
        }
    }
}

struct WorkbuddyUsageSnapshot {
    let day: String
    let prefix: String
    let total: Int
    let updatedAt: Date
}

enum WorkbuddyUsageError: LocalizedError {
    case noAccount
    case noSessions

    var errorDescription: String? {
        switch self {
        case .noAccount: return "无法确定当前 WorkBuddy 账号"
        case .noSessions: return "无法读取当前账号的会话列表"
        }
    }
}

enum WorkbuddyUsageProvider {
    static func fetch(now: Date = Date()) throws -> WorkbuddyUsageSnapshot {
        guard let context = AccountAPI.currentContext() else { throw WorkbuddyUsageError.noAccount }
        guard let sessions = SessionsAPI.workbuddySessionIds(accountId: context.id) else {
            throw WorkbuddyUsageError.noSessions
        }
        let total = WorkbuddyLogUsage.todayTotal(sessionIds: sessions, now: now)
        return WorkbuddyUsageSnapshot(
            day: DayKey.today(now),
            prefix: context.prefix,
            total: total,
            updatedAt: now
        )
    }
}

/// 直接读本机 WorkBuddy 日志，只统计「当前账号的会话、今天」的 Token 总量。
/// 服务端的 `/api/token-stats` 是三个账号共同的日志目录汇总，没有账号维度；
/// 这里用 `/api/sessions/account` 给出的会话 id 做归属，再按与服务端相同的口径
/// （input 已含缓存读取，追加 output 与 cache write）求和。
enum WorkbuddyLogUsage {
    private struct Usage {
        let input: Int
        let output: Int
        let read: Int
        let write: Int
    }

    private static let cacheWriteKeys = [
        "cache_write_input_tokens",
        "cacheWriteInputTokens",
        "cache_creation_input_tokens",
        "prompt_cache_write_tokens",
    ]

    static func todayTotal(sessionIds: Set<String>, now: Date = Date(), root: URL? = nil) -> Int {
        let day = DayKey.today(now)
        let startOfDay = Calendar.current.startOfDay(for: now)
        let envRoot = ProcessInfo.processInfo.environment["WB_WORKBUDDY_ROOT"]
        let workbuddyRoot = root
            ?? envRoot.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".workbuddy")
        let projects = workbuddyRoot.appendingPathComponent("projects")

        var files: [(url: URL, modified: Date)] = []
        if let enumerator = FileManager.default.enumerator(
            at: projects,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl" else { continue }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile ?? false,
                      let modified = values?.contentModificationDate,
                      modified >= startOfDay else { continue }
                files.append((url, modified))
            }
        }
        // 与服务端一致：旧文件先处理，复制/分叉会话的重放记录只算一次。
        files.sort { $0.modified < $1.modified }

        var seen = Set<String>()
        var total = 0
        for file in files {
            guard sessionId(for: file.url, known: sessionIds) != nil else { continue }
            total += todayTotal(in: file.url, day: day, seen: &seen)
        }
        return total
    }

    private static func sessionId(for url: URL, known: Set<String>) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        if known.contains(stem) { return stem }
        // 子代理日志在 <session>/subagents/... 下，向上找到当前账号的会话目录。
        var directory = url.deletingLastPathComponent()
        for _ in 0..<4 {
            let name = directory.lastPathComponent
            if known.contains(name) { return name }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }

    private static func todayTotal(in url: URL, day: String, seen: inout Set<String>) -> Int {
        guard let data = try? Data(contentsOf: url) else { return 0 }
        let marker = Data("\"usage\"".utf8)
        var total = 0
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard line.range(of: marker) != nil else { continue }
            guard let raw = try? JSONSerialization.jsonObject(with: Data(line)),
                  let object = raw as? [String: Any],
                  let usage = usage(from: object),
                  let timestamp = timestamp(from: object),
                  dayKey(ms: timestamp) == day else { continue }
            let fingerprint = "\(timestamp)|\(usage.input)|\(usage.output)|\(usage.read)|\(usage.write)|\(model(from: object))"
            guard seen.insert(fingerprint).inserted else { continue }
            total += usage.input + usage.output + usage.write
        }
        return total
    }

    private static func dayKey(ms: Int64) -> String {
        let components = Calendar.current.dateComponents(
            [.year, .month, .day],
            from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        )
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func field(_ object: [String: Any], _ keys: [String]) -> Int? {
        for key in keys {
            if let value = intValue(object[key]) { return value }
        }
        return nil
    }

    private static func positiveField(_ object: [String: Any], _ keys: [String]) -> Int? {
        for key in keys {
            if let value = intValue(object[key]), value > 0 { return value }
        }
        return nil
    }

    private static func cachedInput(_ object: [String: Any]) -> Int {
        let keys = [
            "cache_read_input_tokens",
            "cacheReadInputTokens",
            "prompt_cache_hit_tokens",
            "cached_tokens",
        ]
        if let value = positiveField(object, keys) { return value }
        if let details = object["prompt_tokens_details"] as? [String: Any],
           let value = positiveField(details, ["cached_tokens"]) {
            return value
        }
        if let details = object["inputTokensDetails"] as? [[String: Any]] {
            for detail in details {
                if let value = positiveField(detail, ["cached_tokens"]) { return value }
            }
        }
        return 0
    }

    private static func usage(from value: [String: Any]) -> Usage? {
        let provider = value["providerData"] as? [String: Any]
        var candidates: [[String: Any]] = []
        if let message = value["message"] as? [String: Any],
           let usage = message["usage"] as? [String: Any] {
            candidates.append(usage)
        }
        if let usage = provider?["usage"] as? [String: Any] {
            candidates.append(usage)
        }
        if let usage = value["usage"] as? [String: Any] {
            candidates.append(usage)
        }
        let inputKeys = ["input_tokens", "inputTokens", "prompt_tokens"]
        guard let selected = candidates.first(where: { field($0, inputKeys) != nil }) else { return nil }

        var write = positiveField(selected, cacheWriteKeys) ?? 0
        if write == 0 {
            var others = candidates
            if let raw = provider?["rawUsage"] as? [String: Any] { others.append(raw) }
            for object in others {
                if let value = positiveField(object, cacheWriteKeys), value > 0 {
                    write = value
                    break
                }
            }
        }
        return Usage(
            input: field(selected, inputKeys) ?? 0,
            output: field(selected, ["output_tokens", "outputTokens", "completion_tokens"]) ?? 0,
            read: cachedInput(selected),
            write: write
        )
    }

    private static func timestamp(from value: [String: Any]) -> Int64? {
        for key in ["timestamp", "ts"] {
            if let number = value[key] as? NSNumber { return number.int64Value }
            if let text = value[key] as? String,
               let parsed = Int64(text.trimmingCharacters(in: .whitespaces)) {
                return parsed
            }
        }
        return nil
    }

    private static func model(from value: [String: Any]) -> String {
        if let provider = value["providerData"] as? [String: Any],
           let model = provider["model"] as? String,
           !model.isEmpty {
            return model
        }
        if let model = value["model"] as? String, !model.isEmpty { return model }
        return "未知模型"
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

enum MenuTitle {
    /// `work-<账号前缀>-446.7M`；账号前缀取不到时退回 `work-446.7M`。
    static func make(prefix: String?, value: String, compact: Bool) -> String {
        let body = prefix.map { "\($0)-\(value)" } ?? value
        return compact ? body : "work-\(body)"
    }
}

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

/// 提醒阈值候选（百万 Token），0 表示关闭。
/// 与菜单项共用这一份数据，`--print-once` 也会输出，便于夹具回归核对。
enum ThresholdChoices {
    static let million: [Double] = [0, 30, 50, 90, 120, 150, 180, 300, 500]
}

struct TokenSnapshot {
    let day: String
    let bySource: [String: DailyUsage]
    let updatedAt: Date

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

    /// 菜单「三产品合计」只累加菜单里列出的三个来源。
    /// 后端还会返回 WorkBuddy 国际版（`workbuddy-ai`），两者账号体系不同，
    /// 菜单栏不单列、也不并入合计（避免「三产品」实际算出四项）。
    private static let productSources: [DisplaySource] = [.workbuddy, .codebuddyCLI, .codebuddyIDE]

    func total(for source: DisplaySource) -> Int {
        switch source {
        case .all: return Self.productSources.reduce(0) { $0 + (bySource[$1.rawValue]?.total ?? 0) }
        default: return bySource[source.rawValue]?.total ?? 0
        }
    }

    func input(for source: DisplaySource) -> Int {
        switch source {
        case .all: return Self.productSources.reduce(0) { $0 + (bySource[$1.rawValue]?.input ?? 0) }
        default: return bySource[source.rawValue]?.input ?? 0
        }
    }

    func output(for source: DisplaySource) -> Int {
        switch source {
        case .all: return Self.productSources.reduce(0) { $0 + (bySource[$1.rawValue]?.output ?? 0) }
        default: return bySource[source.rawValue]?.output ?? 0
        }
    }

    func cacheHitRate(for source: DisplaySource) -> Double? {
        if case .all = source {
            let input = input(for: .all)
            guard input > 0 else { return nil }
            let read = Self.productSources.reduce(0) { $0 + (bySource[$1.rawValue]?.cacheRead ?? 0) }
            return Double(read) / Double(input)
        }
        return bySource[source.rawValue]?.cacheHitRate
    }
}

// MARK: - Menu bar controller

@MainActor
final class MenuController: NSObject {
    private enum Keys {
        static let interval = "refreshInterval"
        static let compact = "compactTitle"
        static let threshold = "alertThresholdMillion"
        static let lastAlert = "lastAlertKey"
    }

    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let headerItem = NSMenuItem()
    private let errorItem = NSMenuItem()
    private let updatedItem = NSMenuItem()
    private var thresholdItem: NSMenuItem?
    private let intervalMenu = NSMenu()
    private let thresholdMenu = NSMenu()

    /// 可选阈值（百万 Token），0 表示关闭提醒。
    private let thresholdChoices = ThresholdChoices.million

    private var usage: WorkbuddyUsageSnapshot?
    private var errorText: String?
    private var isFetching = false
    private var timer: Timer?
    private let notifier = BannerNotifier()

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
        for item in [headerItem, errorItem, updatedItem] {
            item.isEnabled = false
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
        menu.addItem(errorItem)
        menu.addItem(.separator())
        menu.addItem(intervalItem)
        if let thresholdItem { menu.addItem(thresholdItem) }
        menu.addItem(.separator())
        menu.addItem(refreshNow)
        menu.addItem(openConsole)
        let compactItem = NSMenuItem(title: "紧凑标签（省略 work- 前缀）", action: #selector(toggleCompact), keyEquivalent: "t")
        compactItem.target = self
        menu.addItem(compactItem)
        menu.addItem(updatedItem)
        menu.addItem(.separator())
        menu.addItem(quit)
    }

    private func render() {
        var overThreshold = false
        if let usage {
            overThreshold = thresholdMillion > 0 && Double(usage.total) >= thresholdMillion * 1_000_000
            let compact = NumberFormat.compact(usage.total)
            setStatusTitle(menuBarTitle(compact), overThreshold: overThreshold)
            headerItem.title = "今日 WorkBuddy（账号 \(usage.prefix)…） \(compact)"
            updatedItem.title = "更新于 \(NumberFormat.time(usage.updatedAt))"
            statusItem.button?.toolTip = headerItem.title
        } else {
            setStatusTitle(menuBarTitle(errorText == nil ? "…" : "—"), overThreshold: false)
            headerItem.title = errorText == nil ? "正在读取 WorkBuddy 用量…" : "无法读取 WorkBuddy 用量"
            updatedItem.title = ""
            statusItem.button?.toolTip = errorText ?? "正在读取 WorkBuddy 用量"
        }

        errorItem.title = errorText.map { "刷新失败：\($0)" } ?? ""
        errorItem.isHidden = errorText == nil
        updatedItem.isHidden = updatedItem.title.isEmpty

        for (index, value) in RefreshInterval.allCases.enumerated() where index < intervalMenu.items.count {
            intervalMenu.items[index].state = value == interval ? .on : .off
        }

        thresholdItem?.title = thresholdMillion > 0 ? "提醒阈值 \(Int(thresholdMillion))M" : "提醒阈值（关闭）"
        for (index, value) in thresholdChoices.enumerated() where index < thresholdMenu.items.count {
            thresholdMenu.items[index].state = value == thresholdMillion ? .on : .off
        }

        compactMenuState()

        if overThreshold, let usage {
            maybeAlert(total: usage.total)
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

    /// 同一天、同一账号、同一阈值只提醒一次；跨天或改阈值会重新提醒。
    private func maybeAlert(total: Int) {
        let day = DayKey.today()
        let prefix = usage?.prefix ?? "-"
        let key = "workbuddy|\(prefix)|\(day)|\(Int(thresholdMillion))"
        guard UserDefaults.standard.string(forKey: Keys.lastAlert) != key else { return }
        UserDefaults.standard.set(key, forKey: Keys.lastAlert)

        let account = usage.map { "（账号 \($0.prefix)…）" } ?? ""
        notifier.show(
            title: "今日 WorkBuddy\(account) Token 已达 \(NumberFormat.compact(total))",
            body: "提醒阈值 \(Int(thresholdMillion))M，可在菜单「提醒阈值」里调整或关闭。"
        )
    }

    private func menuBarTitle(_ value: String) -> String {
        MenuTitle.make(prefix: usage?.prefix, value: value, compact: compactTitle)
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
            let outcome: Result<WorkbuddyUsageSnapshot, Error>
            do {
                outcome = .success(try await Task.detached(priority: .utility) {
                    try WorkbuddyUsageProvider.fetch()
                }.value)
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return }
            self.isFetching = false
            switch outcome {
            case .success(let usage):
                self.usage = usage
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
            let local: WorkbuddyUsageSnapshot?
            let localError: String?
            do {
                local = try WorkbuddyUsageProvider.fetch()
                localError = nil
            } catch {
                local = nil
                localError = error.localizedDescription
            }
            let payload: [String: Any] = [
                "date": snapshot.day,
                "generatedAt": response.generatedAt ?? 0,
                "all": snapshot.total(for: .all),
                "sources": sources,
                "thresholdChoices": ThresholdChoices.million,
                // API 是三账号汇总，仅用于回归；标题取当前账号的本地日志统计。
                "workbuddy": snapshot.total(for: .workbuddy),
                "accountPrefix": local?.prefix ?? NSNull(),
                "localWorkbuddy": local?.total ?? NSNull(),
                "localError": localError ?? NSNull(),
                "title": local.map {
                    MenuTitle.make(
                        prefix: $0.prefix,
                        value: NumberFormat.compact($0.total),
                        compact: false
                    )
                } ?? NSNull(),
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
