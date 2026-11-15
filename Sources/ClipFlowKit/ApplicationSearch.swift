import Foundation

/// Precomputed, locale-independent search keys for one application.
///
/// Keys are built once when the catalog is scanned (off the main thread), so
/// typing in the search field only compares short folded strings.
public struct ApplicationSearchKey: Equatable, Sendable {
    /// Folded (case/diacritic/width-insensitive) names, e.g. display and bundle name.
    public let names: [String]
    /// Words of each name, split on separators, camelCase and letter/digit boundaries.
    public let words: [String]
    /// First letters of the words of each name, e.g. "vsc" for "Visual Studio Code".
    public let initials: [String]
    /// Toneless pinyin without spaces for names containing Chinese, e.g. "weixin".
    public let pinyin: [String]
    /// Pinyin syllables, used for matching at syllable boundaries.
    public let pinyinSyllables: [String]
    /// Pinyin initials, e.g. "wx" for "微信", "qyl" for "QQ音乐".
    public let pinyinInitials: [String]
    /// Folded bundle identifier.
    public let identifier: String

    public init(names: [String], identifier: String) {
        var folded: [String] = []
        var words: [String] = []
        var initials: [String] = []
        var pinyin: [String] = []
        var syllables: [String] = []
        var pinyinInitials: [String] = []

        for name in names {
            let foldedName = ApplicationSearch.fold(name)
            guard !foldedName.isEmpty, !folded.contains(foldedName) else { continue }
            folded.append(foldedName)

            let nameWords = ApplicationSearch.words(in: name)
            words.append(contentsOf: nameWords)
            if nameWords.count > 1, !ApplicationSearch.containsHan(name) {
                initials.append(String(nameWords.compactMap(\.first)))
            }

            if ApplicationSearch.containsHan(name),
               let latin = name.applyingTransform(.mandarinToLatin, reverse: false) {
                let parts = ApplicationSearch.words(in: latin)
                guard !parts.isEmpty else { continue }
                pinyin.append(parts.joined())
                syllables.append(contentsOf: parts)
                pinyinInitials.append(String(parts.compactMap(\.first)))
            }
        }

        self.names = folded
        self.words = words
        self.initials = initials
        self.pinyin = pinyin
        self.pinyinSyllables = syllables
        self.pinyinInitials = pinyinInitials
        self.identifier = ApplicationSearch.fold(identifier)
    }
}

public enum ApplicationSearch {
    /// Higher is a better match; `nil` means the application does not match.
    public static func score(query rawQuery: String, key: ApplicationSearchKey) -> Int? {
        let query = fold(rawQuery)
        guard !query.isEmpty else { return 0 }
        let compact = query.filter { !$0.isWhitespace }
        var best: Int?
        func consider(_ value: Int) { best = max(best ?? value, value) }

        for name in key.names {
            if name == query { consider(1_000) }
            else if name.hasPrefix(query) { consider(900) }
            else if name.contains(query) { consider(400) }
        }
        if key.words.contains(where: { $0.hasPrefix(query) }) { consider(750) }
        if compact.count >= 2, key.initials.contains(where: { $0.hasPrefix(compact) }) { consider(700) }
        if key.pinyin.contains(where: { $0.hasPrefix(compact) }) { consider(650) }
        if compact.count >= 2, key.pinyinInitials.contains(where: { $0.hasPrefix(compact) }) { consider(600) }
        if key.pinyinSyllables.contains(where: { $0.hasPrefix(compact) }) { consider(550) }

        // "studio code", "yun yin": every token starts a word or syllable.
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.count > 1 {
            let starts = key.words + key.pinyinSyllables
            if tokens.allSatisfy({ token in starts.contains { $0.hasPrefix(token) } }) { consider(500) }
        }

        if compact.count >= 2, key.pinyin.contains(where: { $0.contains(compact) }) { consider(300) }
        if query.count >= 3, key.identifier.contains(query) { consider(100) }
        return best
    }

    /// Filters and orders `items` by match quality. Equal scores are ordered by
    /// `areInIncreasingOrder` (when given), then keep their original order.
    public static func rank<Item>(
        _ items: [Item],
        query: String,
        key: (Item) -> ApplicationSearchKey,
        areInIncreasingOrder: ((Item, Item) -> Bool)? = nil
    ) -> [Item] {
        guard !fold(query).isEmpty else { return items }
        let scored = items.enumerated().compactMap { offset, item -> (Int, Int, Item)? in
            guard let score = score(query: query, key: key(item)) else { return nil }
            return (score, offset, item)
        }
        return scored.sorted { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 > rhs.0 }
            if let areInIncreasingOrder {
                if areInIncreasingOrder(lhs.2, rhs.2) { return true }
                if areInIncreasingOrder(rhs.2, lhs.2) { return false }
            }
            return lhs.1 < rhs.1
        }.map(\.2)
    }

    static func fold(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func containsHan(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
                || (0x20000...0x2FA1F).contains(scalar.value)
        }
    }

    /// Splits on non-alphanumerics, lower→upper camelCase, and letter/digit changes.
    static func words(in value: String) -> [String] {
        var result: [String] = []
        var current = ""
        var previous: Character?

        func flush() {
            let folded = fold(current)
            if !folded.isEmpty { result.append(folded) }
            current = ""
        }

        for character in value {
            guard character.isLetter || character.isNumber else {
                flush()
                previous = nil
                continue
            }
            if let previous {
                let camel = previous.isLowercase && character.isUppercase
                let digitChange = previous.isNumber != character.isNumber
                let hanChange = containsHan(String(previous)) != containsHan(String(character))
                if camel || digitChange || hanChange { flush() }
            }
            current.append(character)
            previous = character
        }
        flush()
        return result
    }
}
