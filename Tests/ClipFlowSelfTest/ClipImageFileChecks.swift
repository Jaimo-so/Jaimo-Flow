import ClipFlowKit
import Foundation

func testClipImageFile() throws {
    let timeZone = TimeZone(secondsFromGMT: -3 * 3600)!
    let locale = Locale(identifier: "en_US_POSIX")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let copiedAt = calendar.date(from: DateComponents(
        calendar: calendar,
        timeZone: timeZone,
        year: 2026,
        month: 11,
        day: 23,
        hour: 10,
        minute: 5,
        second: 9
    ))!

    try require(
        ClipImageFile.suggestedFileName(
            copiedAt: copiedAt,
            sourceAppName: "Safari",
            pathExtension: "png",
            timeZone: timeZone,
            locale: locale
        ) == "Safari 2026-11-23 10.05.09.png",
        "建议文件名应包含来源应用和本地时间"
    )
    try require(
        ClipImageFile.suggestedFileName(
            copiedAt: copiedAt,
            sourceAppName: "  ",
            pathExtension: "",
            timeZone: timeZone,
            locale: locale
        ) == "图片 2026-11-23 10.05.09.png",
        "空来源或空扩展名应回退为「图片」和 png"
    )
    try require(
        ClipImageFile.suggestedFileName(
            copiedAt: copiedAt,
            sourceAppName: "截图/文件夹:测试",
            pathExtension: ".JPEG",
            timeZone: timeZone,
            locale: locale
        ) == "截图 文件夹 测试 2026-11-23 10.05.09.jpeg",
        "文件名应去掉路径分隔符并规范化扩展名"
    )

    try require(ClipImageFile.preferredExtension("PNG") == "png", "扩展名应转为小写")
    try require(ClipImageFile.preferredExtension(".JPG") == "jpg", "扩展名应去掉前导点")
    try require(ClipImageFile.preferredExtension("  ") == "png", "空扩展名应默认为 png")
    try require(
        ClipImageFile.preferredExtension(for: URL(fileURLWithPath: "/tmp/photo.HEIC")) == "heic",
        "应从路径读取扩展名"
    )

    try require(ClipImageFile.sanitizedFileNameComponent("Safari") == "Safari", "普通应用名不应被改写")
    try require(
        ClipImageFile.sanitizedFileNameComponent("Foo/Bar\\Baz:Qux") == "Foo Bar Baz Qux",
        "非法文件名字符应替换为空格"
    )
    try require(ClipImageFile.sanitizedFileNameComponent("\n\t  ") == "图片", "空白名称应回退为「图片」")
    try require(ClipImageFile.sanitizedFileNameComponent("name.") == "name", "不应留下末尾的点")
    let longName = String(repeating: "A", count: 50)
    try require(
        ClipImageFile.sanitizedFileNameComponent(longName) == String(repeating: "A", count: 40),
        "过长的来源名应截断到 40 个字符"
    )
    try require(
        !ClipImageFile.sanitizedFileNameComponent("a/b").contains("/")
            && !ClipImageFile.suggestedFileName(
                copiedAt: copiedAt,
                sourceAppName: "a/b",
                pathExtension: "png",
                timeZone: timeZone,
                locale: locale
            ).contains("/"),
        "建议文件名不能包含路径分隔符"
    )

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClipImageFileTest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let source = directory.appendingPathComponent("source.bin")
    let payload = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03])
    try payload.write(to: source)
    let destination = directory.appendingPathComponent("export.png")
    try ClipImageFile.export(from: source, to: destination)
    try require(try Data(contentsOf: destination) == payload, "导出应完整保留原始字节，不重新编码")
    try require(try Data(contentsOf: source) == payload, "导出不应改写源文件")

    let replaced = Data([0xFF, 0xD8, 0xFF])
    try replaced.write(to: destination)
    try ClipImageFile.export(from: source, to: destination)
    try require(try Data(contentsOf: destination) == payload, "目标已存在时应覆盖为源文件内容")

    try ClipImageFile.export(from: source, to: source)
    try require(try Data(contentsOf: source) == payload, "导出到源路径本身应保持原文件不变")

    let missing = directory.appendingPathComponent("missing.png")
    do {
        try ClipImageFile.export(from: missing, to: destination)
        throw SelfTestError.failed("源文件不存在时不应导出成功")
    } catch is SelfTestError {
        throw SelfTestError.failed("源文件不存在时不应导出成功")
    } catch {
        try require(try Data(contentsOf: destination) == payload, "源文件缺失时不应改写已有目标")
    }
}
