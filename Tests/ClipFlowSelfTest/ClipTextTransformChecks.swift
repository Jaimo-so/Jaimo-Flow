import ClipFlowKit
import Foundation

/// 剪切板“转换后复制”的纯逻辑检查。返回检查条数，便于在汇总里计数。
func runClipTextTransformChecks() throws -> Int {
    var checks = 0
    func expect(_ condition: Bool, _ message: String) throws {
        checks += 1
        try require(condition, message)
    }

    try expect(ClipTextTransform.trimWhitespace.apply(to: "  hello  \n world\t \n\n") == "hello\n world",
               "去除首尾与行尾空白失败")
    try expect(ClipTextTransform.trimWhitespace.apply(to: "clean") == nil, "无变化时不应提供去空白")

    try expect(ClipTextTransform.joinLines.apply(to: "hello\nworld\n\n again ") == "hello world again",
               "英文合并为一行时应补空格")
    try expect(ClipTextTransform.joinLines.apply(to: "这是 PDF\n里复制的\r\n一段话。") == "这是 PDF里复制的一段话。",
               "中文合并为一行时不应插入多余空格")
    try expect(ClipTextTransform.joinLines.apply(to: "auto-\nmatic") == "auto-matic", "连字符结尾不应补空格")
    try expect(ClipTextTransform.joinLines.apply(to: "单行") == nil, "单行文本不应提供合并")

    try expect(ClipTextTransform.removeBlankLines.apply(to: "a\n\n  \nb\n") == "a\nb", "删除空行失败")

    let json = #"{"name":"Jaimo","tags":["a","b"],"empty":{},"list":[],"url":"https://x.y/z","n":1.50,"s":"含 \"引号\", 与 {括号}"}"#
    let formatted = ClipTextTransform.formatJSON.apply(to: json)
    try expect(formatted == """
    {
      "name": "Jaimo",
      "tags": [
        "a",
        "b"
      ],
      "empty": {},
      "list": [],
      "url": "https://x.y/z",
      "n": 1.50,
      "s": "含 \\"引号\\", 与 {括号}"
    }
    """, "格式化 JSON 应保留键顺序、数字写法和字符串内的符号")
    try expect(formatted.flatMap { ClipTextTransform.minifyJSON.apply(to: $0) } == json, "压缩 JSON 应还原紧凑写法")
    try expect(ClipTextTransform.formatJSON.apply(to: "{not json}") == nil, "非法 JSON 不应提供格式化")
    try expect(ClipTextTransform.formatJSON.apply(to: "42") == nil, "非对象/数组不应提供格式化")

    try expect(ClipTextTransform.uppercase.apply(to: "abc 中文") == "ABC 中文", "转大写失败")
    try expect(ClipTextTransform.uppercase.apply(to: "纯中文") == nil, "无大小写变化时不应提供转大写")
    try expect(ClipTextTransform.lowercase.apply(to: "ABC") == "abc", "转小写失败")

    try expect(ClipTextTransform.urlDecode.apply(to: "q=%E4%BD%A0%E5%A5%BD+world") == "q=你好 world", "URL 解码失败")
    try expect(ClipTextTransform.urlDecode.apply(to: "plain") == nil, "无编码字符时不应提供解码")
    try expect(ClipTextTransform.urlEncode.apply(to: "你好 a&b=c") == "%E4%BD%A0%E5%A5%BD%20a%26b%3Dc", "URL 编码失败")

    let available = ClipTextTransform.available(for: "Hello\nWorld")
    try expect(available.contains(.joinLines) && available.contains(.uppercase) && !available.contains(.formatJSON),
               "可用转换列表不正确")
    try expect(ClipTextTransform.available(for: "").isEmpty, "空文本不应提供转换")
    try expect(ClipTextTransform.available(for: String(repeating: "a", count: 10), limit: 5).isEmpty,
               "超长文本应跳过转换以免卡顿")
    return checks
}
