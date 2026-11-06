import AppKit
import Combine
import Foundation
import SwiftUI
@testable import ClipFlow

enum MemoTestError: Error {
    case failed(String)
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw MemoTestError.failed(message) }
}

final class NoteTestDefaults: UserDefaults {
    var quickNoteWrites = 0
    var rejectQuickNoteWrites = false

    override func set(_ value: Any?, forKey defaultName: String) {
        if defaultName == "home.quickNote" {
            quickNoteWrites += 1
            if rejectQuickNoteWrites { return }
        }
        super.set(value, forKey: defaultName)
    }
}

@MainActor
func runTests() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClipFlowMemoSelfTest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("Memos/memos.json")

    let model = MemoLibraryModel(fileURL: fileURL)
    let legacyID = model.createMemo()
    try require(model.selectedItem?.title == "新备忘录", "普通新建默认标题发生变化")
    try require(model.selectedItem?.body == "", "普通新建默认正文发生变化")
    model.updateTitle("原有备忘录")
    model.updateBody("原有正文")
    model.togglePinned(model.selectedItem!)
    try await Task.sleep(nanoseconds: 650_000_000)
    try require(!FileManager.default.fileExists(atPath: fileURL.path), "编辑期间仍触发了延迟保存")
    try require(model.saveStatus == .pending, "编辑期间应显示关闭时保存")
    model.flush()
    let legacyItem = model.selectedItem!

    // The future Agent provides already recognized, separate tasks. The app
    // accepts ordinary title/body text; it does not extract or infer metadata.
    let tasks: [(id: UUID, title: String, body: String)] = [
        (UUID(), "整理发布清单", "整理发布清单\n负责人：小林\n期限：周五\n会议原话：小林周五前整理发布清单。"),
        (UUID(), "核对接口文档", "核对接口文档"),
        (UUID(), "同步评审结果", "同步评审结果\n会议原话：把评审结果同步一下。")
    ]
    for task in tasks {
        let returnedID = try model.createMemo(id: task.id, title: task.title, body: task.body)
        try require(returnedID == task.id, "创建未保留调用者提供的稳定标识")
    }
    try require(model.items.count == 4, "三个任务没有分别创建三条普通 Memo")
    try require(model.items.first(where: { $0.id == legacyID }) == legacyItem, "创建任务改变了原有 Memo")
    for task in tasks {
        let item = model.items.first { $0.id == task.id }
        try require(item?.title == task.title && item?.body == task.body, "输入文本未原样保留")
        try require(item?.isPinned == false, "任务 Memo 默认置顶状态改变")
        try model.createMemo(id: task.id, title: task.title, body: task.body)
    }
    try require(model.items.count == 4, "保存前重复请求产生重复记录")
    model.flush()
    try require(model.saveStatus == .saved, "任务 Memo 未保存成功")

    let data = try Data(contentsOf: fileURL)
    let rows = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
    let expectedKeys: Set<String> = ["id", "title", "body", "createdAt", "updatedAt", "isPinned"]
    try require(rows.count == 4 && rows.allSatisfy { Set($0.keys) == expectedKeys }, "Memo JSON 字段或数组格式改变")
    let decoded = try JSONDecoder().decode([MemoItem].self, from: data)
    try require(decoded == model.items, "现有 Memo 解码流程无法读取保存结果")

    let reopened = MemoLibraryModel(fileURL: fileURL)
    try require(reopened.items == model.items, "重载丢失 Memo 或现有字段")
    try require(reopened.sortedItems.first?.id == legacyID, "原有置顶排序改变")
    // Use the real overlay's observed model and the same sortedItems /
    // selectedItem paths its list and editor read, without opening user data.
    let overlay = MemoLibraryOverlay(model: reopened, onClose: {})
    try require(overlay.model === reopened, "原有 Memo 界面未复用保存后的模型")
    for task in tasks {
        try require(overlay.model.sortedItems.contains { $0.id == task.id }, "任务未进入原有 Memo 界面列表数据")
        overlay.model.selectedID = task.id
        try require(overlay.model.selectedItem?.body == task.body, "原有编辑界面不能读取任务正文")
        try reopened.createMemo(id: task.id, title: task.title, body: task.body)
    }
    try require(reopened.items.count == 4, "重载后重复请求产生重复记录")
    reopened.selectedID = tasks[0].id
    reopened.updateTitle("用户修改的标题")
    reopened.updateBody("用户修改的正文")
    reopened.flush()
    let edited = reopened.selectedItem!
    try reopened.createMemo(id: tasks[0].id, title: tasks[0].title, body: tasks[0].body)
    try require(reopened.selectedItem == edited && reopened.items.count == 4, "重试覆盖用户编辑或产生重复记录")
    let savedBeforeEditing = try Data(contentsOf: fileURL)
    let orderBeforeEditing = reopened.sortedItems.map(\.id)
    var memoRefreshes = 0
    let memoSubscription = reopened.objectWillChange.sink { memoRefreshes += 1 }
    reopened.updateBody("连")
    reopened.updateBody("连续")
    reopened.updateBody("第一次修改\n定义：完整保留记录。\n意义：关闭时统一保存。")
    try require(memoRefreshes == 1, "备忘录每次输入仍在刷新整个列表")
    try require(reopened.sortedItems.map(\.id) == orderBeforeEditing, "输入期间列表仍在重新排序")
    memoSubscription.cancel()
    reopened.selectedID = tasks[1].id
    reopened.updateBody("切换后修改另一条")
    try await Task.sleep(nanoseconds: 650_000_000)
    let dataWhileEditing = try Data(contentsOf: fileURL)
    try require(dataWhileEditing == savedBeforeEditing, "切换备忘录或输入停顿提前写入文件")
    reopened.selectedID = tasks[0].id
    reopened.updateBody("最后追加的完整正文\n定义：保留所有编辑。\n意义：旧保存结果不能覆盖最新输入。")
    let latestItems = reopened.items
    try require(reopened.flush(), "关闭时未能保存最新内容")
    try await Task.sleep(nanoseconds: 650_000_000)
    try require(MemoLibraryModel(fileURL: fileURL).items == latestItems, "延迟任务覆盖了关闭时保存的最新内容")
    // Same text with a different task ID must remain a distinct Memo.
    try reopened.createMemo(id: UUID(), title: tasks[1].title, body: tasks[1].body)
    try require(reopened.items.count == 5, "不同任务被按相同内容错误合并")
    reopened.flush()

    do {
        try reopened.createMemo(id: UUID(), title: " \n", body: "\t")
        throw MemoTestError.failed("空输入创建了 Memo")
    } catch MemoLibraryModel.CreationError.emptyContent { }
    try require(reopened.items.count == 5, "拒绝空输入改变了 Memo 列表")

    let corruptURL = directory.appendingPathComponent("unreadable.json")
    let corruptData = Data("invalid-json".utf8)
    try corruptData.write(to: corruptURL)
    let unreadable = MemoLibraryModel(fileURL: corruptURL)
    do {
        try unreadable.createMemo(id: UUID(), title: "测试", body: "测试")
        throw MemoTestError.failed("读取失败后仍允许内容创建")
    } catch MemoLibraryModel.CreationError.unreadableStore { }
    unreadable.flush()
    let unchangedData = try Data(contentsOf: corruptURL)
    try require(unchangedData == corruptData && unreadable.items.isEmpty, "读取失败后的输入覆盖了原文件")

    let blockedParent = directory.appendingPathComponent("not-a-directory")
    try Data().write(to: blockedParent)
    let retryURL = blockedParent.appendingPathComponent("memos.json")
    let retryModel = MemoLibraryModel(fileURL: retryURL)
    let retryID = UUID()
    try retryModel.createMemo(id: retryID, title: "测试", body: "测试")
    retryModel.flush()
    try require(retryModel.saveStatus == .failed, "写入失败被报告为成功")
    retryModel.updateBody("保存失败后继续写入的完整内容")
    try retryModel.createMemo(id: retryID, title: "测试", body: "测试")
    try require(retryModel.items.count == 1, "写入失败后重试追加重复记录")
    try FileManager.default.removeItem(at: blockedParent)
    retryModel.flush()
    try require(retryModel.saveStatus == .saved, "修复写入位置后不能保存待写入 Memo")
    try require(MemoLibraryModel(fileURL: retryURL).items.count == 1, "写入重试的保存结果不正确")
    try require(MemoLibraryModel(fileURL: retryURL).selectedItem?.body == "保存失败后继续写入的完整内容", "失败后继续输入的内容丢失")

    let suite = "ClipFlowQuickNoteSelfTest.\(UUID().uuidString)"
    let defaults = NoteTestDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("上次关闭时的内容", forKey: "home.quickNote")
    defaults.quickNoteWrites = 0
    let home = HomeDashboardModel(defaults: defaults, memoLibrary: MemoLibraryModel(fileURL: directory.appendingPathComponent("quick-note-memos.json")))
    try require(home.quickNote == "上次关闭时的内容", "便签未恢复上次关闭时的内容")
    var quickNoteRefreshes = 0
    let quickNoteSubscription = home.objectWillChange.sink { quickNoteRefreshes += 1 }
    home.quickNote = "正在编辑\n第二行"
    home.quickNote += "连续输入"
    home.quickNote += "不中断"
    try require(quickNoteRefreshes == 1, "便签每次输入仍在刷新整个共享界面")
    quickNoteSubscription.cancel()
    try await Task.sleep(nanoseconds: 650_000_000)
    try require(defaults.quickNoteWrites == 0, "便签输入停顿期间仍在保存")
    try require(defaults.string(forKey: "home.quickNote") == "上次关闭时的内容", "便签编辑覆盖了上次保存的内容")
    try require(home.quickNoteSaveStatus == .pending, "便签编辑期间未显示关闭时保存")
    home.quickNote += "\n关闭前最后追加"
    try require(home.flushQuickNote(), "便签关闭时保存失败")
    try require(defaults.string(forKey: "home.quickNote") == home.quickNote, "便签没有保存最后的完整内容")
    try require(defaults.quickNoteWrites == 1, "便签关闭时不止保存一次")
    home.flushQuickNote()
    try require(defaults.quickNoteWrites == 1, "重复关闭造成重复写入")
    let savedQuickNote = home.quickNote
    home.quickNote = "重新打开后继续输入"
    try await Task.sleep(nanoseconds: 650_000_000)
    try require(home.quickNote == "重新打开后继续输入", "旧保存任务覆盖了新输入")
    try require(defaults.string(forKey: "home.quickNote") == savedQuickNote, "重新编辑时提前保存")
    defaults.rejectQuickNoteWrites = true
    try require(!home.flushQuickNote() && home.quickNoteSaveStatus == .failed, "便签写入失败没有正确报告")
    home.quickNote += "\n失败后继续追加"
    try require(home.quickNote.hasSuffix("失败后继续追加"), "便签保存失败后没有保留新编辑")
    defaults.rejectQuickNoteWrites = false
    try require(home.flushQuickNote(), "便签写入恢复后不能重试")
    try require(defaults.string(forKey: "home.quickNote") == home.quickNote, "便签重试丢失完整内容")
    home.quickNote = ""
    try require(home.flushQuickNote() && defaults.string(forKey: "home.quickNote") == "", "清空便签后关闭没有保存空内容")

    home.memoLibraryOpen = true
    home.memoLibrary.createMemo()
    home.memoLibrary.updateBody("关闭面板前的正文")
    home.closeMemoLibrary()
    try require(!home.memoLibraryOpen && home.memoLibrary.saveStatus == .saved, "关闭备忘录面板未保存")

    // Preserve normal edit / pin / delete behavior on imported ordinary Memos.
    reopened.selectedID = tasks[2].id
    reopened.togglePinned(reopened.selectedItem!)
    try require(reopened.selectedItem?.isPinned == true, "任务 Memo 不能使用原有置顶功能")
    reopened.deleteSelected()
    reopened.flush()
    try require(MemoLibraryModel(fileURL: fileURL).items.count == 4, "原有删除保存流程失效")

    // Search filters title/body; deleting while filtered prefers another visible item.
    let searchModel = MemoLibraryModel(fileURL: fileURL)
    searchModel.query = "接口文档"
    try require(searchModel.filteredSortedItems.count == 1, "标题搜索未命中唯一备忘录")
    try require(searchModel.filteredSortedItems.first?.title == "核对接口文档", "标题搜索结果不正确")
    searchModel.query = "完整保留记录"
    try require(searchModel.filteredSortedItems.count == 1, "正文搜索未命中备忘录")
    searchModel.query = "不存在的关键词XYZ"
    try require(searchModel.filteredSortedItems.isEmpty, "无匹配搜索应返回空列表")
    searchModel.query = "整理"
    try require(searchModel.filteredSortedItems.count >= 1, "部分关键词搜索失败")
    let visibleID = searchModel.filteredSortedItems[0].id
    searchModel.selectedID = visibleID
    searchModel.deleteSelected()
    try require(searchModel.items.contains { $0.id == visibleID } == false, "删除后记录仍存在")
    if let nextID = searchModel.selectedID {
        try require(searchModel.filteredSortedItems.contains { $0.id == nextID }, "删除后选中项不在当前搜索结果中")
    }
    searchModel.query = ""
    let nonempty = searchModel.items.first {
        !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    try require(nonempty != nil, "搜索自检缺少带正文的备忘录")
    searchModel.selectedID = nonempty!.id
    try require(searchModel.copySelectedBody(), "有正文时应能复制到剪贴板")
    searchModel.createMemo()
    try require(searchModel.query.isEmpty, "手动新建未清空搜索词")
    try require(!searchModel.copySelectedBody(), "空正文不应复制成功")
    print("PASS: 备忘录与便签编辑不逐字刷新共享界面、不写盘与重排；关闭保存最新全文；失败重试与字段兼容；搜索与复制")
}

try await runTests()
