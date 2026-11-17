import Foundation

/// 剪切板文本记录的“转换后复制”操作。
///
/// 只在内存中转换并写入系统剪贴板，不修改历史记录本身。
/// 每个转换都是纯函数，便于在 SelfTest 中覆盖。
public enum ClipTextTransform: String, CaseIterable, Identifiable, Sendable {
    case trimWhitespace
    case joinLines
    case removeBlankLines
    case formatJSON
    case minifyJSON
    case uppercase
    case lowercase
    case urlDecode
    case urlEncode

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .trimWhitespace: return "去除首尾与行尾空白"
        case .joinLines: return "合并为一行"
        case .removeBlankLines: return "删除空行"
        case .formatJSON: return "格式化 JSON"
        case .minifyJSON: return "压缩 JSON"
        case .uppercase: return "转为大写"
        case .lowercase: return "转为小写"
        case .urlDecode: return "URL 解码"
        case .urlEncode: return "URL 编码"
        }
    }

    public var symbolName: String {
        switch self {
        case .trimWhitespace: return "scissors"
        case .joinLines: return "arrow.right.to.line"
        case .removeBlankLines: return "line.3.horizontal.decrease"
        case .formatJSON: return "curlybraces"
        case .minifyJSON: return "curlybraces.square"
        case .uppercase: return "textformat.size.larger"
        case .lowercase: return "textformat.size.smaller"
        case .urlDecode: return "link.badge.plus"
        case .urlEncode: return "link"
        }
    }

    /// 返回转换结果；不适用或结果与原文相同时返回 nil，界面据此隐藏该项。
    public func apply(to text: String) -> String? {
        let result: String?
        switch self {
        case .trimWhitespace:
            let lines = Self.lines(of: text).map { line -> String in
                var line = Substring(line)
                while let last = line.last, last == " " || last == "\t" { line.removeLast() }
                return String(line)
            }
            result = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        case .joinLines:
            let parts = Self.lines(of: text)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard parts.count > 1 else { return nil }
            result = parts.dropFirst().reduce(parts[0]) { joined, next in
                joined + (Self.needsSpace(between: joined, and: next) ? " " : "") + next
            }
        case .removeBlankLines:
            result = Self.lines(of: text)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .joined(separator: "\n")
        case .formatJSON:
            result = Self.reencodeJSON(text, pretty: true)
        case .minifyJSON:
            result = Self.reencodeJSON(text, pretty: false)
        case .uppercase:
            result = text.uppercased()
        case .lowercase:
            result = text.lowercased()
        case .urlDecode:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.contains("%") || trimmed.contains("+") else { return nil }
            result = trimmed.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
        case .urlEncode:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            result = trimmed.addingPercentEncoding(withAllowedCharacters: Self.urlQueryValueAllowed)
        }
        guard let result, !result.isEmpty, result != text else { return nil }
        return result
    }

    /// 当前文本可用的转换，按 allCases 顺序；结果相同的重复项只保留第一个。
    public static func available(for text: String, limit: Int = 200_000) -> [ClipTextTransform] {
        guard !text.isEmpty, text.utf8.count <= limit else { return [] }
        var seen = Set<String>()
        return allCases.filter { transform in
            guard let output = transform.apply(to: text) else { return false }
            return seen.insert(output).inserted
        }
    }

    private static func lines(of text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    /// 中文之间直接拼接，避免 PDF/网页复制的断行变成多余空格；英文单词之间补一个空格。
    private static func needsSpace(between left: String, and right: String) -> Bool {
        guard let last = left.unicodeScalars.last, let first = right.unicodeScalars.first else { return false }
        if last == "-" { return false }
        return !(isCJK(last) || isCJK(first))
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xF900...0xFAFF, 0xFF00...0xFFEF, 0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }

    /// 先用 JSONSerialization 校验，再逐字符重排空白：保留原始键顺序和数字写法。
    private static func reencodeJSON(_ text: String, pretty: Bool) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[",
              let data = trimmed.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else { return nil }

        let indentUnit = "  "
        let characters = Array(trimmed)
        var output = ""
        var depth = 0
        var index = 0
        var inString = false

        func nextSignificant(after position: Int) -> Character? {
            var cursor = position + 1
            while cursor < characters.count {
                let character = characters[cursor]
                if !character.isWhitespace { return character }
                cursor += 1
            }
            return nil
        }
        func newline() {
            output += "\n" + String(repeating: indentUnit, count: depth)
        }

        while index < characters.count {
            let character = characters[index]
            if inString {
                output.append(character)
                if character == "\\", index + 1 < characters.count {
                    index += 1
                    output.append(characters[index])
                } else if character == "\"" {
                    inString = false
                }
                index += 1
                continue
            }
            switch character {
            case "\"":
                inString = true
                output.append(character)
            case "{", "[":
                output.append(character)
                let close: Character = character == "{" ? "}" : "]"
                if nextSignificant(after: index) == close {
                    // 空对象/数组保持紧凑：{} 或 []
                    while index + 1 < characters.count, characters[index + 1] != close { index += 1 }
                    index += 1
                    output.append(close)
                } else {
                    depth += 1
                    if pretty { newline() }
                }
            case "}", "]":
                depth -= 1
                if pretty { newline() }
                output.append(character)
            case ",":
                output.append(character)
                if pretty { newline() }
            case ":":
                output += pretty ? ": " : ":"
            default:
                if !character.isWhitespace { output.append(character) }
            }
            index += 1
        }
        return output
    }

    private static let urlQueryValueAllowed: CharacterSet = {
        CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    }()
}
