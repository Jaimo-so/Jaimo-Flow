import Foundation

/// 时间组件里可添加的一个城市/时区。
public struct WorldClockCity: Hashable, Sendable, Identifiable {
    public let identifier: String
    public let name: String
    /// 用于搜索的别名：英文名、拼音、常用缩写等（小写）。
    public let aliases: [String]

    public var id: String { identifier }

    public init(identifier: String, name: String, aliases: [String] = []) {
        self.identifier = identifier
        self.name = name
        self.aliases = aliases
    }
}

/// 一个时区相对本地所在的日期：昨天、今天或明天。
public enum WorldClockDayRelation: Int, Sendable {
    case yesterday = -1
    case today = 0
    case tomorrow = 1

    public var label: String {
        switch self {
        case .yesterday: return "昨天"
        case .today: return "今天"
        case .tomorrow: return "明天"
        }
    }
}

/// 首页“时间”组件的多时区逻辑：城市名、UTC 偏移、与本地的时差、跨日提示与搜索。
/// 只依赖 Foundation，可在 Linux 上测试。
public enum WorldClock {
    /// 除本地时间外最多可添加的时区数。
    public static let maxExtraZones = 6

    /// 常用城市。第一个匹配同一时区标识的名称会被当作该时区的显示名。
    public static let catalog: [WorldClockCity] = [
        .init(identifier: "Asia/Shanghai", name: "上海", aliases: ["shanghai", "beijing", "北京", "china", "中国", "cst", "bj", "sh"]),
        .init(identifier: "Asia/Hong_Kong", name: "香港", aliases: ["hong kong", "hongkong", "xianggang", "hk"]),
        .init(identifier: "Asia/Taipei", name: "台北", aliases: ["taipei", "taibei", "台湾", "taiwan"]),
        .init(identifier: "Asia/Tokyo", name: "东京", aliases: ["tokyo", "dongjing", "日本", "japan", "jst"]),
        .init(identifier: "Asia/Seoul", name: "首尔", aliases: ["seoul", "shouer", "韩国", "korea", "kst"]),
        .init(identifier: "Asia/Singapore", name: "新加坡", aliases: ["singapore", "xinjiapo", "sg"]),
        .init(identifier: "Asia/Bangkok", name: "曼谷", aliases: ["bangkok", "mangu", "泰国", "thailand"]),
        .init(identifier: "Asia/Kolkata", name: "新德里", aliases: ["new delhi", "delhi", "mumbai", "孟买", "印度", "india", "ist", "xindeli"]),
        .init(identifier: "Asia/Dubai", name: "迪拜", aliases: ["dubai", "dibai", "阿联酋", "uae"]),
        .init(identifier: "Europe/Moscow", name: "莫斯科", aliases: ["moscow", "mosike", "俄罗斯", "russia"]),
        .init(identifier: "Europe/Berlin", name: "柏林", aliases: ["berlin", "bolin", "德国", "germany", "cet"]),
        .init(identifier: "Europe/Paris", name: "巴黎", aliases: ["paris", "bali", "法国", "france"]),
        .init(identifier: "Europe/London", name: "伦敦", aliases: ["london", "lundun", "英国", "uk", "gmt", "bst"]),
        .init(identifier: "UTC", name: "UTC", aliases: ["utc", "gmt", "协调世界时", "世界标准时间"]),
        .init(identifier: "America/Sao_Paulo", name: "圣保罗", aliases: ["sao paulo", "shengbaoluo", "巴西", "brazil"]),
        .init(identifier: "America/Argentina/Buenos_Aires", name: "布宜诺斯艾利斯", aliases: ["buenos aires", "阿根廷", "argentina", "buyinuosiailisi", "ba"]),
        .init(identifier: "America/Argentina/Catamarca", name: "卡塔马卡", aliases: ["catamarca", "katamaka"]),
        .init(identifier: "America/New_York", name: "纽约", aliases: ["new york", "niuyue", "nyc", "美东", "est", "edt", "et"]),
        .init(identifier: "America/Toronto", name: "多伦多", aliases: ["toronto", "duolunduo", "加拿大", "canada"]),
        .init(identifier: "America/Chicago", name: "芝加哥", aliases: ["chicago", "zhijiage", "美中", "cdt"]),
        .init(identifier: "America/Denver", name: "丹佛", aliases: ["denver", "danfo", "美山地", "mst", "mdt"]),
        .init(identifier: "America/Los_Angeles", name: "洛杉矶", aliases: ["los angeles", "luoshanji", "旧金山", "san francisco", "硅谷", "美西", "pst", "pdt", "la", "sf"]),
        .init(identifier: "Pacific/Honolulu", name: "檀香山", aliases: ["honolulu", "夏威夷", "hawaii"]),
        .init(identifier: "Australia/Sydney", name: "悉尼", aliases: ["sydney", "xini", "澳大利亚", "australia", "aest"]),
        .init(identifier: "Pacific/Auckland", name: "奥克兰", aliases: ["auckland", "aokelan", "新西兰", "new zealand", "nz"])
    ]

    /// 时区的中文显示名；不在常用列表里时取标识的最后一段（如 `America/Argentina/Salta` → `Salta`）。
    public static func cityName(for identifier: String) -> String {
        if let city = catalog.first(where: { $0.identifier == identifier }) { return city.name }
        if identifier == "Asia/Chongqing" || identifier == "Asia/Harbin" || identifier == "PRC" { return "北京" }
        let last = identifier.split(separator: "/").last.map(String.init) ?? identifier
        return last.replacingOccurrences(of: "_", with: " ")
    }

