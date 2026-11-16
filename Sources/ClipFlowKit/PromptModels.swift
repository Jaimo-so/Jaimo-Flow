import Foundation

public struct PromptVariable: Codable, Hashable, Sendable {
    public var name: String
    public var defaultValue: String
    public var isRequired: Bool

    public init(name: String, defaultValue: String = "", isRequired: Bool = true) {
        self.name = name
        self.defaultValue = defaultValue
        self.isRequired = isRequired
    }
}

public struct PromptItem: Identifiable, Hashable, Sendable {
    public let id: Int64
    public var title: String
    public var body: String
    public var groupName: String
    public var isFavorite: Bool
    public var variables: [PromptVariable]
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?
    public var useCount: Int
    public var sortOrder: Int

    public init(
        id: Int64 = 0,
        title: String,
        body: String,
        groupName: String = "未分组",
        isFavorite: Bool = false,
        variables: [PromptVariable] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastUsedAt: Date? = nil,
        useCount: Int = 0,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.groupName = groupName
        self.isFavorite = isFavorite
        self.variables = variables
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
        self.sortOrder = sortOrder
    }
}

public enum PromptTemplate {
    private static let expression = try! NSRegularExpression(
        pattern: #"\{\{\s*([^{}]+?)\s*\}\}"#
    )

    public static func variableNames(in body: String) -> [String] {
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        var seen = Set<String>()
        var names: [String] = []

        for match in expression.matches(in: body, range: range) {
            guard let captureRange = Range(match.range(at: 1), in: body) else { continue }
            let name = body[captureRange].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            names.append(name)
        }
        return names
    }

    public static func variables(
        in body: String,
        preserving existing: [PromptVariable] = []
    ) -> [PromptVariable] {
        let previous = Dictionary(uniqueKeysWithValues: existing.map { ($0.name, $0) })
        return variableNames(in: body).map { previous[$0] ?? PromptVariable(name: $0) }
    }

    public static func render(_ body: String, values: [String: String]) -> String {
        let fullRange = NSRange(body.startIndex..<body.endIndex, in: body)
        let matches = expression.matches(in: body, range: fullRange)
        var result = body

        for match in matches.reversed() {
            guard let tokenRange = Range(match.range(at: 0), in: result),
                  let nameRange = Range(match.range(at: 1), in: result) else { continue }
            let name = result[nameRange].trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = values[name] {
                result.replaceSubrange(tokenRange, with: value)
            }
        }
        return result
    }
}

/// 提示词变量的“上次填写”记忆与副本命名等与平台无关的逻辑。
public enum PromptVariableMemory {
    /// 每个变量记住的最大字符数，避免把超长粘贴内容写入偏好设置。
    public static let maxRememberedLength = 4_000

    /// 打开变量面板时的初始值：优先使用上次填写的非空值，否则使用默认值。
    public static func initialValues(
        for variables: [PromptVariable],
        remembered: [String: String]
    ) -> [String: String] {
        Dictionary(
            variables.map { variable -> (String, String) in
                let last = remembered[variable.name] ?? ""
                let usable = !last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                return (variable.name, usable ? last : variable.defaultValue)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// 只保留当前模板中仍存在、与默认值不同且非空的变量值。
    public static func valuesToRemember(
        _ values: [String: String],
        variables: [PromptVariable]
    ) -> [String: String] {
        var result: [String: String] = [:]
        for variable in variables {
            guard let value = values[variable.name],
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value != variable.defaultValue,
                  value.count <= maxRememberedLength else { continue }
            result[variable.name] = value
        }
        return result
    }

    /// 当前填写是否与默认值不同（用于显示“恢复默认值”）。
    public static func differsFromDefaults(
        _ values: [String: String],
        variables: [PromptVariable]
    ) -> Bool {
        variables.contains { (values[$0.name] ?? "") != $0.defaultValue }
    }

    /// 尚未填写的必填变量名，按模板中出现的顺序返回。
    public static func missingRequired(
        _ values: [String: String],
        variables: [PromptVariable]
    ) -> [String] {
        variables.filter { variable in
            variable.isRequired
                && (values[variable.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.map(\.name)
    }

    /// 生成不与现有标题重复的副本标题：「标题 副本」「标题 副本 2」……
    public static func duplicateTitle(for title: String, existingTitles: [String]) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var base = trimmed.isEmpty ? "未命名提示词" : trimmed
        // 对副本再建副本时沿用同一个基础标题，避免出现「副本 副本」。
        if let range = base.range(of: #" 副本( \d+)?$"#, options: .regularExpression) {
            base = String(base[..<range.lowerBound])
        }
        let taken = Set(existingTitles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        let first = "\(base) 副本"
        if !taken.contains(first) { return first }
        var index = 2
        while taken.contains("\(base) 副本 \(index)") { index += 1 }
        return "\(base) 副本 \(index)"
    }
}
