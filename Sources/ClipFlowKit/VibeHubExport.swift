import Foundation

/// A plain snapshot of one Vibehub phrase, independent of the app's SwiftUI model,
/// so export and duplicate detection can be tested without AppKit.
public struct VibeHubPhraseSnapshot: Equatable, Sendable {
    public var id: String
    public var title: String
    public var phrase: String
    public var category: String
    public var tags: String
    public var scenario: String
    public var meaning: String
    public var isFavorite: Bool
    public var updatedAt: Date

    public init(id: String, title: String, phrase: String, category: String, tags: String,
                scenario: String, meaning: String, isFavorite: Bool, updatedAt: Date) {
        self.id = id
        self.title = title
        self.phrase = phrase
        self.category = category
        self.tags = tags
        self.scenario = scenario
        self.meaning = meaning
        self.isFavorite = isFavorite
        self.updatedAt = updatedAt
    }
}

/// Renders Vibehub phrases as a self-contained Markdown document.
public enum VibeHubMarkdown {
    /// Splits the free-form tag field (，,、;；/ or newlines) into trimmed, de-duplicated tags.
    public static func tags(from raw: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",，、;；/\n")
        var seen = Set<String>()
        return raw.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Wraps text in a fenced block whose fence is longer than any backtick run inside the text,
    /// so phrases that themselves contain ``` stay intact.
    public static func fenced(_ text: String) -> String {
        var longest = 0
        var current = 0
        for character in text {
            if character == "`" { current += 1; longest = max(longest, current) } else { current = 0 }
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        let body = text.hasSuffix("\n") ? String(text.dropLast()) : text
        return "\(fence)text\n\(body)\n\(fence)"
    }

    /// One phrase as a Markdown section. Empty optional fields are omitted.
    public static func section(_ item: VibeHubPhraseSnapshot, headingLevel: Int = 3) -> String {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let hashes = String(repeating: "#", count: min(max(headingLevel, 1), 6))
        var lines = ["\(hashes) \(title.isEmpty ? "无标题话术" : singleLine(title))\(item.isFavorite ? " ★" : "")"]
        var meta = ["分类：\(item.category)"]
        let tagList = tags(from: item.tags)
        if !tagList.isEmpty { meta.append("标签：" + tagList.map { "`\($0)`" }.joined(separator: " ")) }
        lines.append("")
        lines.append(meta.joined(separator: " · "))
        lines.append("")
        let phrase = item.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(phrase.isEmpty ? "_（话术原文为空）_" : fenced(item.phrase))
        let scenario = item.scenario.trimmingCharacters(in: .whitespacesAndNewlines)
        if !scenario.isEmpty {
            lines.append("")
            lines.append("**适用场景**")
            lines.append("")
            lines.append(item.scenario.trimmingCharacters(in: .newlines))
        }
        let meaning = item.meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        if !meaning.isEmpty {
            lines.append("")
            lines.append("**术语与含义**")
            lines.append("")
            lines.append(item.meaning.trimmingCharacters(in: .newlines))
        }
        return lines.joined(separator: "\n")
    }

    /// Full document grouped by category. Categories follow `categoryOrder`; unknown ones are appended
    /// in first-seen order. Phrases keep their input order within a category.
    public static func document(
        _ items: [VibeHubPhraseSnapshot],
        title: String,
        categoryOrder: [String] = [],
        exportedAt: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        var order = categoryOrder
        for item in items where !order.contains(item.category) { order.append(item.category) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var parts = ["# \(singleLine(title))", "",
                     "> 由 Jaimo Flow Vibehub 导出 · \(formatter.string(from: exportedAt)) · 共 \(items.count) 条话术"]
        for category in order {
            let group = items.filter { $0.category == category }
            guard !group.isEmpty else { continue }
            parts.append("")
            parts.append("## \(category)（\(group.count)）")
            for item in group {
                parts.append("")
                parts.append(section(item))
            }
        }
        return parts.joined(separator: "\n") + "\n"
    }

    /// File name without characters that Finder or other systems reject.
    public static func suggestedFileName(scopeTitle: String, date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleanScope = scopeTitle.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        let scopePart = cleanScope.isEmpty ? "" : " \(cleanScope)"
        return "Vibehub 话术\(scopePart) \(formatter.string(from: date)).md"
    }

    private static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Finds phrases whose original text is (nearly) the same, so the library does not silently
/// accumulate duplicates of the same instruction.
public enum VibeHubSimilarity {
    public struct Match: Equatable, Sendable {
        public let id: String
        public let score: Double
        public init(id: String, score: Double) { self.id = id; self.score = score }
    }

    public static let defaultThreshold = 0.82
    /// Very short phrases produce noisy bigram scores; below this they must match exactly.
    public static let minimumFuzzyLength = 6

    /// Lowercased, width-folded text with whitespace and punctuation removed.
    public static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
        let drop = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { !drop.contains($0) }))
    }

    /// Sørensen–Dice coefficient over character bigrams of the normalized text (0...1).
    public static func score(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(normalized(lhs)), b = Array(normalized(rhs))
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        guard a.count >= minimumFuzzyLength, b.count >= minimumFuzzyLength else { return 0 }
        var counts: [String: Int] = [:]
        for index in 0..<(a.count - 1) { counts[String(a[index...index + 1]), default: 0] += 1 }
        var overlap = 0
        for index in 0..<(b.count - 1) {
            let key = String(b[index...index + 1])
            if let count = counts[key], count > 0 { overlap += 1; counts[key] = count - 1 }
        }
        return Double(2 * overlap) / Double(a.count - 1 + b.count - 1)
    }

    /// Other phrases similar to `target`, best match first. Empty phrases never match.
    public static func matches(
        for target: VibeHubPhraseSnapshot,
        in candidates: [VibeHubPhraseSnapshot],
        threshold: Double = defaultThreshold,
        limit: Int = 3
    ) -> [Match] {
        guard !normalized(target.phrase).isEmpty else { return [] }
        return candidates
            .filter { $0.id != target.id }
            .map { Match(id: $0.id, score: score(target.phrase, $0.phrase)) }
            .filter { $0.score >= threshold }
            .sorted { $0.score > $1.score }
            .prefix(max(limit, 0))
            .map { $0 }
    }
}
