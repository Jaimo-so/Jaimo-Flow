import Foundation

/// 剪切板历史的搜索语法。
///
/// - 空格分隔多个关键词，全部命中才显示（与之前整串匹配相比，词序不再重要）
/// - `"多个 词"` 或 `“多个 词”`：按整段短语匹配
/// - `-词`：排除包含该词的记录
/// - `app:微信` / `来源:微信` / `from:微信`：按来源应用过滤，多个来源取并集
/// - `date:今天` / `时间:昨天` / `time:7天`：按复制日期过滤，支持 今天、昨天、前天、N天 / Nd（最近 N 天）、
///   本周、本月，以及 `2026-11-20` / `11-20` 这样的具体日期
/// - `is:代码` / `类型:链接`：按类型过滤，支持 文字、代码、链接、图片、收藏
///
/// 无法识别的过滤值会按普通关键词处理，避免用户输入被悄悄忽略。
public struct ClipSearchQuery: Equatable, Sendable {
    public enum DateRange: Equatable, Sendable {
        /// 包含 start，不包含 end。
        case between(start: Date, end: Date)
    }

    public enum KindFilter: String, Equatable, Sendable {
        case text, code, link, image, favorite

        public var title: String {
            switch self {
            case .text: return "文字"
            case .code: return "代码"
            case .link: return "链接"
            case .image: return "图片"
            case .favorite: return "收藏"
            }
        }
    }

    public var terms: [String] = []
    public var excludedTerms: [String] = []
    public var sourceApps: [String] = []
    public var dateRanges: [DateRange] = []
    public var dateLabels: [String] = []
    public var kinds: [KindFilter] = []

    public init() {}

    public var isEmpty: Bool {
        terms.isEmpty && excludedTerms.isEmpty && sourceApps.isEmpty && dateRanges.isEmpty && kinds.isEmpty
    }

    /// 是否使用了关键词以外的过滤条件，用于在界面中展示“已生效的筛选”。
    public var hasStructuredFilters: Bool {
        !excludedTerms.isEmpty || !sourceApps.isEmpty || !dateRanges.isEmpty || !kinds.isEmpty
    }

    /// 已生效筛选条件的中文摘要，例如 “来源：微信 · 时间：今天 · 排除：广告”。
    public var summary: String {
        var parts: [String] = []
        if !terms.isEmpty { parts.append("关键词：" + terms.joined(separator: "、")) }
        if !sourceApps.isEmpty { parts.append("来源：" + sourceApps.joined(separator: " 或 ")) }
        if !dateLabels.isEmpty { parts.append("时间：" + dateLabels.joined(separator: " 或 ")) }
        if !kinds.isEmpty { parts.append("类型：" + kinds.map(\.title).joined(separator: " 或 ")) }
        if !excludedTerms.isEmpty { parts.append("排除：" + excludedTerms.joined(separator: "、")) }
        return parts.joined(separator: " · ")
    }

