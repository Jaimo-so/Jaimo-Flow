import ClipFlowKit
import Foundation

/// 剪切板搜索语法与按日分组的自测，返回通过的检查数。
func testClipSearchQuery() throws -> Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Argentina/Catamarca")!
    calendar.firstWeekday = 2
    // 2026-11-21 10:00（周六）
    let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 10))!
    func at(_ month: Int, _ day: Int, _ hour: Int = 12, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
    func item(
        _ id: Int64, _ text: String, app: String = "微信", kind: ClipKind = .text,
        date: Date, favorite: Bool = false
    ) -> ClipItem {
        ClipItem(
            id: id, kind: kind, category: kind == .image ? .image : kind == .link ? .link : .text,
            isFavorite: favorite, sourceAppName: app, sourceBundleID: "com.example.\(id)",
            copiedAt: date, title: text, fullText: text, meta: [], contentHash: "\(id)"
        )
    }
    let items = [
        item(1, "会议纪要 周五 下午三点", app: "飞书", date: at(11, 21, 9)),
        item(2, "func search() { return }", app: "Xcode", kind: .code, date: at(11, 21, 0, year: 2026)),
        item(3, "https://github.com/Jaimo-so/Jaimo-Flow", app: "Google Chrome", kind: .link, date: at(11, 20, 23)),
        item(4, "午饭吃什么 广告推广", app: "微信", date: at(11, 19), favorite: true),
        item(5, "旧的会议纪要", app: "飞书", date: at(11, 10)),
        item(6, "去年的笔记", app: "备忘录", date: at(12, 30, year: 2025))
    ]
    func ids(_ raw: String) -> [Int64] {
        let query = ClipSearchQuery.parse(raw, now: now, calendar: calendar)
        return items.filter(query.matches).map(\.id)
    }
    var checks = 0
    func expect(_ raw: String, _ expected: [Int64]) throws {
        let actual = ids(raw)
        try require(actual == expected, "搜索「\(raw)」应命中 \(expected)，实际 \(actual)")
        checks += 1
    }

    try expect("", [1, 2, 3, 4, 5, 6])
    try expect("会议 纪要", [1, 5])                         // 多关键词 AND，不要求相邻
    try expect("纪要 会议", [1, 5])                         // 词序无关
    try expect("\"周五 下午\"", [1])                         // 引号短语
    try expect("“周五下午”", [])                             // 中文引号短语需原样相邻
    try expect("会议 -旧的", [1])                           // 排除
    try expect("app:飞书", [1, 5])
    try expect("来源：飞书 旧", [5])                         // 全角冒号 + 关键词
    try expect("app:chrome", [3])                          // 大小写不敏感
    try expect("app:\"Google Chrome\"", [3])               // 带空格的来源
    try expect("app:飞书 app:xcode", [1, 2, 5])             // 多个来源取并集
    try expect("date:今天", [1, 2])                         // 今天 00:00 也算今天
    try expect("时间:昨天", [3])
    try expect("date:3天", [1, 2, 3, 4])
    try expect("date:7d app:飞书", [1])
    try expect("date:本月", [1, 2, 3, 4, 5])
    try expect("date:本周", [1, 2, 3, 4])                   // 周一 11-16 起
    try expect("date:11-10", [5])
    try expect("date:2025-12-30", [6])
    try expect("date:11月20日", [3])
    try expect("is:代码", [2])
    try expect("类型:收藏", [4])
    try expect("is:链接 is:代码", [2, 3])
    try expect("date:明天", [])                              // 无法识别的日期按普通关键词搜索
    try expect("is:视频", [])
    try expect("-", [3])                                  // 单独的减号是普通关键词
    try expect("Jaimo-Flow", [3])                          // 词中间的减号不当作排除

    let parsed = ClipSearchQuery.parse("会议 app:飞书 date:今天 -旧 is:代码", now: now, calendar: calendar)
    try require(parsed.hasStructuredFilters, "带过滤条件的搜索应标记为结构化筛选")
    try require(
        parsed.summary == "关键词：会议 · 来源：飞书 · 时间：今天 · 类型：代码 · 排除：旧",
        "筛选摘要不正确：\(parsed.summary)"
    )
    try require(!ClipSearchQuery.parse("会议 纪要").hasStructuredFilters, "纯关键词不应显示筛选条")
    checks += 3

    try require(
        ClipSearchQuery.replacingSourceFilter(in: "会议 app:微信 date:今天", with: "飞书") == "会议 date:今天 app:飞书",
        "替换来源条件时应保留其他条件"
    )
    try require(
        ClipSearchQuery.replacingSourceFilter(in: "\"周五 下午\"", with: "Google Chrome") == "\"周五 下午\" app:\"Google Chrome\"",
        "带空格的来源应加引号，并保留短语"
    )
    checks += 2

    let sections = ClipDaySection.group(items, now: now, calendar: calendar)
    try require(sections.map(\.title) == ["今天", "昨天", "11月19日 周四", "11月10日 周二", "2025年12月30日 周二"],
                "按日分组标题不正确：\(sections.map(\.title))")
    try require(sections.map { $0.items.map(\.id) } == [[1, 2], [3], [4], [5], [6]], "按日分组内容不正确")
    let interleaved = ClipDaySection.group([items[0], items[2], items[1]], now: now, calendar: calendar)
    try require(Set(interleaved.map(\.id)).count == interleaved.count, "同一天分成多段时 id 应唯一")
    checks += 3
    return checks
}
