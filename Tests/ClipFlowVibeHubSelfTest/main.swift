import AppKit
@testable import ClipFlow

enum VibeHubTestError: Error { case failed(String) }
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw VibeHubTestError.failed(message) }
}

try MainActor.assumeIsolated {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClipFlowVibeHubSelfTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("VibeHub/phrases.json")
    let model = VibeHubLibraryModel(fileURL: url)
    let original = "给各个页面加上哈希路由，点击切换时网址同步变化，并支持刷新和浏览器前进后退。"
    try require(model.selectedItem?.phrase == original, "示例话术未完整保留")
    try require(model.selectedItem?.category == .navigation, "示例分类错误")
    let sampleID = model.selectedID
    model.flush()
    try require(model.saveStatus == .saved, "首次保存失败")
    try require(VibeHubLibraryModel(fileURL: url).items == model.items, "重开后内容丢失或重复插入示例")

    model.scope = .category(.interface)
    try require(model.selectedItem == nil, "空分类保留不可见的选中项")
    let createdID = model.createPhrase()
    try require(model.selectedItem?.category == .interface && model.selectedID == createdID, "新建未沿用分类")
    let longText = String(repeating: "定义与意义要完整保留。\n", count: 500)
    model.updateSelected(\.title, to: "我的界面话术")
    model.updateSelected(\.phrase, to: "修改页面间距和字体")
    model.updateSelected(\.scenario, to: "页面排版调整")
    model.updateSelected(\.meaning, to: longText)
    model.updateSelected(\.tags, to: "响应式、CSS")
    model.updateSelected(\.isFavorite, to: true)
    model.flush()
    let restored = VibeHubLibraryModel(fileURL: url)
    restored.selectedID = createdID
    try require(restored.selectedItem?.meaning == longText, "长笔记的定义和意义被截断")
    try require(restored.selectedItem == model.selectedItem, "编辑字段未全部持久化")
    model.scope = .favorites
    try require(model.filteredItems.count == 1, "收藏筛选错误")
    model.updateSelected(\.isFavorite, to: false)
    try require(model.scope == .all && model.selectedID == createdID, "取消收藏时编辑目标丢失")
    model.query = "HASH"
    try require(model.filteredItems.count == 1 && model.selectedID == sampleID, "含义的英文搜索失效")
    model.query = "css"
    try require(model.filteredItems.count == 1 && model.selectedID == createdID, "标签搜索失效")
    model.query = "页面排版调整"
    try require(model.filteredItems.count == 1, "场景搜索失效")
    model.query = ""
    model.selectedID = createdID
    model.classifySelected()
    try require(model.selectedItem?.category == .interface, "布局话术分类错误")
    model.updateSelected(\.phrase, to: original)
    model.classifySelected()
    try require(model.selectedItem?.category == .navigation, "路由话术误归交互类")
    model.updateSelected(\.category, to: .engineering)
    model.updateSelected(\.phrase, to: "用户自己的原始表达\n\n第二段")
    try require(model.selectedItem?.category == .engineering, "手动分类被编辑原文覆盖")
    model.scope = .favorites
    _ = model.createPhrase()
    try require(model.selectedItem?.isFavorite == true, "收藏页新建不可见")
    model.scope = .all
    for item in model.items { model.selectedID = item.id; model.deleteSelected() }
    model.flush()
    try require(VibeHubLibraryModel(fileURL: url).items.isEmpty, "删除全部后重新生成了示例")

    let corruptURL = directory.appendingPathComponent("corrupt.json")
    let bytes = Data("unreadable-json".utf8)
    try bytes.write(to: corruptURL)
    let corrupt = VibeHubLibraryModel(fileURL: corruptURL)
    try require(corrupt.loadFailed && corrupt.createPhrase() == nil, "无法读取时仍创建话术")
    corrupt.flush()
    let unchanged = try Data(contentsOf: corruptURL)
    try require(unchanged == bytes, "读取失败覆盖了原有话术文件")
    try JSONEncoder().encode(restored.items).write(to: corruptURL)
    corrupt.reload()
    try require(!corrupt.loadFailed && corrupt.items == restored.items, "重新读取失败")

    let blocked = directory.appendingPathComponent("blocked")
    try Data().write(to: blocked)
    let retryURL = blocked.appendingPathComponent("phrases.json")
    let retry = VibeHubLibraryModel(fileURL: retryURL)
    retry.flush()
    try require(retry.saveStatus == .failed, "写入失败未反馈")
    try FileManager.default.removeItem(at: blocked)
    retry.flush()
    try require(retry.saveStatus == .saved && VibeHubLibraryModel(fileURL: retryURL).items == retry.items, "保存失败后无法重试")

    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let monitor = ClipboardMonitor(pasteboard: board)
    _ = monitor.write(text: original)
    try require(board.string(forType: .string) == original, "复制丢失原文")
    print("PASS: 示例原文、分类与手动调整、搜索与收藏、长笔记保存重开、删除、读取保护、失败重试与完整复制")

}