    public static func parse(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> ClipSearchQuery {
        var query = ClipSearchQuery()
        for token in tokenize(raw) {
            if token.quoted {
                let phrase = token.text.lowercased()
                if !phrase.isEmpty { query.terms.append(phrase) }
                continue
            }
            let text = token.text
            if text.count > 1, text.hasPrefix("-") || text.hasPrefix("－") {
                query.excludedTerms.append(String(text.dropFirst()).lowercased())
                continue
            }
            if let (key, value) = splitFilter(text) {
                switch key {
                case "app", "from", "来源", "应用":
                    query.sourceApps.append(value.lowercased())
                    continue
                case "date", "time", "时间", "日期":
                    if let range = dateRange(for: value, now: now, calendar: calendar) {
                        query.dateRanges.append(range)
                        query.dateLabels.append(value)
                        continue
                    }
                case "is", "type", "类型":
                    if let kind = kindFilter(for: value) {
                        if !query.kinds.contains(kind) { query.kinds.append(kind) }
                        continue
                    }
                default:
                    break
                }
            }
            query.terms.append(text.lowercased())
        }
        return query
    }

    public func matches(_ item: ClipItem) -> Bool {
        if !sourceApps.isEmpty {
            let source = item.sourceAppName.lowercased()
            let bundle = item.sourceBundleID.lowercased()
            guard sourceApps.contains(where: { source.contains($0) || bundle.contains($0) }) else { return false }
        }
        if !dateRanges.isEmpty {
            guard dateRanges.contains(where: { range in
                switch range {
                case .between(let start, let end): return item.copiedAt >= start && item.copiedAt < end
                }
            }) else { return false }
        }
        if !kinds.isEmpty {
            guard kinds.contains(where: { kind in
                switch kind {
                case .text: return item.kind == .text
                case .code: return item.kind == .code
                case .link: return item.kind == .link
                case .image: return item.kind == .image
                case .favorite: return item.isFavorite
                }
            }) else { return false }
        }
        guard !terms.isEmpty || !excludedTerms.isEmpty else { return true }
        let haystack = [item.title, item.sourceAppName, item.fullText ?? "", item.imageAlt ?? ""]
            .joined(separator: "\n")
            .lowercased()
        for term in terms where !haystack.contains(term) { return false }
        for term in excludedTerms where haystack.contains(term) { return false }
        return true
    }

    // MARK: - Parsing helpers

    struct Token: Equatable {
        var text: String
        var quoted: Bool
    }

    static func tokenize(_ raw: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var closingQuote: Character?
        var currentQuoted = false

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty || currentQuoted && !current.isEmpty {
                tokens.append(Token(text: currentQuoted ? current : trimmed, quoted: currentQuoted))
            }
            current = ""
            currentQuoted = false
        }

        for character in raw {
            if let closing = closingQuote {
                if character == closing {
                    closingQuote = nil
                    flush()
                } else {
                    current.append(character)
                }
                continue
            }
            let pairs: [Character: Character] = ["\"": "\"", "“": "”", "「": "」"]
            if let closing = pairs[character] {
                // app:"Google Chrome"：引号属于过滤值，整个 token 仍按过滤条件解析。
                if current.hasSuffix(":") || current.hasSuffix("：") {
                    closingQuote = closing
                } else {
                    flush(); closingQuote = closing; currentQuoted = true
                }
            } else if character.isWhitespace {
                flush()
            } else {
                current.append(character)
            }
        }
        // 未闭合的引号：把已输入的内容当作短语，输入过程中结果不会突然变空。
        flush()
        return tokens
    }

    static func splitFilter(_ text: String) -> (String, String)? {
        guard let index = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return nil }
        let key = text[..<index].lowercased()
        let value = String(text[text.index(after: index)...])
        guard !key.isEmpty, !value.isEmpty else { return nil }
        return (key, value)
    }

    static func kindFilter(for value: String) -> KindFilter? {
        switch value.lowercased() {
        case "text", "文字", "文本": return .text
        case "code", "代码": return .code
        case "link", "url", "链接": return .link
        case "image", "img", "图片": return .image
        case "fav", "favorite", "star", "收藏": return .favorite
        default: return nil
        }
    }

    static func dateRange(for raw: String, now: Date, calendar: Calendar) -> DateRange? {
        let value = raw.lowercased()
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date? { calendar.date(byAdding: .day, value: offset, to: today) }
        func single(_ start: Date?) -> DateRange? {
            guard let start, let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            return .between(start: start, end: end)
        }
        guard let tomorrow = day(1) else { return nil }

        switch value {
        case "今天", "today": return single(today)
        case "昨天", "yesterday": return single(day(-1))
        case "前天": return single(day(-2))
        case "本周", "这周", "week":
            guard let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return nil }
            return .between(start: start, end: tomorrow)
        case "本月", "这个月", "month":
            guard let start = calendar.dateInterval(of: .month, for: now)?.start else { return nil }
            return .between(start: start, end: tomorrow)
        default:
            break
        }

        // 最近 N 天：7天 / 7d / 7 天内，包含今天。
        var digits = value
        for suffix in ["天内", "天", "d"] where digits.hasSuffix(suffix) {
            digits = String(digits.dropLast(suffix.count))
            if let count = Int(digits), count > 0, count <= 3_650, let start = day(-(count - 1)) {
                return .between(start: start, end: tomorrow)
            }
            return nil
        }

        // 具体日期：2026-11-20、2026/11/20、11-20、11/20、11月20日。
        let normalized = value
            .replacingOccurrences(of: "年", with: "-")
            .replacingOccurrences(of: "月", with: "-")
            .replacingOccurrences(of: "日", with: "")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let parts = normalized.split(separator: "-", omittingEmptySubsequences: true).compactMap { Int($0) }
        guard parts.count == normalized.split(separator: "-").count else { return nil }
        var components = DateComponents()
        switch parts.count {
        case 3:
            components.year = parts[0]; components.month = parts[1]; components.day = parts[2]
        case 2:
            components.year = calendar.component(.year, from: now)
            components.month = parts[0]; components.day = parts[1]
        default:
            return nil
        }
        guard let month = components.month, (1...12).contains(month),
              let dayValue = components.day, (1...31).contains(dayValue),
              let date = calendar.date(from: components),
              calendar.component(.day, from: date) == dayValue else { return nil }
        return single(calendar.startOfDay(for: date))
    }
}