    /// `UTC+8`、`UTC−3`、`UTC+5:30`，零偏移为 `UTC`。
    public static func utcOffsetText(_ zone: TimeZone, at date: Date) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        guard seconds != 0 else { return "UTC" }
        let sign = seconds > 0 ? "+" : "−"
        let minutes = abs(seconds) / 60
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "UTC\(sign)\(hours)" : String(format: "UTC%@%d:%02d", sign, hours, rest)
    }

    /// 与本地时区的时差描述，例如“快 11 小时”“慢 2 小时 30 分”“与本地相同”。
    public static func differenceText(of zone: TimeZone, relativeTo base: TimeZone, at date: Date) -> String {
        let delta = zone.secondsFromGMT(for: date) - base.secondsFromGMT(for: date)
        guard delta != 0 else { return "与本地相同" }
        let minutes = abs(delta) / 60
        let hours = minutes / 60
        let rest = minutes % 60
        var amount = ""
        if hours > 0 { amount += "\(hours) 小时" }
        if rest > 0 { amount += (amount.isEmpty ? "" : " ") + "\(rest) 分" }
        return (delta > 0 ? "快 " : "慢 ") + amount
    }

    /// 该时区当前日期相对本地日期是昨天、今天还是明天。
    public static func dayRelation(of zone: TimeZone, relativeTo base: TimeZone, at date: Date) -> WorldClockDayRelation {
        let zoneDay = dayNumber(of: date, in: zone)
        let baseDay = dayNumber(of: date, in: base)
        let difference = max(-1, min(1, zoneDay - baseDay))
        return WorldClockDayRelation(rawValue: difference) ?? .today
    }

    /// 24 小时制的 `HH:mm`。
    public static func timeText(at date: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// 复制到剪贴板的一行文字，例如 `东京 11月20日 周五 01:05（UTC+9）`。
    public static func copyText(identifier: String, at date: Date) -> String? {
        guard let zone = TimeZone(identifier: identifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.month, .day, .weekday], from: date)
        let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let weekday = weekdays[((parts.weekday ?? 1) - 1 + 7) % 7]
        return "\(cityName(for: identifier)) \(parts.month ?? 0)月\(parts.day ?? 0)日 \(weekday) \(timeText(at: date, in: zone))（\(utcOffsetText(zone, at: date))）"
    }

    /// 清理保存的时区列表：去掉无效标识、重复项和与本地相同的标识，并限制数量。
    public static func normalizedZones(_ identifiers: [String], localIdentifier: String? = nil) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in identifiers {
            let identifier = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty,
                  identifier != localIdentifier,
                  TimeZone(identifier: identifier) != nil,
                  seen.insert(identifier).inserted
            else { continue }
            result.append(identifier)
            if result.count == maxExtraZones { break }
        }
        return result
    }

    /// 在列表末尾添加一个时区；已存在、无效、与本地相同或已满时返回 nil。
    public static func adding(_ identifier: String, to identifiers: [String], localIdentifier: String? = nil) -> [String]? {
        let current = normalizedZones(identifiers, localIdentifier: localIdentifier)
        guard current.count < maxExtraZones,
              !current.contains(identifier),
              identifier != localIdentifier,
              TimeZone(identifier: identifier) != nil
        else { return nil }
        return current + [identifier]
    }

    /// 搜索可添加的时区。空查询返回常用城市；会排除 `excluding` 中的标识。
    /// 常用城市按名称/别名匹配优先，其后补充系统时区标识中的匹配项。
    public static func search(_ query: String, excluding: Set<String> = [], limit: Int = 12) -> [WorldClockCity] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidates = catalog.filter { !excluding.contains($0.identifier) }
        guard !needle.isEmpty else { return Array(candidates.prefix(limit)) }

        let compactNeedle = needle.replacingOccurrences(of: " ", with: "")
        func score(_ city: WorldClockCity) -> Int? {
            let names = [city.name.lowercased()] + city.aliases
            if names.contains(needle) { return 0 }
            if names.contains(where: { $0.hasPrefix(needle) || $0.replacingOccurrences(of: " ", with: "").hasPrefix(compactNeedle) }) { return 1 }
            if names.contains(where: { $0.contains(needle) }) { return 2 }
            if city.identifier.lowercased().contains(compactNeedle) { return 3 }
            return nil
        }
        var results = candidates
            .compactMap { city in score(city).map { (city, $0) } }
            .enumerated()
            .sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }
            .map(\.element.0)

        if results.count < limit, compactNeedle.count >= 2 {
            let known = Set(results.map(\.identifier)).union(excluding)
            let underscored = needle.replacingOccurrences(of: " ", with: "_")
            let extra = TimeZone.knownTimeZoneIdentifiers
                .filter { identifier in
                    guard !known.contains(identifier) else { return false }
                    let lower = identifier.lowercased()
                    return lower.contains(underscored) || lower.replacingOccurrences(of: "_", with: "").contains(compactNeedle)
                }
                .sorted()
                .map { WorldClockCity(identifier: $0, name: cityName(for: $0)) }
            results.append(contentsOf: extra)
        }
        return Array(results.prefix(limit))
    }

    private static func dayNumber(of date: Date, in zone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let midnight = utc.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day)) ?? date
        return Int((midnight.timeIntervalSince1970 / 86_400).rounded(.down))
    }
}
