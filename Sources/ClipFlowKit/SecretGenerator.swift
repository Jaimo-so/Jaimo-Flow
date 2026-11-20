import Foundation

/// Options for generating a random password in the API Key / password editor.
public struct PasswordOptions: Equatable, Codable {
    public static let lengthRange: ClosedRange<Int> = 8...64
    public static let `default` = PasswordOptions()

    public var length: Int {
        didSet { length = PasswordOptions.clampLength(length) }
    }
    public var includeUppercase: Bool
    public var includeLowercase: Bool
    public var includeDigits: Bool
    public var includeSymbols: Bool
    /// Leaves out characters that are easy to misread, such as 0/O and 1/l/I.
    public var excludeAmbiguous: Bool

    public init(
        length: Int = 20,
        includeUppercase: Bool = true,
        includeLowercase: Bool = true,
        includeDigits: Bool = true,
        includeSymbols: Bool = true,
        excludeAmbiguous: Bool = true
    ) {
        self.length = PasswordOptions.clampLength(length)
        self.includeUppercase = includeUppercase
        self.includeLowercase = includeLowercase
        self.includeDigits = includeDigits
        self.includeSymbols = includeSymbols
        self.excludeAmbiguous = excludeAmbiguous
    }

    public static func clampLength(_ value: Int) -> Int {
        min(max(value, lengthRange.lowerBound), lengthRange.upperBound)
    }

    static let ambiguous: Set<Character> = ["0", "O", "o", "1", "l", "I", "|", "`", "'", "\""]

    /// Character groups enabled by the options. Falls back to lowercase + digits when everything is off.
    public var characterGroups: [[Character]] {
        var groups: [String] = []
        if includeUppercase { groups.append("ABCDEFGHIJKLMNOPQRSTUVWXYZ") }
        if includeLowercase { groups.append("abcdefghijklmnopqrstuvwxyz") }
        if includeDigits { groups.append("0123456789") }
        // Avoid quotes, backslash and whitespace so the result pastes safely into shells and .env files.
        if includeSymbols { groups.append("!#$%&()*+,-./:;<=>?@[]^_{}~") }
        if groups.isEmpty { groups = ["abcdefghijklmnopqrstuvwxyz", "0123456789"] }
        return groups.map { group in
            let characters = Array(group)
            return excludeAmbiguous ? characters.filter { !PasswordOptions.ambiguous.contains($0) } : characters
        }
    }

    public var hasAnyCharacterSet: Bool {
        includeUppercase || includeLowercase || includeDigits || includeSymbols
    }
}

public enum PasswordGenerator {
    public static func generate(_ options: PasswordOptions = .default) -> String {
        var rng = SystemRandomNumberGenerator()
        return generate(options, using: &rng)
    }

    /// Generates a password that contains at least one character from every enabled group.
    public static func generate<R: RandomNumberGenerator>(_ options: PasswordOptions, using rng: inout R) -> String {
        let groups = options.characterGroups
        let pool = groups.flatMap { $0 }
        let length = max(PasswordOptions.clampLength(options.length), groups.count)
        var characters: [Character] = groups.map { $0.randomElement(using: &rng)! }
        while characters.count < length {
            characters.append(pool.randomElement(using: &rng)!)
        }
        characters.shuffle(using: &rng)
        return String(characters)
    }
}

public enum SecretStrength: Int, Comparable, CaseIterable {
    case weak, fair, strong, veryStrong

    public static func < (lhs: SecretStrength, rhs: SecretStrength) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .weak: return "弱"
        case .fair: return "一般"
        case .strong: return "强"
        case .veryStrong: return "很强"
        }
    }
}

public struct SecretInspection: Equatable {
    public let characterCount: Int
    /// Rough upper-bound entropy estimate: length × log2(character pool size).
    public let estimatedBits: Int
    public let strength: SecretStrength
    public let hasLeadingWhitespace: Bool
    public let hasTrailingWhitespace: Bool
    public let containsLineBreak: Bool

    public var hasEdgeWhitespace: Bool { hasLeadingWhitespace || hasTrailingWhitespace }

    /// Short warning shown under the editor field, or nil when the value looks clean.
    public var whitespaceWarning: String? {
        if containsLineBreak && hasEdgeWhitespace { return "首尾含空格或换行，粘贴时常被一起带入" }
        if containsLineBreak { return "内容中含有换行" }
        if hasLeadingWhitespace && hasTrailingWhitespace { return "开头和结尾含有空格" }
        if hasLeadingWhitespace { return "开头含有空格" }
        if hasTrailingWhitespace { return "结尾含有空格" }
        return nil
    }
}

public enum SecretInspector {
    public static func inspect(_ secret: String) -> SecretInspection {
        let scalars = secret.unicodeScalars
        var lower = false, upper = false, digit = false, symbol = false, other = false
        for scalar in scalars {
            switch scalar {
            case "a"..."z": lower = true
            case "A"..."Z": upper = true
            case "0"..."9": digit = true
            case "!"..."~": symbol = true
            default: other = true
            }
        }
        var pool = 0
        if lower { pool += 26 }
        if upper { pool += 26 }
        if digit { pool += 10 }
        if symbol { pool += 32 }
        if other { pool += 100 }
        let count = secret.count
        let distinct = Set(secret).count
        var bits = pool > 1 ? Double(count) * log2(Double(pool)) : 0
        // Repeated characters (e.g. "aaaaaaaa") carry far less entropy than the formula suggests.
        if count > 0 && distinct * 2 < count {
            bits *= Double(distinct) / Double(count)
        }
        let estimatedBits = Int(bits.rounded(.down))
        let strength: SecretStrength
        switch estimatedBits {
        case ..<40: strength = .weak
        case ..<60: strength = .fair
        case ..<100: strength = .strong
        default: strength = .veryStrong
        }
        let first = secret.first, last = secret.last
        return SecretInspection(
            characterCount: count,
            estimatedBits: estimatedBits,
            strength: strength,
            hasLeadingWhitespace: first.map { $0.isWhitespace } ?? false,
            hasTrailingWhitespace: last.map { $0.isWhitespace } ?? false,
            containsLineBreak: secret.contains { $0.isNewline }
        )
    }

    /// Removes leading/trailing spaces and line breaks only; inner characters are untouched.
    public static func trimmedEdges(_ secret: String) -> String {
        secret.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
