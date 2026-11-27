import Foundation

enum QuotaProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case antigravity
    case gemini
    case deepseek

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex: return "Codex CLI"
        case .antigravity: return "Antigravity CLI"
        case .gemini: return "Gemini CLI"
        case .deepseek: return "DeepSeek"
        }
    }

    fileprivate var defaultAccountLabel: String {
        switch self {
        case .codex: return "本机 Codex"
        case .antigravity: return "本机 Antigravity"
        case .gemini: return "本机 Gemini"
        case .deepseek: return "DeepSeek"
        }
    }

    var shortTitle: String {
        switch self {
        case .codex: return "Codex"
        case .antigravity: return "AGY"
        case .gemini: return "Gemini"
        case .deepseek: return "DeepSeek"
        }
    }

    var defaultBinaryName: String {
        switch self {
        case .codex: return "codex"
        case .antigravity: return "agy"
        case .gemini: return "gemini"
        case .deepseek: return ""
        }
    }

    var usesAPIKey: Bool {
        self == .deepseek
    }

    var supportsCustomHomeDirectory: Bool {
        !usesAPIKey
    }

    var supportsCustomBinaryPath: Bool {
        !usesAPIKey
    }

    var defaultDirectoryPlaceholder: String {
        switch self {
        case .codex: return "CODEX_HOME"
        case .antigravity: return "HOME"
        case .gemini: return "~/.gemini"
        case .deepseek: return ""
        }
    }

    var defaultBaseURL: String? {
        switch self {
        case .deepseek: return "https://api.deepseek.com"
        case .codex, .antigravity, .gemini: return nil
        }
    }

    var symbolName: String {
        switch self {
        case .codex: return "terminal.fill"
        case .antigravity: return "sparkles"
        case .gemini: return "sparkle"
        case .deepseek: return "creditcard.fill"
        }
    }
}

struct QuotaAccountConfig: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var provider: QuotaProvider
    var label: String
    var planOverride: String?
    /// For Codex: custom CODEX_HOME directory. For Antigravity: custom HOME. For Gemini: custom ~/.gemini directory or oauth_creds.json path.
    var customHomePath: String?
    /// Optional explicit path to the `codex`, `agy`, or `gemini` CLI executable.
    var customBinaryPath: String?
    /// Optional custom API base URL for HTTP API providers (e.g., DeepSeek).
    var customBaseURL: String?
    /// Keychain entry ID under `com.clipflow.mac.quota` for API Key providers (e.g., DeepSeek).
    var credentialID: String?
    var isBuiltIn: Bool

    static let defaultCodexID = "builtin.codex.local"
    static let defaultAntigravityID = "builtin.antigravity.local"

    init(
        id: String,
        provider: QuotaProvider,
        label: String,
        planOverride: String? = nil,
        customHomePath: String? = nil,
        customBinaryPath: String? = nil,
        customBaseURL: String? = nil,
        credentialID: String? = nil,
        isBuiltIn: Bool
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.planOverride = planOverride
        self.customHomePath = customHomePath
        self.customBinaryPath = customBinaryPath
        self.customBaseURL = customBaseURL
        self.credentialID = credentialID
        self.isBuiltIn = isBuiltIn
    }

    func cardLabel(accountEmail: String?) -> String? {
        guard label != accountEmail, !(isBuiltIn && label == provider.defaultAccountLabel) else { return nil }
        return label
    }

    static var defaultAccounts: [QuotaAccountConfig] {
        [
            QuotaAccountConfig(
                id: defaultCodexID,
                provider: .codex,
                label: QuotaProvider.codex.defaultAccountLabel,
                isBuiltIn: true
            ),
            QuotaAccountConfig(
                id: defaultAntigravityID,
                provider: .antigravity,
                label: QuotaProvider.antigravity.defaultAccountLabel,
                isBuiltIn: true
            )
        ]
    }
}

