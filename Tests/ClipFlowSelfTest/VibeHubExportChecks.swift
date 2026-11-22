import ClipFlowKit
import Foundation

/// Vibehub Markdown export and similar-phrase detection. Returns the number of checks run.
func runVibeHubExportChecks() throws -> Int {
    var checks = 0
    func check(_ condition: Bool, _ message: String) throws {
        try require(condition, message)
        checks += 1
    }
    let utc = TimeZone(identifier: "UTC")!
    let date = Date(timeIntervalSince1970: 1_795_000_000) // 2026-11-18 11:06 UTC
    func phrase(_ id: String, _ title: String, _ text: String, category: String = "路由与导航",
                tags: String = "", scenario: String = "", meaning: String = "", favorite: Bool = false) -> VibeHubPhraseSnapshot {
        VibeHubPhraseSnapshot(id: id, title: title, phrase: text, category: category, tags: tags,
                              scenario: scenario, meaning: meaning, isFavorite: favorite, updatedAt: date)
    }

    try check(VibeHubMarkdown.tags(from: "哈希路由、页面切换, Router；router\n /浏览器历史 ") == ["哈希路由", "页面切换", "Router", "浏览器历史"],
              "标签拆分或去重错误")

    let routing = phrase("a", "页面切换与哈希路由", "给各个页面加上哈希路由。\n支持前进后退。",
                         tags: "哈希路由、页面切换", scenario: "多页面网站", meaning: "# 后面的片段表示页面", favorite: true)
    let section = VibeHubMarkdown.section(routing)
    try check(section.hasPrefix("### 页面切换与哈希路由 ★\n\n分类：路由与导航 · 标签：`哈希路由` `页面切换`"), "单条话术标题或元信息格式错误")
    try check(section.contains("```text\n给各个页面加上哈希路由。\n支持前进后退。\n```"), "话术原文未完整放入代码块")
    try check(section.contains("**适用场景**\n\n多页面网站") && section.contains("**术语与含义**\n\n# 后面的片段表示页面"),
              "适用场景或术语含义缺失")

    let bare = VibeHubMarkdown.section(phrase("b", "  ", ""))
    try check(bare.hasPrefix("### 无标题话术\n") && bare.contains("_（话术原文为空）_")
              && !bare.contains("适用场景") && !bare.contains("标签："), "空字段未省略或无标题未兜底")

    let fenced = VibeHubMarkdown.fenced("用 ```swift 包住代码，再加 ````")
    try check(fenced.hasPrefix("`````text\n") && fenced.hasSuffix("\n`````"), "原文含反引号时代码块被提前截断")

    let ui = phrase("c", "统一间距", "把卡片间距统一为 12pt", category: "界面与布局")
    let custom = phrase("d", "多行\n标题", "自定义分类话术", category: "自定义")
    let doc = VibeHubMarkdown.document([ui, custom, routing], title: "Vibehub 话术 · 全部",
                                       categoryOrder: ["路由与导航", "界面与布局"], exportedAt: date, timeZone: utc)
    try check(doc.hasPrefix("# Vibehub 话术 · 全部\n\n> 由 Jaimo Flow Vibehub 导出 · 2026-11-18 11:06 · 共 3 条话术\n"),
              "导出文档标题、时间或数量错误")
    let routeIndex = doc.range(of: "## 路由与导航（1）")!.lowerBound
    let uiIndex = doc.range(of: "## 界面与布局（1）")!.lowerBound
    let customIndex = doc.range(of: "## 自定义（1）")!.lowerBound
    try check(routeIndex < uiIndex && uiIndex < customIndex, "分类分组顺序错误")
    try check(doc.contains("### 多行 标题\n") && doc.hasSuffix("\n") && !doc.contains("## 数据与接口"),
              "多行标题未合并或出现空分类")

    try check(VibeHubMarkdown.suggestedFileName(scopeTitle: "调试/测试: 收藏", date: date, timeZone: utc)
              == "Vibehub 话术 调试-测试- 收藏 2026-11-18.md", "导出文件名未清理非法字符")

    try check(VibeHubSimilarity.normalized("Hello， World！\n ＡＢＣ") == "helloworldabc", "归一化未忽略大小写、全半角、标点和空白")
    try check(VibeHubSimilarity.score("给页面加上哈希路由，支持前进后退。", "给页面加上哈希路由 支持前进后退") == 1,
              "仅标点空白不同的话术未判为相同")
    let near = VibeHubSimilarity.score("给各个页面加上哈希路由，点击切换时网址同步变化，并支持刷新和浏览器前进后退。",
                                       "给各个页面加上哈希路由，点击切换时网址同步变化，支持刷新与浏览器前进后退")
    try check(near >= VibeHubSimilarity.defaultThreshold && near < 1, "近似话术相似度不在预期范围：\(near)")
    try check(VibeHubSimilarity.score("修复登录页面报错", "把卡片间距统一为 12pt") < 0.3, "无关话术被判为相似")
    try check(VibeHubSimilarity.score("修复 bug", "修复 bugs") == 0 && VibeHubSimilarity.score("修复", "修复") == 1,
              "过短话术应只做完全匹配")

    let target = phrase("t", "新", "给各个页面加上哈希路由，点击切换时网址同步变化，并支持刷新和浏览器前进后退。")
    let candidates = [
        target,
        phrase("x", "无关", "把卡片间距统一为 12pt"),
        phrase("y", "近似", "给各个页面加上哈希路由，点击切换时网址同步变化，支持刷新与浏览器前进后退"),
        phrase("z", "相同", "给各个页面加上哈希路由 点击切换时网址同步变化 并支持刷新和浏览器前进后退"),
        phrase("e", "空", "  ")
    ]
    let matches = VibeHubSimilarity.matches(for: target, in: candidates)
    try check(matches.map(\.id) == ["z", "y"] && matches.first?.score == 1, "相似话术未排除自身或排序错误")
    try check(VibeHubSimilarity.matches(for: phrase("e", "空", " \n"), in: candidates).isEmpty, "空话术不应提示重复")
    try check(VibeHubSimilarity.matches(for: target, in: candidates, limit: 1).count == 1, "相似结果数量上限无效")
    return checks
}
