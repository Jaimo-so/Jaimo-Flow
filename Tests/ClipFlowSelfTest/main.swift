import ClipFlowKit
import Foundation

enum SelfTestError: Error {
    case failed(String)
}

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw SelfTestError.failed(message) }
}

func makeClip(_ text: String, date: Date = Date()) -> CapturedClip {
    CapturedClip(
        kind: .text,
        category: .text,
        sourceAppName: "SelfTest",
        sourceBundleID: "com.clipflow.selftest",
        copiedAt: date,
        title: text,
        fullText: text,
        meta: ClipClassifier.textMeta(text: text, kind: .text),
        contentHash: ClipClassifier.hash(Data(text.utf8))
    )
}

func withStore(_ body: (SQLiteClipStore) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClipFlowSelfTest-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(SQLiteClipStore(baseDirectory: directory))
}

do {
    let reviewDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClipFlowDailyReviewSelfTest-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: reviewDirectory) }
    let reviewURL = reviewDirectory.appendingPathComponent("DailyReviews/reviews.json")
    let reviewStore = try DailyReviewStore(fileURL: reviewURL)
    let fullReview = "今日完成\n写出完整定义：复盘是回看事实、分析原因和安排下一步。\n\n收获与思考\n保留原文、例子与意义。🙂"
    try reviewStore.save(dateKey: "2026-10-13", body: fullReview)
    try require(reviewStore.entry(for: "2026-10-13")?.body == fullReview, "每日复盘保存时丢失正文或换行")
    try reviewStore.save(dateKey: "2026-10-12", body: "昨天的复盘")
    try reviewStore.save(dateKey: "2026-10-13", body: fullReview + "\n下一步：继续验证。")
    try require(reviewStore.entries.count == 2, "同一天重复保存产生多篇复盘")
    let reopenedReviews = try DailyReviewStore(fileURL: reviewURL)
    try require(reopenedReviews.entry(for: "2026-10-13")?.body == fullReview + "\n下一步：继续验证。", "重新打开后复盘正文不完整")
    try require(reopenedReviews.entry(for: "2026-10-12")?.body == "昨天的复盘", "保存今天覆盖了历史复盘")
    do {
        try reopenedReviews.save(dateKey: "2026-10-14", body: " \n ")
        throw SelfTestError.failed("空白复盘被保存")
    } catch DailyReviewStore.StoreError.emptyContent { }
    let corruptReviewURL = reviewDirectory.appendingPathComponent("corrupt.json")
    let corruptReviewData = Data("not-json".utf8)
    try corruptReviewData.write(to: corruptReviewURL)
    do {
        _ = try DailyReviewStore(fileURL: corruptReviewURL)
        throw SelfTestError.failed("损坏的复盘文件被当作空库")
    } catch is DecodingError { }
    try require(try Data(contentsOf: corruptReviewURL) == corruptReviewData, "读取失败改变了原有复盘文件")

    let url = ClipClassifier.classify(text: "https://example.com/path?q={value}")
    try require(url.kind == .link && url.category == .link, "URL 必须优先判定为链接")

    let code = ClipClassifier.classify(text: "func greet() {\n  return \"你好\"\n}")
    try require(code.kind == .code && code.category == .text, "多行代码分类失败")

    try require(
        ClipClassifier.classify(text: "周四下午对接接口联调").kind == .text,
        "单行普通文字分类失败"
    )

    let longArticle = (0..<180)
        .map { "第\($0)段：渐进渲染需要保留每一段文字及其定义与意义。" }
        .joined(separator: "\n")
    let articleChunks = TextChunker.chunks(from: longArticle, targetLength: 120, maximumLength: 160)
    try require(articleChunks.count > 1, "长文章没有被分片")
    try require(
        articleChunks.map { $0.text + $0.trailingSeparator }.joined() == longArticle,
        "文章分片后没有完整保留原文"
    )
    try require(
        articleChunks.allSatisfy { $0.text.count <= 160 },
        "文章分片超过最大长度"
    )

    let unbrokenText = String(repeating: "🙂", count: 360)
    let unbrokenChunks = TextChunker.chunks(from: unbrokenText, targetLength: 90, maximumLength: 100)
    try require(
        unbrokenChunks.map { $0.text + $0.trailingSeparator }.joined() == unbrokenText,
        "无换行长文本分片损坏了 Unicode 字符"
    )

    try withStore { store in
        let clip = makeClip("same")
        try require(store.insert(clip) != nil, "首次插入失败")
        try require(store.insert(clip) == nil, "连续相同内容没有被去重")
        try require(store.itemCount() == 1, "去重后的记录数错误")
    }

    try withStore { store in
        guard let first = try store.insert(makeClip("first", date: Date(timeIntervalSince1970: 1))) else {
            throw SelfTestError.failed("无法插入首条记录")
        }
        _ = try store.insert(makeClip("second", date: Date(timeIntervalSince1970: 2)))
        try store.setFavorite(id: first.id, isFavorite: true)
        _ = try store.insert(makeClip("third", date: Date(timeIntervalSince1970: 3)), limit: 2)

        let items = try store.loadAll()
        try require(Set(items.map(\.title)) == Set(["first", "third"]), "数量上限没有淘汰最旧非收藏项")
        try require(items.first(where: { $0.id == first.id })?.isFavorite == true, "收藏项没有保留")
    }

    try require(SQLiteClipStore.defaultHistoryLimit == 150, "默认历史上限必须为 150 条")
    try withStore { store in
        for index in 0..<155 {
            _ = try store.insert(
                makeClip("history-\(index)", date: Date(timeIntervalSince1970: Double(index))),
                limit: 1_000
            )
        }
        try store.enforceHistoryLimit()
        try require(store.itemCount() == 150, "现有历史没有收敛到默认上限")
    }

    let promptBody = "请用{{语气}}向{{受众}}解释：{{内容}}。再次强调：{{语气}}。"
    try require(
        PromptTemplate.variableNames(in: promptBody) == ["语气", "受众", "内容"],
        "提示词变量没有按首次出现顺序去重"
    )
    try require(
        PromptTemplate.render(
            promptBody,
            values: ["语气": "简洁", "受众": "新用户", "内容": "本地存储"]
        ) == "请用简洁向新用户解释：本地存储。再次强调：简洁。",
        "提示词变量渲染失败"
    )

    try withStore { store in
        _ = try store.insert(makeClip("history"))
        let created = try store.createPrompt(
            title: "解释概念",
            body: promptBody,
            groupName: "写作",
            variables: PromptTemplate.variables(in: promptBody)
        )
        try require(try store.promptCount() == 1, "提示词没有写入独立数据表")
        try require(try store.clear() == 1, "清空历史返回的数量错误")
        try require(try store.promptCount() == 1, "清空历史误删了提示词")

        try store.updatePrompt(
            id: created.id,
            title: "解释复杂概念",
            body: "向{{对象}}解释{{主题}}",
            groupName: "产品",
            variables: PromptTemplate.variables(in: "向{{对象}}解释{{主题}}")
        )
        try store.setPromptFavorite(id: created.id, isFavorite: true)
        try store.markPromptUsed(id: created.id, date: Date(timeIntervalSince1970: 100))
        guard let updated = try store.loadPrompts().first else {
            throw SelfTestError.failed("无法读取更新后的提示词")
        }
        try require(updated.title == "解释复杂概念", "提示词更新失败")
        try require(updated.groupName == "产品" && updated.variables.count == 2, "提示词分组或变量更新失败")
        try require(updated.isFavorite && updated.useCount == 1, "提示词收藏或使用次数更新失败")

        try store.deletePrompt(id: created.id)
        try require(try store.promptCount() == 0, "提示词删除失败")
    }

    try withStore { store in
        let first = try store.createPrompt(title: "第一", body: "a", groupName: "产品", variables: [])
        let second = try store.createPrompt(title: "第二", body: "b", groupName: "产品", variables: [])
        let third = try store.createPrompt(title: "第三", body: "c", groupName: "产品", variables: [])
        try store.setPromptOrder([third.id, first.id, second.id])
        try require(
            try store.loadPrompts().map(\.id) == [third.id, first.id, second.id],
            "提示词拖拽排序没有持久化"
        )
    }

    try require(
        AppVersion("v0.1.2")! > AppVersion("0.1.1")!,
        "更新版本比较失败"
    )
    try require(
        AppVersion("1.2.0")! == AppVersion("1.2")!,
        "版本号尾部零没有正确归一化"
    )

    let releaseJSON = """
    {
      "tag_name": "v0.1.2",
      "name": "Jaimo Flow 0.1.2",
      "body": "修复与优化",
      "html_url": "https://github.com/Jaimo-so/Jaimo-Flow/releases/tag/v0.1.2",
      "assets": [
        {
          "name": "Jaimo-Flow-0.1.2-macOS-Apple-Silicon.dmg",
          "browser_download_url": "https://github.com/Jaimo-so/Jaimo-Flow/releases/download/v0.1.2/Jaimo-Flow-0.1.2-macOS-Apple-Silicon.dmg",
          "digest": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        }
      ]
    }
    """
    let release = try JSONDecoder().decode(GitHubReleasePayload.self, from: Data(releaseJSON.utf8))
    let update = try release.availableUpdate(currentVersion: "0.1.1")
    try require(update?.version == "0.1.2", "GitHub Release 版本解析失败")
    try require(
        update?.expectedSHA256 == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        "GitHub Release SHA-256 解析失败"
    )
    try require(
        try release.availableUpdate(currentVersion: "0.1.2") == nil,
        "相同版本不应提示更新"
    )

    // API Key / 密码编辑器：生成密码与内容检查
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
    var seeded = SeededGenerator(state: 42)
    let fullOptions = PasswordOptions(length: 24)
    for _ in 0..<200 {
        let password = PasswordGenerator.generate(fullOptions, using: &seeded)
        try require(password.count == 24, "生成密码长度不正确")
        try require(password.contains { $0.isUppercase } && password.contains { $0.isLowercase }
            && password.contains { $0.isNumber } && password.contains { !$0.isLetter && !$0.isNumber },
            "生成密码没有覆盖所有已启用的字符类型")
        try require(!password.contains { "0Oo1lI|`'\" \\".contains($0) || $0.isWhitespace },
            "生成密码包含易混淆字符、引号、反斜杠或空白")
    }
    var digitsOnly = PasswordOptions(length: 3, includeUppercase: false, includeLowercase: false, includeSymbols: false, excludeAmbiguous: false)
    try require(digitsOnly.length == PasswordOptions.lengthRange.lowerBound, "密码长度没有限制在最小值")
    digitsOnly.length = 999
    try require(digitsOnly.length == PasswordOptions.lengthRange.upperBound, "密码长度没有限制在最大值")
    digitsOnly.length = 12
    let pin = PasswordGenerator.generate(digitsOnly, using: &seeded)
    try require(pin.count == 12 && pin.allSatisfy { $0.isNumber }, "仅数字选项生成了非数字字符")
    let noneSelected = PasswordOptions(length: 10, includeUppercase: false, includeLowercase: false, includeDigits: false, includeSymbols: false)
    try require(!noneSelected.hasAnyCharacterSet, "未选择任何字符类型时应提示")
    try require(PasswordGenerator.generate(noneSelected, using: &seeded).count == 10, "未选择字符类型时没有回退到默认字符集")
    try require(PasswordGenerator.generate() != PasswordGenerator.generate(), "两次生成得到相同密码")

    try require(SecretInspector.inspect("123456").strength == .weak, "弱密码强度判断错误")
    try require(SecretInspector.inspect("aaaaaaaaaaaaaaaaaaaaaaaa").strength == .weak, "重复字符密码被判为强")
    try require(SecretInspector.inspect(PasswordGenerator.generate(fullOptions, using: &seeded)).strength >= .strong, "24 位随机密码强度过低")
    try require(SecretInspector.inspect("sk-proj-AbCdEf0123456789XyZ0123456789abcdEF").strength == .veryStrong, "长 API Key 强度判断过低")
    let clean = SecretInspector.inspect("sk-abc")
    try require(clean.whitespaceWarning == nil && clean.characterCount == 6, "干净内容出现空白提示或字符数错误")
    let pasted = SecretInspector.inspect("sk-abc\n")
    try require(pasted.hasTrailingWhitespace && pasted.containsLineBreak && pasted.whitespaceWarning != nil, "没有发现结尾换行")
    try require(SecretInspector.inspect(" sk-abc").whitespaceWarning == "开头含有空格", "没有发现开头空格")
    try require(SecretInspector.trimmedEdges("  sk a b\n") == "sk a b", "去除首尾空白时改动了中间内容")
    try require(SecretInspector.inspect("").strength == .weak && SecretInspector.inspect("").whitespaceWarning == nil, "空内容检查结果错误")

    print("Jaimo Flow self-test passed: 47 checks")
} catch {
    fputs("Jaimo Flow self-test failed: \(error)\n", stderr)
    exit(1)
}