struct QuotaBucket: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    /// Percentage used in 0...100 (may exceed 100 if over-limit).
    let usedPercent: Double
    let resetsAt: Date?
    let windowMinutes: Int?
    let detail: String?

    var clampedFraction: Double {
        min(max(usedPercent / 100.0, 0), 1)
    }

    var remainingPercent: Double {
        max(0, min(100, 100.0 - usedPercent))
    }

    var remainingFraction: Double {
        remainingPercent / 100.0
    }

    var formattedPercent: String {
        Self.formatPercent(usedPercent)
    }

    var formattedRemainingPercent: String {
        Self.formatPercent(remainingPercent)
    }

    private static func formatPercent(_ value: Double) -> String {
        let formatted = String(format: "%.1f", value)
        return (formatted.hasSuffix(".0") ? String(formatted.dropLast(2)) : formatted) + "%"
    }

    func resetCountdownText(now: Date = Date()) -> String? {
        guard let resetsAt else { return nil }
        let interval = resetsAt.timeIntervalSince(now)
        if interval <= 0 {
            return "即将重置"
        }
        guard interval < Double(Int.max) else { return nil }
        let remaining = Int(interval)
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = (remaining % 3_600) / 60
        if days > 0 {
            return hours > 0 ? "\(days) 天 \(hours) 小时后重置" : "\(days) 天后重置"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours) 小时 \(minutes) 分钟后重置" : "\(hours) 小时后重置"
        }
        return "\(max(1, minutes)) 分钟后重置"
    }
}

struct QuotaSample: Codable, Equatable {
    let timestamp: Date
    let usedPercent: Double
}

struct QuotaBalanceInfo: Codable, Equatable, Identifiable, Sendable {
    let currency: String
    let totalBalance: String
    let grantedBalance: String?
    let toppedUpBalance: String?

    var id: String { currency }

    var formattedTotal: String {
        Self.formatAmount(totalBalance, currency: currency)
    }

    var detailText: String? {
        var parts: [String] = []
        if let toppedUp = Self.meaningfulAmount(toppedUpBalance) {
            parts.append("充值 \(Self.formatAmount(toppedUp, currency: currency))")
        }
        if let granted = Self.meaningfulAmount(grantedBalance) {
            parts.append("赠金 \(Self.formatAmount(granted, currency: currency))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func meaningfulAmount(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func formatAmount(_ amount: String, currency: String) -> String {
        let trimmed = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        switch currency.uppercased() {
        case "CNY", "RMB": return "¥\(trimmed)"
        case "USD": return "$\(trimmed)"
        case "EUR": return "€\(trimmed)"
        default: return "\(trimmed) \(currency.uppercased())"
        }
    }
}

struct QuotaAccountSnapshot: Codable, Equatable, Sendable {
    let accountID: String
    let provider: QuotaProvider
    let accountEmail: String?
    let planLabel: String?
    let buckets: [QuotaBucket]
    let resetCreditsCount: Int?
    let creditBalance: String?
    let balances: [QuotaBalanceInfo]?
    let fetchedAt: Date

    init(
        accountID: String,
        provider: QuotaProvider,
        accountEmail: String?,
        planLabel: String?,
        buckets: [QuotaBucket],
        resetCreditsCount: Int?,
        creditBalance: String?,
        fetchedAt: Date,
        balances: [QuotaBalanceInfo]? = nil
    ) {
        self.accountID = accountID
        self.provider = provider
        self.accountEmail = accountEmail
        self.planLabel = planLabel
        self.buckets = buckets
        self.resetCreditsCount = resetCreditsCount
        self.creditBalance = creditBalance
        self.balances = balances
        self.fetchedAt = fetchedAt
    }

    var peakUsedPercent: Double {
        buckets.map(\.usedPercent).max() ?? 0
    }
}

struct QuotaPersistedState: Codable, Equatable {
    var accounts: [QuotaAccountConfig]
    var snapshots: [String: QuotaAccountSnapshot]
    /// Keyed by `"\(accountID)::\(bucketID)"`.
    var history: [String: [QuotaSample]]

    static let empty = QuotaPersistedState(
        accounts: QuotaAccountConfig.defaultAccounts,
        snapshots: [:],
        history: [:]
    )

    static func historyKey(accountID: String, bucketID: String) -> String {
        "\(accountID)::\(bucketID)"
    }
}

enum QuotaError: LocalizedError, Equatable {
    case binaryNotFound(QuotaProvider)
    case commandFailed(String)
    case timedOut(QuotaProvider)
    case invalidOutput(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let provider):
            return "未找到 \(provider.defaultBinaryName) 命令，请确认已安装 CLI 或在账号编辑中指定可执行文件路径。"
        case .commandFailed(let message):
            return message
        case .timedOut(let provider):
            return "查询 \(provider.title) 额度超时，请检查网络连接或登录状态后重试。"
        case .invalidOutput(let message):
            return "无法解析额度数据：\(message)"
        case .cancelled:
            return "已取消刷新"
        }
    }
}

