import AppKit
import Foundation
import SwiftUI
@testable import ClipFlow

enum MemoTestError: Error {
    case failed(String)
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw MemoTestError.failed(message) }
}

try MainActor.assumeIsolated {
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
    try retryModel.createMemo(id: retryID, title: "测试", body: "测试")
    try require(retryModel.items.count == 1, "写入失败后重试追加重复记录")
    try FileManager.default.removeItem(at: blockedParent)
    retryModel.flush()
    try require(retryModel.saveStatus == .saved, "修复写入位置后不能保存待写入 Memo")
    try require(MemoLibraryModel(fileURL: retryURL).items.count == 1, "写入重试的保存结果不正确")

    // Preserve normal edit / pin / delete behavior on imported ordinary Memos.
    reopened.selectedID = tasks[2].id
    reopened.togglePinned(reopened.selectedItem!)
    try require(reopened.selectedItem?.isPinned == true, "任务 Memo 不能使用原有置顶功能")
    reopened.deleteSelected()
    reopened.flush()
    try require(MemoLibraryModel(fileURL: fileURL).items.count == 4, "原有删除保存流程失效")
    print("PASS: 单任务单 Memo、原有界面数据路径、保存重载、重复调用、编辑保留、字段兼容与失败重试")
}