/// 剪切板历史按复制日期分组，用于在列表中插入“今天 / 昨天 / 11月18日 周三”这样的小标题。
public struct ClipDaySection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let items: [ClipItem]

    public static func group(_ items: [ClipItem], now: Date = Date(), calendar: Calendar = .current) -> [ClipDaySection] {
        var sections: [ClipDaySection] = []
        var currentKey: String?
        var currentTitle = ""
        var buffer: [ClipItem] = []
        var usedKeys: [String: Int] = [:]

        func flush() {
            guard let key = currentKey, !buffer.isEmpty else { return }
            // 收藏等因素可能让同一天分成多段，保证 id 唯一。
            let count = usedKeys[key, default: 0]
            usedKeys[key] = count + 1
            sections.append(ClipDaySection(id: count == 0 ? key : "\(key)#\(count)", title: currentTitle, items: buffer))
            buffer = []
        }

        for item in items {
            let start = calendar.startOfDay(for: item.copiedAt)
            let parts = calendar.dateComponents([.year, .month, .day], from: start)
            let key = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            if key != currentKey {
                flush()
                currentKey = key
                currentTitle = title(for: start, now: now, calendar: calendar)
            }
            buffer.append(item)
        }
        flush()
        return sections
    }

    public static func title(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let offset = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if offset == 0 { return "今天" }
        if offset == 1 { return "昨天" }
        let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
        let weekday = weekdays[((parts.weekday ?? 1) - 1 + 7) % 7]
        let month = parts.month ?? 0
        let dayOfMonth = parts.day ?? 0
        if parts.year == calendar.component(.year, from: now) {
            return "\(month)月\(dayOfMonth)日 \(weekday)"
        }
        return "\(parts.year ?? 0)年\(month)月\(dayOfMonth)日 \(weekday)"
    }
}

public extension ClipSearchQuery {
    /// 把搜索框中的来源条件替换为指定应用，保留其余关键词与过滤条件。
    static func replacingSourceFilter(in raw: String, with appName: String) -> String {
        let name = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceKeys: Set<String> = ["app", "from", "来源", "应用"]
        let kept = tokenize(raw).compactMap { token -> String? in
            if token.quoted { return "\"\(token.text)\"" }
            if let (key, _) = splitFilter(token.text), sourceKeys.contains(key) { return nil }
            return token.text
        }
        guard !name.isEmpty else { return kept.joined(separator: " ") }
        let value = name.contains(where: \.isWhitespace) ? "\"\(name)\"" : name
        return (kept + ["app:" + value]).joined(separator: " ")
    }
}