// MARK: - Pure Parsers

enum CodexQuotaParser {
    private struct AccountReadEnvelope: Decodable {
        struct Result: Decodable {
            struct Account: Decodable {
                let type: String?
                let email: String?
                let planType: String?
                let workspaceName: String?
            }
            let account: Account?
        }
        let result: Result?
    }

    private struct RateLimitsEnvelope: Decodable {
        struct Result: Decodable {
            struct Window: Decodable {
                let usedPercent: Double
                let windowDurationMins: Int?
                let resetsAt: TimeInterval?
            }
            struct Credits: Decodable {
                let hasCredits: Bool?
                let unlimited: Bool?
                let balance: String?
            }
            struct RateLimitSet: Decodable {
                let limitId: String?
                let limitName: String?
                let primary: Window?
                let secondary: Window?
                let credits: Credits?
                let planType: String?
            }
            struct ResetCredits: Decodable {
                let availableCount: Int?
            }
            let rateLimits: RateLimitSet?
            let rateLimitsByLimitId: [String: RateLimitSet]?
            let rateLimitResetCredits: ResetCredits?
        }
        let result: Result?
    }

    static func parse(
        accountID: String,
        rateLimitsJSON: Data,
        accountJSON: Data? = nil,
        fetchedAt: Date = Date()
    ) throws -> QuotaAccountSnapshot {
        let decoder = JSONDecoder()
        let rateEnvelope: RateLimitsEnvelope
        do {
            rateEnvelope = try decoder.decode(RateLimitsEnvelope.self, from: rateLimitsJSON)
        } catch {
            throw QuotaError.invalidOutput("Codex 返回格式异常")
        }

        guard let result = rateEnvelope.result,
              result.rateLimits != nil || result.rateLimitsByLimitId?.isEmpty == false else {
            throw QuotaError.invalidOutput("Codex 未返回额度结果，请确认已执行 codex login 登录")
        }

        let accountResult = accountJSON.flatMap { try? decoder.decode(AccountReadEnvelope.self, from: $0).result }
        let email = accountResult?.account?.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mainLimit = result.rateLimits ?? result.rateLimitsByLimitId?["codex"]
        let rawPlan = mainLimit?.planType ?? accountResult?.account?.planType
        let planLabel = formatPlan(rawPlan, workspaceName: accountResult?.account?.workspaceName)

        var buckets: [QuotaBucket] = []
        if let primary = mainLimit?.primary {
            buckets.append(makeBucket(id: "primary", prefix: nil, window: primary))
        }
        if let secondary = mainLimit?.secondary {
            buckets.append(makeBucket(id: "secondary", prefix: nil, window: secondary))
        }

        if let byID = result.rateLimitsByLimitId {
            let mainLimitID = mainLimit?.limitId ?? "codex"
            for key in byID.keys.sorted() where key != mainLimitID {
                guard let extra = byID[key] else { continue }
                let labelPrefix = extra.limitName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? key
                if let primary = extra.primary {
                    buckets.append(makeBucket(id: "\(key).primary", prefix: labelPrefix, window: primary))
                }
                if let secondary = extra.secondary {
                    buckets.append(makeBucket(id: "\(key).secondary", prefix: labelPrefix, window: secondary))
                }
            }
        }

        let resetCredits = result.rateLimitResetCredits?.availableCount
        let creditBalance: String?
        if let credits = mainLimit?.credits {
            if credits.unlimited == true {
                creditBalance = "无限制"
            } else if let balance = credits.balance?.nilIfEmpty {
                creditBalance = balance
            } else {
                creditBalance = nil
            }
        } else {
            creditBalance = nil
        }

        return QuotaAccountSnapshot(
            accountID: accountID,
            provider: .codex,
            accountEmail: email?.nilIfEmpty,
            planLabel: planLabel,
            buckets: buckets,
            resetCreditsCount: resetCredits,
            creditBalance: creditBalance,
            fetchedAt: fetchedAt
        )
    }

