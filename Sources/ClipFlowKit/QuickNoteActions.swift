import Foundation

/// Pure helpers behind the quick-note widget actions (copy, convert to memo,
/// clear with undo). Kept free of AppKit so the rules can be self-tested.
public enum QuickNoteActions {
    public struct MemoDraft: Equatable {
        public let title: String
        public let body: String

        public init(title: String, body: String) {
            self.title = title
            self.body = body
        }
    }

    public static let defaultTitleLimit = 30
    public static let defaultFallbackTitle = "快速便签"

    /// Builds a memo from the quick note. The first non-blank line becomes the
    /// title (list / heading / checkbox markers removed, long lines shortened).
    /// When the title is an exact copy of that line, the body holds the rest;
    /// otherwise the body keeps the full note so nothing is lost.
    /// Returns nil for blank notes.
    public static func memoDraft(
        from note: String,
        titleLimit: Int = defaultTitleLimit,
        fallbackTitle: String = defaultFallbackTitle
    ) -> MemoDraft? {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNote.isEmpty else { return nil }

        let lines = trimmedNote.components(separatedBy: .newlines)
        guard let firstIndex = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return nil }

        let rawLine = lines[firstIndex].trimmingCharacters(in: .whitespaces)
        let normalized = normalizedTitleLine(rawLine)
        let limit = max(titleLimit, 2)
        var title = normalized
        var truncated = false
        if title.count > limit {
            title = String(title.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
            truncated = true
        }
        if title.isEmpty {
            return MemoDraft(title: fallbackTitle, body: trimmedNote)
        }

        let titleIsVerbatim = !truncated && normalized == rawLine
        guard titleIsVerbatim else {
            return MemoDraft(title: title, body: trimmedNote)
        }
        let rest = lines[(firstIndex + 1)...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return MemoDraft(title: title, body: rest)
    }

    /// Strips leading Markdown-ish markers: `#`, `>`, `-`/`*`/`+`/`•`,
    /// `[ ]`/`[x]` checkboxes and ordered-list numbers (`1.` `2)` `3、`).
    public static func normalizedTitleLine(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        var changed = true
        while changed {
            changed = false
            for pattern in markerPatterns {
                if let range = text.range(of: pattern, options: .regularExpression), range.lowerBound == text.startIndex {
                    text = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    changed = true
                }
            }
        }
        return text
    }

    /// Visible characters, ignoring spaces and line breaks. Emoji and CJK each count once.
    public static func characterCount(_ note: String) -> Int {
        note.filter { !$0.isWhitespace && !$0.isNewline }.count
    }

    private static let markerPatterns = [
        #"^#{1,6}(\s+|$)"#,
        #"^>+\s*"#,
        #"^[-*+•·](\s+|$)"#,
        #"^\[[ xX✓]?\](\s+|$)"#,
        #"^\d{1,3}[.)、．](\s+|(?=\D))"#,
    ]
}

/// Remembers the most recently cleared quick note so the user can undo once.
public struct QuickNoteUndoBuffer: Equatable {
    public private(set) var clearedText: String?

    public init() {}

    public var canUndo: Bool { clearedText != nil }

    /// Records `text` as cleared. Blank text is not worth an undo and keeps
    /// any earlier buffer untouched.
    public mutating func recordClear(of text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        clearedText = text
    }

    /// Returns the text to restore. If the user has typed something new in the
    /// meantime the cleared text is appended below it instead of replacing it.
    public mutating func restore(into current: String) -> String? {
        guard let cleared = clearedText else { return nil }
        clearedText = nil
        let trimmedCurrent = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedCurrent.isEmpty { return cleared }
        return current.trimmingCharacters(in: .newlines) + "\n\n" + cleared
    }

    public mutating func discard() {
        clearedText = nil
    }
}
