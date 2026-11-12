import AppKit
import Foundation
@testable import ClipFlow

enum RecorderTestError: Error {
    case failed(String)
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw RecorderTestError.failed(message) }
}

func touch(url: URL, createdAt: Date, size: Int = 32) throws {
    let data = Data(repeating: 0x01, count: size)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([
        .creationDate: createdAt,
        .modificationDate: createdAt
    ], ofItemAtPath: url.path)
}

@MainActor
func runTests() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClipFlowRecorderSelfTest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let older = Date(timeIntervalSince1970: 1_700_000_000)
    let newer = Date(timeIntervalSince1970: 1_700_086_400)
    let mid = Date(timeIntervalSince1970: 1_700_043_200)
    try touch(url: directory.appendingPathComponent("晨会纪要.m4a"), createdAt: older, size: 80)
    try touch(url: directory.appendingPathComponent("产品评审.m4a"), createdAt: newer, size: 40)
    try touch(url: directory.appendingPathComponent("ignore.txt"), createdAt: newer, size: 16)
    try touch(url: directory.appendingPathComponent(".hidden.m4a"), createdAt: newer, size: 16)
    try FileManager.default.createDirectory(
        at: directory.appendingPathComponent("not-a-file.m4a"),
        withIntermediateDirectories: false
    )
    try touch(url: directory.appendingPathComponent("Jaimo Flow 录音 2026-11-12 10-03-00-123.m4a"), createdAt: mid, size: 120)

    let loaded = SavedRecording.loadAll(in: directory)
    try require(loaded.count == 3, "应只收录普通 m4a 文件，忽略文本、隐藏文件和同名目录")
    try require(loaded.map(\.name) == ["产品评审", "Jaimo Flow 录音 2026-11-12 10-03-00-123", "晨会纪要"], "历史应按创建时间从新到旧排序")
    try require(loaded[0].byteSize == 40, "文件大小读取不正确")

    let filtered = SavedRecording.filter(loaded, query: " 评审 ")
    try require(filtered.map(\.name) == ["产品评审"], "搜索应按名称忽略首尾空白并做不区分大小写匹配")
    try require(SavedRecording.filter(loaded, query: "JAIMO").count == 1, "搜索应忽略大小写")
    try require(SavedRecording.filter(loaded, query: "   ").count == 3, "只有空白的搜索词应返回全部记录")
    try require(SavedRecording.filter(loaded, query: "不存在").isEmpty, "无匹配时应返回空列表")

    switch SavedRecording.validatedFileName("  周会录音  ") {
    case .success(let name):
        try require(name == "周会录音", "重命名校验应去掉首尾空白")
    case .failure(let message):
        throw RecorderTestError.failed("合法名称被拒绝：\(message)")
    }
    if case .success = SavedRecording.validatedFileName("  ") {
        throw RecorderTestError.failed("空名称应被拒绝")
    }
    if case .success = SavedRecording.validatedFileName("a/b") {
        throw RecorderTestError.failed("带路径分隔符的名称应被拒绝")
    }
    if case .success = SavedRecording.validatedFileName("a:b") {
        throw RecorderTestError.failed("带冒号的名称应被拒绝")
    }
    if case .success = SavedRecording.validatedFileName(".") {
        throw RecorderTestError.failed("单独的点不应作为文件名")
    }

    let model = AudioRecorderModel(recordingsDirectory: directory)
    try require(model.recordings.map(\.name) == loaded.map(\.name), "模型初始化后应载入同一批录音")
    try require(model.latestRecording?.name == "产品评审", "最近一条应为最新创建的录音")

    model.historyQuery = "录音"
    try require(model.filteredRecordings.count == 1, "模型搜索过滤结果不正确")
    model.historyQuery = ""

    let original = model.recordings.first { $0.name == "晨会纪要" }!
    try require(model.rename(original, to: "晨会纪要"), "未改名的重命名应视为成功")
    try require(model.rename(original, to: "产品评审") == false, "重名为已存在的文件应失败")
    try require(model.historyError == "已有同名录音", "同名冲突应给出明确提示")
    try require(model.rename(original, to: "  ../秘密  ") == false, "非法名称应被拒绝")
    try require(model.rename(original, to: "周会纪要"), "合法重命名应成功")
    try require(model.recordings.contains(where: { $0.name == "周会纪要" }), "重命名后列表应出现新名称")
    try require(!model.recordings.contains(where: { $0.name == "晨会纪要" }), "重命名后旧名称应消失")
    try require(
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("周会纪要.m4a").path),
        "重命名后文件应落在新路径"
    )
    try require(model.selectedRecordingID == directory.appendingPathComponent("周会纪要.m4a").path, "重命名后应选中新文件")

    let beforeDelete = model.recordings.count
    let target = model.recordings.first { $0.name == "周会纪要" }!
    try require(model.delete(target), "删除已有录音应成功")
    try require(model.recordings.count == beforeDelete - 1, "删除后列表数量应减少")
    try require(!model.recordings.contains(where: { $0.name == "周会纪要" }), "删除后记录仍在列表中")
    try require(
        !FileManager.default.fileExists(atPath: directory.appendingPathComponent("周会纪要.m4a").path),
        "删除后文件仍留在目录中"
    )

    let missing = SavedRecording(
        url: directory.appendingPathComponent("already-gone.m4a"),
        name: "already-gone",
        createdAt: Date(),
        duration: 0,
        byteSize: 0
    )
    try require(model.delete(missing), "删除已不存在的文件应视为成功并刷新列表")

    model.historyQuery = "产品"
    try require(model.filteredRecordings.map(\.name) == ["产品评审"], "删除其他条目后搜索结果应保持正确")

    print("PASS: 录音历史按时间排序、搜索、重命名与删除；临时目录不触及用户本机录音")
}

try await runTests()
