import Foundation

public enum ClipKind: String, Codable, CaseIterable, Sendable {
    case text
    case code
    case image
    case link
}

public enum ClipCategory: String, Codable, CaseIterable, Sendable {
    case text
    case image
    case link
}

public struct MetaEntry: Codable, Hashable, Sendable {
    public let key: String
    public let value: String

    public init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }
}

public struct ClipItem: Identifiable, Hashable, Sendable {
    public let id: Int64
    public var kind: ClipKind
    public var category: ClipCategory
    public var isFavorite: Bool
    public var sourceAppName: String
    public var sourceBundleID: String
    public var copiedAt: Date
    public var title: String
    public var fullText: String?
    public var imagePath: URL?
    public var imageAlt: String?
    public var meta: [MetaEntry]
    public var contentHash: String

    public init(
        id: Int64 = 0,
        kind: ClipKind,
        category: ClipCategory,
        isFavorite: Bool = false,
        sourceAppName: String,
        sourceBundleID: String,
        copiedAt: Date = Date(),
        title: String,
        fullText: String? = nil,
        imagePath: URL? = nil,
        imageAlt: String? = nil,
        meta: [MetaEntry],
        contentHash: String
    ) {
        self.id = id
        self.kind = kind
        self.category = category
        self.isFavorite = isFavorite
        self.sourceAppName = sourceAppName
        self.sourceBundleID = sourceBundleID
        self.copiedAt = copiedAt
        self.title = title
        self.fullText = fullText
        self.imagePath = imagePath
        self.imageAlt = imageAlt
        self.meta = meta
        self.contentHash = contentHash
    }
}

public struct CapturedClip: Sendable {
    public let kind: ClipKind
    public let category: ClipCategory
    public let sourceAppName: String
    public let sourceBundleID: String
    public let copiedAt: Date
    public let title: String
    public let fullText: String?
    public let imageData: Data?
    public let imageFileExtension: String?
    public let imageAlt: String?
    public let meta: [MetaEntry]
    public let contentHash: String

    public init(
        kind: ClipKind,
        category: ClipCategory,
        sourceAppName: String,
        sourceBundleID: String,
        copiedAt: Date = Date(),
        title: String,
        fullText: String? = nil,
        imageData: Data? = nil,
        imageFileExtension: String? = nil,
        imageAlt: String? = nil,
        meta: [MetaEntry],
        contentHash: String
    ) {
        self.kind = kind
        self.category = category
        self.sourceAppName = sourceAppName
        self.sourceBundleID = sourceBundleID
        self.copiedAt = copiedAt
        self.title = title
        self.fullText = fullText
        self.imageData = imageData
        self.imageFileExtension = imageFileExtension
        self.imageAlt = imageAlt
        self.meta = meta
        self.contentHash = contentHash
    }
}

public enum ClipFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case text
    case image
    case link
    case favorite
    case apiKey

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "全部"
        case .text: return "文字"
        case .image: return "图片"
        case .link: return "链接"
        case .favorite: return "收藏"
        case .apiKey: return "API Key"
        }
    }
}

public enum ClipFlowPhase: Equatable, Sendable {
    case loading
    case ready
    case failed(String)
}

public extension ClipItem {
    var relativeTimeText: String {
        let calendar = Calendar.current
        let now = Date()
        let seconds = max(0, now.timeIntervalSince(copiedAt))
        if seconds < 60 { return "刚刚" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86_400 && calendar.isDateInToday(copiedAt) {
            return "\(Int(seconds / 3_600)) 小时前"
        }
        if calendar.isDateInYesterday(copiedAt) { return "昨天" }
        return Self.monthDayFormatter.string(from: copiedAt)
    }

    var detailedTimeText: String {
        let prefix: String
        if Calendar.current.isDateInToday(copiedAt) {
            prefix = "今天"
        } else if Calendar.current.isDateInYesterday(copiedAt) {
            prefix = "昨天"
        } else {
            prefix = Self.monthDayFormatter.string(from: copiedAt)
        }
        return "\(prefix) \(Self.timeFormatter.string(from: copiedAt))"
    }

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