    private static func makeBucket(
        id: String,
        prefix: String?,
        window: RateLimitsEnvelope.Result.Window
    ) -> QuotaBucket {
        let windowTitle = formatWindowTitle(minutes: window.windowDurationMins)
        let title = prefix.map { "\($0) · \(windowTitle)" } ?? windowTitle
        let resetsAt = window.resetsAt.flatMap { $0 > 1 ? Date(timeIntervalSince1970: $0) : nil }
        return QuotaBucket(
            id: id,
            title: title,
            usedPercent: max(0, window.usedPercent),
            resetsAt: resetsAt,
            windowMinutes: window.windowDurationMins,
            detail: nil
        )
    }

    private static func formatWindowTitle(minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "窗口额度" }
        if minutes == 300 { return "5 小时" }
        if minutes == 10_080 { return "周" }
        if minutes % 1_440 == 0 {
            let days = minutes / 1_440
            return days == 7 ? "周" : "\(days) 天"
        }
        if minutes % 60 == 0 {
            return "\(minutes / 60) 小时"
        }
        return "\(minutes) 分钟"
    }

    private static func formatPlan(_ raw: String?, workspaceName: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        switch raw.lowercased() {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        default: return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }
}

enum AntigravityQuotaParser {
    private struct Envelope: Decodable {
        struct Command: Decodable {
            struct Payload: Decodable {
                struct Group: Decodable {
                    struct Bucket: Decodable {
                        let id: String
                        let name: String?
                        let description: String?
                        let window: String?
                        let remaining_fraction: Double
                        let reset_time: ResetTime?
                    }
                    let name: String
                    let description: String?
                    let buckets: [Bucket]
                }
                let groups: [Group]?
            }
            let name: String?
            let data: Payload?
        }
        let status: String?
        let error: String?
        let command: Command?
    }

    private enum ResetTime: Decodable {
        case epoch(Double)
        case iso(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let epoch = try? container.decode(Double.self) {
                self = .epoch(epoch)
            } else {
                let string = try container.decode(String.self)
                self = Double(string).map(Self.epoch) ?? .iso(string)
            }
        }
    }

    static func parse(
        accountID: String,
        jsonData: Data,
        fetchedAt: Date = Date()
    ) throws -> QuotaAccountSnapshot {
        guard let envelope = decodeEnvelope(from: jsonData) else {
            throw QuotaError.invalidOutput("Antigravity 返回格式异常")
        }

        if let status = envelope.status, status.uppercased() != "SUCCESS" {
            let message = envelope.error?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? "Antigravity 查询返回错误状态（\(status)）"
            throw QuotaError.commandFailed(message)
        }

        guard let groups = envelope.command?.data?.groups, !groups.isEmpty else {
            throw QuotaError.invalidOutput("Antigravity 未返回模型额度分组")
        }

        let isoWithFractional = ISO8601DateFormatter()
        isoWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]

