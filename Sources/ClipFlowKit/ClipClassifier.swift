import CryptoKit
import Foundation

public enum ClipClassifier {
    private static let codeMarkers = [
        "{", "}", "=>", "func ", "const ", "let ", "var ", "class ",
        "struct ", "import ", "return ", "def ", "public ", "private ", "#include"
    ]

    public static func classify(text: String) -> (kind: ClipKind, category: ClipCategory) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: trimmed),
           let scheme = components.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           components.host != nil {
            return (.link, .link)
        }

        let isMultiline = trimmed.contains("\n")
        let markerCount = codeMarkers.reduce(into: 0) { result, marker in
            if trimmed.contains(marker) { result += 1 }
        }
        if isMultiline && markerCount > 0 {
            return (.code, .text)
        }
        return (.text, .text)
    }

    /// 返回可安全交给浏览器打开的网址：仅接受带主机名的 http/https 链接，其余内容返回 nil。
    public static func openableURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isWhitespace }),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return nil }
        return components.url
    }

    public static func title(for text: String, maxLength: Int = 100) -> String {
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maxLength else { return collapsed }
        let end = collapsed.index(collapsed.startIndex, offsetBy: maxLength)
        return String(collapsed[..<end]) + "…"
    }

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func textMeta(text: String, kind: ClipKind) -> [MetaEntry] {
        let lines = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
        return [
            MetaEntry("类型", "纯文本"),
            MetaEntry("字符数", "\(text.count)"),
            MetaEntry("行数", "\(lines)")
        ]
    }

    public static func linkMeta(urlString: String) -> [MetaEntry] {
        var entries = [MetaEntry("类型", "网址")]
        if let host = URLComponents(string: urlString)?.host {
            entries.append(MetaEntry("域名", host))
        }
        return entries
    }

    public static func formattedByteCount(_ count: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(count))
    }
}
