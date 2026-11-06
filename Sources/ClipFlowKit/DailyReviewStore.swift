import Foundation

public struct DailyReviewEntry: Codable, Equatable, Identifiable {
    public let dateKey: String
    public let body: String
    public let updatedAt: Date

    public var id: String { dateKey }

    public init(dateKey: String, body: String, updatedAt: Date) {
        self.dateKey = dateKey
        self.body = body
        self.updatedAt = updatedAt
    }
}

/// One complete, unabridged note per local calendar date.
public final class DailyReviewStore {
    public enum StoreError: Error {
        case emptyContent
        case missingEntry
    }

    public private(set) var entries: [DailyReviewEntry]
    public let fileURL: URL

    public init(fileURL: URL? = nil) throws {
        self.fileURL = fileURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
            .appendingPathComponent("ClipFlow", isDirectory: true)
            .appendingPathComponent("DailyReviews", isDirectory: true)
            .appendingPathComponent("reviews.json")
        if FileManager.default.fileExists(atPath: self.fileURL.path) {
            entries = try JSONDecoder().decode([DailyReviewEntry].self, from: Data(contentsOf: self.fileURL))
        } else {
            entries = []
        }
    }

    public func entry(for dateKey: String) -> DailyReviewEntry? {
        entries.first { $0.dateKey == dateKey }
    }

    @discardableResult
    public func save(dateKey: String, body: String, now: Date = .now) throws -> DailyReviewEntry {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoreError.emptyContent
        }
        let entry = DailyReviewEntry(dateKey: dateKey, body: body, updatedAt: now)
        var next = entries.filter { $0.dateKey != dateKey }
        next.append(entry)
        next.sort { $0.dateKey > $1.dateKey }
        try persist(next)
        return entry
    }

    @discardableResult
    public func delete(dateKey: String) throws -> DailyReviewEntry {
        guard let removed = entries.first(where: { $0.dateKey == dateKey }) else {
            throw StoreError.missingEntry
        }
        let next = entries.filter { $0.dateKey != dateKey }
        try persist(next)
        return removed
    }

    private func persist(_ next: [DailyReviewEntry]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(next).write(to: fileURL, options: .atomic)
        entries = next
    }
}