        let bucketIDCounts = Dictionary(grouping: groups.flatMap(\.buckets), by: \.id)
        var buckets: [QuotaBucket] = []
        var seenIDs: Set<String> = []
        for group in groups {
            let groupTitle = normalizeGroupName(group.name)
            // Order shorter rolling windows (5h) before weekly, matching the dashboard visual rhythm.
            let sortedBuckets = group.buckets.sorted { lhs, rhs in
                windowSortRank(lhs.window) < windowSortRank(rhs.window)
            }
            for rawBucket in sortedBuckets {
                let windowTitle = formatWindowTitle(rawBucket.window, fallbackName: rawBucket.name)
                let title = "\(groupTitle) · \(windowTitle)"
                let usedPercent = max(0, min(100, (1.0 - rawBucket.remaining_fraction) * 100.0))
                let parsedDate: Date?
                switch rawBucket.reset_time {
                case .epoch(let epoch): parsedDate = Date(timeIntervalSince1970: epoch)
                case .iso(let value): parsedDate = isoWithFractional.date(from: value) ?? isoBasic.date(from: value)
                case nil: parsedDate = nil
                }
                // Treat Unix epoch (1970-01-01) as "no active rolling window yet" (0% used).
                let validResetDate = parsedDate.flatMap { date -> Date? in
                    let epoch = date.timeIntervalSince1970
                    return epoch.isFinite && epoch > 86_400 ? date : nil
                }
                let windowMinutes: Int?
                switch rawBucket.window?.lowercased() {
                case "5h": windowMinutes = 300
                case "daily", "24h": windowMinutes = 1_440
                case "weekly", "7d": windowMinutes = 10_080
                default: windowMinutes = nil
                }
                let id = (bucketIDCounts[rawBucket.id]?.count ?? 0) > 1
                    ? "\(group.name).\(rawBucket.id)" : rawBucket.id
                guard seenIDs.insert(id).inserted else { continue }
                buckets.append(QuotaBucket(
                    id: id,
                    title: title,
                    usedPercent: usedPercent,
                    resetsAt: validResetDate,
                    windowMinutes: windowMinutes,
                    detail: group.description
                ))
            }
        }

        return QuotaAccountSnapshot(
            accountID: accountID,
            provider: .antigravity,
            accountEmail: nil,
            planLabel: nil,
            buckets: buckets,
            resetCreditsCount: nil,
            creditBalance: nil,
            fetchedAt: fetchedAt
        )
    }

    private static func normalizeGroupName(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("gemini") { return "Gemini" }
        if lower.contains("claude") && lower.contains("gpt") { return "Claude & GPT" }
        if lower.contains("claude") { return "Claude" }
        if lower.contains("gpt") { return "GPT" }
        return name
    }

    private static func windowSortRank(_ window: String?) -> Int {
        switch window?.lowercased() {
        case "5h": return 0
        case "daily", "24h": return 1
        case "weekly", "7d": return 2
        default: return 3
        }
    }

    private static func formatWindowTitle(_ window: String?, fallbackName: String?) -> String {
        switch window?.lowercased() {
        case "5h": return "5 小时"
        case "weekly", "7d": return "周"
        case "daily", "24h": return "日"
        default:
            if let fallbackName, !fallbackName.isEmpty { return fallbackName }
            return window ?? "额度"
        }
    }

    private static func decodeEnvelope(from data: Data) -> Envelope? {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(Envelope.self, from: data) { return envelope }
        let text = String(decoding: data, as: UTF8.self)
        // Accept a JSON object preceded by diagnostic log lines, including pretty-printed responses.
        let lines = text.split(whereSeparator: \.isNewline)
        for index in lines.indices {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("{") else { continue }
            let candidate = line.hasSuffix("}") ? line : lines[index...].joined(separator: "\n")
            if let envelope = try? decoder.decode(Envelope.self, from: Data(candidate.utf8)),
               envelope.command != nil || envelope.status != nil || envelope.error != nil {
                return envelope
            }
        }
        return nil
    }
}

