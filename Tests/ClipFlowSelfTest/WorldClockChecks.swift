import ClipFlowKit
import Foundation

/// 首页“时间”组件多时区逻辑的检查。返回检查条数，便于在汇总里计数。
func runWorldClockChecks() throws -> Int {
    var checks = 0
    func expect(_ condition: Bool, _ message: String) throws {
        checks += 1
        try require(condition, message)
    }
    func zone(_ identifier: String) throws -> TimeZone {
        guard let zone = TimeZone(identifier: identifier) else { throw SelfTestError.failed("缺少时区 \(identifier)") }
        return zone
    }

    // 2026-11-19 12:00 UTC 与 2026-11-19 23:30 UTC
    let noon = Date(timeIntervalSince1970: 1_795_089_600)
    let lateNight = noon.addingTimeInterval(11.5 * 3_600)
    // 2026-07-01 12:00 UTC（北半球夏令时）
    let summer = Date(timeIntervalSince1970: 1_782_907_200)

    let shanghai = try zone("Asia/Shanghai")
    let catamarca = try zone("America/Argentina/Catamarca")
    let tokyo = try zone("Asia/Tokyo")
    let newYork = try zone("America/New_York")
    let kolkata = try zone("Asia/Kolkata")
    let losAngeles = try zone("America/Los_Angeles")

    try expect(WorldClock.cityName(for: "Asia/Shanghai") == "上海", "上海时区名称错误")
    try expect(WorldClock.cityName(for: "America/Argentina/Catamarca") == "卡塔马卡", "卡塔马卡时区名称错误")
    try expect(WorldClock.cityName(for: "America/Argentina/Salta") == "Salta", "未收录时区应取标识最后一段")
    try expect(WorldClock.cityName(for: "America/Port_of_Spain") == "Port of Spain", "未收录时区应把下划线换成空格")

    try expect(WorldClock.utcOffsetText(shanghai, at: noon) == "UTC+8", "上海 UTC 偏移错误")
    try expect(WorldClock.utcOffsetText(catamarca, at: noon) == "UTC−3", "卡塔马卡 UTC 偏移错误")
    try expect(WorldClock.utcOffsetText(kolkata, at: noon) == "UTC+5:30", "半小时时区偏移错误")
    try expect(WorldClock.utcOffsetText(try zone("UTC"), at: noon) == "UTC", "零偏移应显示 UTC")
    try expect(WorldClock.utcOffsetText(newYork, at: noon) == "UTC−5", "纽约冬令时偏移错误")
    try expect(WorldClock.utcOffsetText(newYork, at: summer) == "UTC−4", "纽约夏令时偏移错误")

    try expect(WorldClock.differenceText(of: shanghai, relativeTo: catamarca, at: noon) == "快 11 小时", "上海相对卡塔马卡时差错误")
    try expect(WorldClock.differenceText(of: newYork, relativeTo: catamarca, at: noon) == "慢 2 小时", "纽约相对卡塔马卡时差错误")
    try expect(WorldClock.differenceText(of: kolkata, relativeTo: shanghai, at: noon) == "慢 2 小时 30 分", "半小时时差错误")
    try expect(WorldClock.differenceText(of: shanghai, relativeTo: shanghai, at: noon) == "与本地相同", "相同时区时差错误")

    try expect(WorldClock.timeText(at: noon, in: shanghai) == "20:00", "上海时间格式错误")
    try expect(WorldClock.timeText(at: noon, in: catamarca) == "09:00", "卡塔马卡时间格式错误")
    try expect(WorldClock.dayRelation(of: tokyo, relativeTo: catamarca, at: noon) == .today, "同一天应为今天")
    try expect(WorldClock.dayRelation(of: tokyo, relativeTo: catamarca, at: lateNight) == .tomorrow, "东京已跨日应为明天")
    try expect(WorldClock.dayRelation(of: losAngeles, relativeTo: tokyo, at: lateNight) == .yesterday, "洛杉矶相对东京应为昨天")
    try expect(WorldClock.dayRelation(of: tokyo, relativeTo: catamarca, at: lateNight).label == "明天", "跨日标签错误")

    try expect(WorldClock.copyText(identifier: "Asia/Tokyo", at: lateNight) == "东京 11月20日 周五 08:30（UTC+9）", "复制文本格式错误")
    try expect(WorldClock.copyText(identifier: "Not/AZone", at: noon) == nil, "无效时区不应生成复制文本")

    let normalized = WorldClock.normalizedZones(
        ["Asia/Tokyo", " Asia/Tokyo ", "Bad/Zone", "", "America/Argentina/Catamarca", "Europe/London"],
        localIdentifier: "America/Argentina/Catamarca"
    )
    try expect(normalized == ["Asia/Tokyo", "Europe/London"], "应去掉重复、无效和本地时区")
    let many = WorldClock.catalog.map(\.identifier)
    try expect(WorldClock.normalizedZones(many).count == WorldClock.maxExtraZones, "时区数量应有上限")
    try expect(WorldClock.adding("Asia/Tokyo", to: ["Asia/Shanghai"]) == ["Asia/Shanghai", "Asia/Tokyo"], "添加时区失败")
    try expect(WorldClock.adding("Asia/Shanghai", to: ["Asia/Shanghai"]) == nil, "重复时区不应再次添加")
    try expect(WorldClock.adding("Asia/Tokyo", to: [], localIdentifier: "Asia/Tokyo") == nil, "本地时区不应作为附加时区")
    try expect(WorldClock.adding("Europe/Paris", to: Array(many.prefix(WorldClock.maxExtraZones))) == nil, "已满时不应添加")

    try expect(WorldClock.catalog.allSatisfy { TimeZone(identifier: $0.identifier) != nil }, "常用城市里不应有无效时区")
    try expect(Set(WorldClock.catalog.map(\.identifier)).count == WorldClock.catalog.count, "常用城市不应重复")
    try expect(WorldClock.search("").count == 12, "空搜索应返回常用城市")
    try expect(WorldClock.search("东京").first?.identifier == "Asia/Tokyo", "中文名搜索失败")
    try expect(WorldClock.search("北京").first?.identifier == "Asia/Shanghai", "别名搜索应找到上海时区")
    try expect(WorldClock.search("new york").first?.identifier == "America/New_York", "英文名搜索失败")
    try expect(WorldClock.search("NIUYUE").first?.identifier == "America/New_York", "拼音搜索应忽略大小写")
    try expect(WorldClock.search("硅谷").first?.identifier == "America/Los_Angeles", "地区别名搜索失败")
    try expect(!WorldClock.search("东京", excluding: ["Asia/Tokyo"]).contains { $0.identifier == "Asia/Tokyo" }, "已添加的时区应被排除")
    try expect(WorldClock.search("salta").first?.identifier == "America/Argentina/Salta", "应能搜到系统时区标识")
    try expect(WorldClock.search("port of spain").first?.identifier == "America/Port_of_Spain", "带空格的系统时区搜索失败")
    try expect(WorldClock.search("zzzz-none").isEmpty, "无匹配时应为空")

    return checks
}