enum DeepSeekQuotaParser {
    private struct BalanceResponse: Decodable {
        struct BalanceInfo: Decodable {
            let currency: String?
            let total_balance: String?
            let granted_balance: String?
            let topped_up_balance: String?
        }

        let is_available: Bool?
        let balance_infos: [BalanceInfo]?
    }

    private struct ErrorResponse: Decodable {
        struct Detail: Decodable {
            let message: String?
        }

        let error: Detail?
        let message: String?
    }

    static func endpoint(baseURL: String?) throws -> URL {
        let raw = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? QuotaProvider.deepseek.defaultBaseURL!
        guard var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            throw QuotaError.commandFailed("DeepSeek 接口地址无效，请检查自定义地址格式。")
        }
        let isLocalhost = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && isLocalhost) else {
            throw QuotaError.commandFailed("远程接口地址必须使用 HTTPS，本机地址可使用 HTTP。")
        }

        var path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.lowercased().hasSuffix("user/balance") {
            // Keep explicit full balance endpoint path.
        } else if path.lowercased() == "v1" {
            path = "user/balance"
        } else if path.isEmpty {
            path = "user/balance"
        } else {
            path = "\(path)/user/balance"
        }
        components.path = "/\(path)"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw QuotaError.commandFailed("DeepSeek 接口地址无效，请检查自定义地址格式。")
        }
        return url
    }

    static func parseErrorMessage(from data: Data) -> String? {
        guard let decoded = try? JSONDecoder().decode(ErrorResponse.self, from: data) else { return nil }
        return decoded.error?.message?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? decoded.message?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func parse(
        accountID: String,
        jsonData: Data,
        fetchedAt: Date = Date()
    ) throws -> QuotaAccountSnapshot {
        let decoded: BalanceResponse
        do {
            decoded = try JSONDecoder().decode(BalanceResponse.self, from: jsonData)
        } catch {
            throw QuotaError.invalidOutput("DeepSeek 返回格式异常")
        }

        guard let rawInfos = decoded.balance_infos, !rawInfos.isEmpty else {
            throw QuotaError.invalidOutput("DeepSeek 未返回余额信息")
        }

        var balances: [QuotaBalanceInfo] = []
        var seenCurrencies: Set<String> = []
        for info in rawInfos {
            guard let currency = info.currency?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty?.uppercased(),
                  let total = info.total_balance?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
                continue
            }
            guard seenCurrencies.insert(currency).inserted else { continue }
            balances.append(QuotaBalanceInfo(
                currency: currency,
                totalBalance: total,
                grantedBalance: info.granted_balance?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                toppedUpBalance: info.topped_up_balance?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ))
        }

        guard !balances.isEmpty else {
            throw QuotaError.invalidOutput("DeepSeek 余额字段缺失")
        }

        let summary = balances.map(\.formattedTotal).joined(separator: " · ")
        let planLabel: String?
        if let available = decoded.is_available {
            planLabel = available ? "余额可用" : "余额不足"
        } else {
            planLabel = nil
        }

        return QuotaAccountSnapshot(
            accountID: accountID,
            provider: .deepseek,
            accountEmail: nil,
            planLabel: planLabel,
            buckets: [],
            resetCreditsCount: nil,
            creditBalance: summary,
            fetchedAt: fetchedAt,
            balances: balances
        )
    }
}

enum GeminiQuotaParser {
    struct LoadCodeAssistInfo: Equatable, Sendable {
        let projectID: String?
        let planLabel: String?
    }

    private struct LoadCodeAssistEnvelope: Decodable {
        struct Tier: Decodable {
            let id: String?
            let name: String?
        }

        enum ProjectField: Decodable {
            case string(String)
            case object(String?)

            private enum CodingKeys: String, CodingKey { case id }

            init(from decoder: Decoder) throws {
                let single = try decoder.singleValueContainer()
                if let value = try? single.decode(String.self) {
                    self = .string(value)
                } else {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    self = .object(try container.decodeIfPresent(String.self, forKey: .id))
                }
            }

            var value: String? {
                switch self {
                case .string(let value): return value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                case .object(let value): return value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                }
            }
        }

        let cloudaicompanionProject: ProjectField?
        let currentTier: Tier?
        let paidTier: Tier?
    }

    private struct RetrieveUserQuotaEnvelope: Decodable {
        struct RawBucket: Decodable {
            let modelId: String?
            let tokenType: String?
            let remainingFraction: Double?
            let remainingAmount: String?
            let resetTime: ResetTime?
        }

        let resetTime: ResetTime?
        let buckets: [RawBucket]?
        let quotas: [RawBucket]?
    }

    private enum ResetTime: Decodable {
        case epoch(Double)
        case iso(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let epoch = try? container.decode(Double.self) {
                self = .epoch(epoch)
            } else {
                let string = try container.decode(String.self)
                self = Double(string).map(Self.epoch) ?? .iso(string)
            }
        }
    }

    private struct IDTokenClaims: Decodable {
        let email: String?
    }

    static func parseLoadCodeAssist(jsonData: Data) -> LoadCodeAssistInfo {
        guard let envelope = try? JSONDecoder().decode(LoadCodeAssistEnvelope.self, from: jsonData) else {
            return LoadCodeAssistInfo(projectID: nil, planLabel: nil)
        }
        let tierID = envelope.paidTier?.id?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? envelope.currentTier?.id?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let tierName = envelope.paidTier?.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? envelope.currentTier?.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        return LoadCodeAssistInfo(
            projectID: envelope.cloudaicompanionProject?.value,
            planLabel: formatTier(id: tierID, name: tierName)
        )
    }

    static func extractEmail(fromIDToken idToken: String?) -> String? {
        guard let idToken else { return nil }
        let segments = idToken.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: base64),
              let claims = try? JSONDecoder().decode(IDTokenClaims.self, from: data) else {
            return nil
        }
        return claims.email?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func parse(
        accountID: String,
        quotaJSON: Data,
        email: String? = nil,
        planLabel: String? = nil,
        fetchedAt: Date = Date()
    ) throws -> QuotaAccountSnapshot {
        let envelope: RetrieveUserQuotaEnvelope
        do {
            envelope = try JSONDecoder().decode(RetrieveUserQuotaEnvelope.self, from: quotaJSON)
        } catch {
            throw QuotaError.invalidOutput("Gemini 返回格式异常")
        }

        let rawBuckets = envelope.buckets ?? envelope.quotas ?? []
        guard !rawBuckets.isEmpty else {
            throw QuotaError.invalidOutput("Gemini 未返回模型额度分组")
        }

        let isoWithFractional = ISO8601DateFormatter()
        isoWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]

        func parseDate(_ resetTime: ResetTime?) -> Date? {
            let parsed: Date?
            switch resetTime {
            case .epoch(let value):
                let seconds = value > 10_000_000_000 ? value / 1000.0 : value
                parsed = Date(timeIntervalSince1970: seconds)
            case .iso(let value):
                parsed = isoWithFractional.date(from: value) ?? isoBasic.date(from: value)
            case nil:
                parsed = nil
            }
            return parsed.flatMap { date in
                let epoch = date.timeIntervalSince1970
                return epoch.isFinite && epoch > 86_400 ? date : nil
            }
        }

        let fallbackResetDate = parseDate(envelope.resetTime)

        struct MergedEntry {
            let normalizedID: String
            var remainingFraction: Double
            var resetDate: Date?
            var detail: String?
        }

        var byModel: [String: MergedEntry] = [:]
        for raw in rawBuckets {
            guard let modelID = raw.modelId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                  let fraction = raw.remainingFraction,
                  fraction.isFinite else {
                continue
            }
            let normalizedID = normalizeModelID(modelID)
            let clampedFraction = max(0, min(1, fraction))
            let resetDate = parseDate(raw.resetTime) ?? fallbackResetDate
            let detail = raw.remainingAmount?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

            if var existing = byModel[normalizedID] {
                if clampedFraction < existing.remainingFraction {
                    existing.remainingFraction = clampedFraction
                    existing.resetDate = resetDate ?? existing.resetDate
                    existing.detail = detail ?? existing.detail
                } else if clampedFraction == existing.remainingFraction {
                    if let candidate = resetDate,
                       existing.resetDate == nil || candidate < existing.resetDate! {
                        existing.resetDate = candidate
                    }
                }
                byModel[normalizedID] = existing
            } else {
                byModel[normalizedID] = MergedEntry(
                    normalizedID: normalizedID,
                    remainingFraction: clampedFraction,
                    resetDate: resetDate,
                    detail: detail
                )
            }
        }

        let sortedEntries = byModel.values.sorted { lhs, rhs in
            let leftRank = modelSortKey(lhs.normalizedID)
            let rightRank = modelSortKey(rhs.normalizedID)
            if leftRank != rightRank { return leftRank < rightRank }
            return lhs.normalizedID < rhs.normalizedID
        }

        guard !sortedEntries.isEmpty else {
            throw QuotaError.invalidOutput("Gemini 额度数据中没有有效的模型记录")
        }

        let buckets = sortedEntries.map { entry in
            QuotaBucket(
                id: entry.normalizedID,
                title: formatModelTitle(entry.normalizedID),
                usedPercent: max(0, min(100, (1.0 - entry.remainingFraction) * 100.0)),
                resetsAt: entry.resetDate,
                windowMinutes: nil,
                detail: entry.detail
            )
        }

        return QuotaAccountSnapshot(
            accountID: accountID,
            provider: .gemini,
            accountEmail: email?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            planLabel: planLabel?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            buckets: buckets,
            resetCreditsCount: nil,
            creditBalance: nil,
            fetchedAt: fetchedAt
        )
    }

    private static func normalizeModelID(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.hasSuffix("_vertex") {
            return String(lower.dropLast("_vertex".count))
        }
        return lower
    }

    private static func modelSortKey(_ id: String) -> (Int, Int, Int, String) {
        let familyRank: Int
        if id.contains("pro") {
            familyRank = 0
        } else if id.contains("flash-lite") || id.contains("lite") {
            familyRank = 2
        } else if id.contains("flash") {
            familyRank = 1
        } else {
            familyRank = 3
        }
        // Prefer higher Gemini version numbers first (e.g., 3.1 > 3.0 > 2.5 > 2.0).
        let versionScore = extractVersionScore(from: id)
        let previewPenalty = id.contains("preview") || id.contains("exp") ? 1 : 0
        return (-versionScore, familyRank, previewPenalty, id)
    }

    private static func extractVersionScore(from id: String) -> Int {
        let parts = id.split(separator: "-")
        for part in parts {
            let digits = part.split(separator: ".")
            if let major = digits.first.flatMap({ Int($0) }) {
                let minor = digits.count > 1 ? (Int(digits[1]) ?? 0) : 0
                return major * 100 + minor
            }
        }
        return 0
    }

    private static func formatModelTitle(_ id: String) -> String {
        let parts = id.split(separator: "-").map(String.init)
        return parts.map { token in
            switch token.lowercased() {
            case "gemini": return "Gemini"
            case "pro": return "Pro"
            case "flash": return "Flash"
            case "lite": return "Lite"
            case "ultra": return "Ultra"
            case "preview": return "Preview"
            case "exp": return "Exp"
            default:
                if token.first?.isNumber == true { return token }
                return token.prefix(1).uppercased() + token.dropFirst()
            }
        }.joined(separator: " ")
    }

    private static func formatTier(id: String?, name: String?) -> String? {
        if let id = id?.lowercased() {
            if id.contains("ultra") { return "AI Ultra" }
            if id.contains("pro") { return "AI Pro" }
            if id == "standard-tier" { return "Standard" }
            if id == "free-tier" { return "Free" }
            if id == "legacy-tier" { return "Legacy" }
        }
        if let name, !name.isEmpty {
            return name
        }
        return id
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
