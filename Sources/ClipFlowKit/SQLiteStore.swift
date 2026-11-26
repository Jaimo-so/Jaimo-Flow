import CSQLite
import Foundation

public enum ClipStoreError: LocalizedError {
    case applicationSupportUnavailable
    case openDatabase(String)
    case execute(String)
    case prepare(String)
    case bind(String)
    case decode(String)

    public var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "无法访问应用支持目录"
        case .openDatabase(let message):
            return "无法打开本地数据库：\(message)"
        case .execute(let message):
            return "数据库写入失败：\(message)"
        case .prepare(let message):
            return "数据库查询失败：\(message)"
        case .bind(let message):
            return "数据库参数错误：\(message)"
        case .decode(let message):
            return "数据库内容无法解析：\(message)"
        }
    }
}

public final class SQLiteClipStore {
    public static let defaultHistoryLimit = 150
    private static let clipColumns = """
    id, kind, category, isFavorite, sourceAppName, sourceBundleID,
    copiedAt, title, fullText, imagePath, imageAlt, meta, contentHash
    """

    private let databaseURL: URL
    private let imagesURL: URL
    private var database: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(baseDirectory: URL? = nil) throws {
        let root: URL
        if let baseDirectory {
            root = baseDirectory
        } else {
            root = try Self.defaultDirectory()
        }

        databaseURL = root.appendingPathComponent("ClipFlow.sqlite3", isDirectory: false)
        imagesURL = root.appendingPathComponent("Images", isDirectory: true)

        try FileManager.default.createDirectory(
            at: imagesURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(databaseURL.path, &database, flags, nil) != SQLITE_OK {
            let message = databaseMessage
            sqlite3_close(database)
            database = nil
            throw ClipStoreError.openDatabase(message)
        }

        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = NORMAL;")
        try execute("PRAGMA busy_timeout = 1500;")
        try execute("PRAGMA foreign_keys = ON;")
        try migrate()
    }

    public static func resetDefaultStorage() throws {
        let directory = try defaultDirectory()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    private static func defaultDirectory() throws -> URL {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ClipStoreError.applicationSupportUnavailable
        }
        return support.appendingPathComponent("ClipFlow", isDirectory: true)
    }

    deinit {
        sqlite3_close(database)
    }

    public func loadAll() throws -> [ClipItem] {
        let sql = """
        SELECT \(Self.clipColumns)
        FROM clips
        ORDER BY copiedAt DESC, id DESC;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        var items: [ClipItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            items.append(try decodeItem(statement))
        }
        return items
    }

    public func latestContentHash() throws -> String? {
        let statement = try prepare("SELECT contentHash FROM clips ORDER BY copiedAt DESC, id DESC LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return string(statement, column: 0)
        case SQLITE_DONE: return nil
        default: throw ClipStoreError.execute(databaseMessage)
        }
    }

    @discardableResult
    public func insert(
        _ captured: CapturedClip,
        limit: Int = SQLiteClipStore.defaultHistoryLimit
    ) throws -> ClipItem? {
        try insertWithHistoryChanges(captured, limit: limit)?.item
    }

    public func insertWithHistoryChanges(
        _ captured: CapturedClip,
        limit: Int = SQLiteClipStore.defaultHistoryLimit
    ) throws -> (item: ClipItem, evictedIDs: Set<Int64>)? {
        var storedImageURL: URL?
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            if try latestContentHash() == captured.contentHash {
                try execute("COMMIT;")
                return nil
            }
            if let data = captured.imageData {
                let ext = sanitizedExtension(captured.imageFileExtension ?? "png")
                let fileURL = imagesURL.appendingPathComponent("\(UUID().uuidString).\(ext)")
                try data.write(to: fileURL, options: [.atomic])
                storedImageURL = fileURL
            }
            let item = try insertRow(captured, imageURL: storedImageURL)
            let victims = try removeOverflowHistory(limit)
            try execute("COMMIT;")
            removeImages(victims.compactMap(\.imageURL))
            return (item, Set(victims.map(\.id)))
        } catch {
            try? execute("ROLLBACK;")
            if let storedImageURL {
                try? FileManager.default.removeItem(at: storedImageURL)
            }
            throw error
        }
    }

    private func insertRow(_ captured: CapturedClip, imageURL: URL?) throws -> ClipItem {
        let statement = try prepare("""
        INSERT INTO clips (
            kind, category, isFavorite, sourceAppName, sourceBundleID, copiedAt,
            title, fullText, imagePath, imageAlt, meta, contentHash
        ) VALUES (?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        RETURNING \(Self.clipColumns);
        """)
        defer { sqlite3_finalize(statement) }

        let metaJSON = String(decoding: try encoder.encode(captured.meta), as: UTF8.self)
        try bind(captured.kind.rawValue, to: statement, at: 1)
        try bind(captured.category.rawValue, to: statement, at: 2)
        try bind(captured.sourceAppName, to: statement, at: 3)
        try bind(captured.sourceBundleID, to: statement, at: 4)
        sqlite3_bind_double(statement, 5, captured.copiedAt.timeIntervalSince1970)
        try bind(captured.title, to: statement, at: 6)
        try bindOptional(captured.fullText, to: statement, at: 7)
        try bindOptional(imageURL?.lastPathComponent, to: statement, at: 8)
        try bindOptional(captured.imageAlt, to: statement, at: 9)
        try bind(metaJSON, to: statement, at: 10)
        try bind(captured.contentHash, to: statement, at: 11)

        guard sqlite3_step(statement) == SQLITE_ROW else { throw ClipStoreError.execute(databaseMessage) }
        let item = try decodeItem(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ClipStoreError.execute(databaseMessage) }
        return item
    }

    public func setFavorite(id: Int64, isFavorite: Bool, limit: Int = SQLiteClipStore.defaultHistoryLimit) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let statement = try prepare("UPDATE clips SET isFavorite = ? WHERE id = ?;")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, isFavorite ? 1 : 0)
            sqlite3_bind_int64(statement, 2, id)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ClipStoreError.execute(databaseMessage)
            }
            let victims = isFavorite ? [] : try removeOverflowHistory(limit)
            try execute("COMMIT;")
            removeImages(victims.compactMap(\.imageURL))
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func delete(id: Int64) throws {
        let imagePath = try imagePath(for: id)
        let statement = try prepare("DELETE FROM clips WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ClipStoreError.execute(databaseMessage)
        }
        if let imagePath {
            try? FileManager.default.removeItem(at: imagePath)
        }
    }

    @discardableResult
    public func clear() throws -> Int {
        let paths = try allImagePaths()
        let count = try itemCount()
        try execute("DELETE FROM clips;")
        for path in paths {
            try? FileManager.default.removeItem(at: path)
        }
        return count
    }

    public func itemCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM clips;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    public func loadPrompts() throws -> [PromptItem] {
        let statement = try prepare("""
        SELECT id, title, body, groupName, isFavorite, variables, createdAt,
               updatedAt, lastUsedAt, useCount, sortOrder
        FROM prompts
        ORDER BY sortOrder ASC, id ASC;
        """)
        defer { sqlite3_finalize(statement) }

        var prompts: [PromptItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            prompts.append(try decodePrompt(statement))
        }
        return prompts
    }

    @discardableResult
    public func createPrompt(
        title: String,
        body: String,
        groupName: String,
        variables: [PromptVariable],
        isFavorite: Bool = false,
        date: Date = Date()
    ) throws -> PromptItem {
        let sortOrder = try nextPromptSortOrder()
        let statement = try prepare("""
        INSERT INTO prompts (
            title, body, groupName, isFavorite, variables, createdAt, updatedAt,
            lastUsedAt, useCount, sortOrder
        ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, 0, ?);
        """)
        defer { sqlite3_finalize(statement) }

        try bind(title, to: statement, at: 1)
        try bind(body, to: statement, at: 2)
        try bind(groupName, to: statement, at: 3)
        sqlite3_bind_int(statement, 4, isFavorite ? 1 : 0)
        try bind(try encodeVariables(variables), to: statement, at: 5)
        sqlite3_bind_double(statement, 6, date.timeIntervalSince1970)
        sqlite3_bind_double(statement, 7, date.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 8, Int64(sortOrder))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ClipStoreError.execute(databaseMessage)
        }

        return PromptItem(
            id: sqlite3_last_insert_rowid(database),
            title: title,
            body: body,
            groupName: groupName,
            isFavorite: isFavorite,
            variables: variables,
            createdAt: date,
            updatedAt: date,
            sortOrder: sortOrder
        )
    }

    public func updatePrompt(
        id: Int64,
        title: String,
        body: String,
        groupName: String,
        variables: [PromptVariable],
        date: Date = Date()
    ) throws {
        let statement = try prepare("""
        UPDATE prompts
        SET title = ?, body = ?, groupName = ?, variables = ?, updatedAt = ?
        WHERE id = ?;
        """)
        defer { sqlite3_finalize(statement) }

        try bind(title, to: statement, at: 1)
        try bind(body, to: statement, at: 2)
        try bind(groupName, to: statement, at: 3)
        try bind(try encodeVariables(variables), to: statement, at: 4)
        sqlite3_bind_double(statement, 5, date.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 6, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ClipStoreError.execute(databaseMessage)
        }
    }

    public func setPromptFavorite(id: Int64, isFavorite: Bool) throws {
        let statement = try prepare("UPDATE prompts SET isFavorite = ?, updatedAt = ? WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, isFavorite ? 1 : 0)
        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        sqlite3_bind_int64(statement, 3, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ClipStoreError.execute(databaseMessage)
        }
    }

    public func markPromptUsed(id: Int64, date: Date = Date()) throws {
        let statement = try prepare("""
        UPDATE prompts SET lastUsedAt = ?, useCount = useCount + 1 WHERE id = ?;
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 2, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ClipStoreError.execute(databaseMessage)
        }
    }

    public func deletePrompt(id: Int64) throws {
        let statement = try prepare("DELETE FROM prompts WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ClipStoreError.execute(databaseMessage)
        }
    }

    public func setPromptOrder(_ ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let statement = try prepare("UPDATE prompts SET sortOrder = ? WHERE id = ?;")
            defer { sqlite3_finalize(statement) }

            for (index, id) in ids.enumerated() {
                sqlite3_bind_int64(statement, 1, Int64(index + 1))
                sqlite3_bind_int64(statement, 2, id)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw ClipStoreError.execute(databaseMessage)
                }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func promptCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM prompts;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func migrate() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS clips (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            kind TEXT NOT NULL,
            category TEXT NOT NULL,
            isFavorite INTEGER NOT NULL DEFAULT 0,
            sourceAppName TEXT NOT NULL,
            sourceBundleID TEXT NOT NULL,
            copiedAt REAL NOT NULL,
            title TEXT NOT NULL,
            fullText TEXT,
            imagePath TEXT,
            imageAlt TEXT,
            meta TEXT NOT NULL,
            contentHash TEXT NOT NULL
        );
        """)
        try execute("CREATE INDEX IF NOT EXISTS clips_copiedAt ON clips(copiedAt DESC);")
        try execute("CREATE INDEX IF NOT EXISTS clips_category ON clips(category);")
        try execute("CREATE INDEX IF NOT EXISTS clips_favorite ON clips(isFavorite);")
        try execute("""
        CREATE TABLE IF NOT EXISTS prompts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            body TEXT NOT NULL,
            groupName TEXT NOT NULL DEFAULT '未分组',
            isFavorite INTEGER NOT NULL DEFAULT 0,
            variables TEXT NOT NULL DEFAULT '[]',
            createdAt REAL NOT NULL,
            updatedAt REAL NOT NULL,
            lastUsedAt REAL,
            useCount INTEGER NOT NULL DEFAULT 0,
            sortOrder INTEGER NOT NULL DEFAULT 0
        );
        """)
        if try !hasColumn(named: "sortOrder", in: "prompts") {
            try execute("ALTER TABLE prompts ADD COLUMN sortOrder INTEGER NOT NULL DEFAULT 0;")
        }
        try execute("UPDATE prompts SET sortOrder = id WHERE sortOrder = 0;")
        try execute("CREATE INDEX IF NOT EXISTS prompts_updatedAt ON prompts(updatedAt DESC);")
        try execute("CREATE INDEX IF NOT EXISTS prompts_groupName ON prompts(groupName);")
        try execute("CREATE INDEX IF NOT EXISTS prompts_favorite ON prompts(isFavorite);")
        try execute("CREATE INDEX IF NOT EXISTS prompts_sortOrder ON prompts(sortOrder ASC);")
    }

    public func enforceHistoryLimit(
        _ limit: Int = SQLiteClipStore.defaultHistoryLimit
    ) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let victims = try removeOverflowHistory(limit)
            try execute("COMMIT;")
            removeImages(victims.compactMap(\.imageURL))
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func removeOverflowHistory(_ limit: Int) throws -> [(id: Int64, imageURL: URL?)] {
        let statement = try prepare("""
        SELECT id, imagePath FROM clips
        WHERE isFavorite = 0
        ORDER BY copiedAt DESC, id DESC
        LIMIT -1 OFFSET ?;
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(max(1, limit)))
        var victims: [(id: Int64, imageURL: URL?)] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            victims.append((
                sqlite3_column_int64(statement, 0),
                optionalString(statement, column: 1).map { imagesURL.appendingPathComponent($0) }
            ))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw ClipStoreError.execute(databaseMessage) }
        guard !victims.isEmpty else { return [] }

        let delete = try prepare("DELETE FROM clips WHERE id = ?;")
        defer { sqlite3_finalize(delete) }
        for (id, _) in victims {
            sqlite3_bind_int64(delete, 1, id)
            guard sqlite3_step(delete) == SQLITE_DONE else {
                throw ClipStoreError.execute(databaseMessage)
            }
            sqlite3_reset(delete)
        }
        return victims
    }

    private func removeImages(_ paths: [URL]) {
        for path in paths {
            try? FileManager.default.removeItem(at: path)
        }
    }

    private func imagePath(for id: Int64) throws -> URL? {
        let statement = try prepare("SELECT imagePath FROM clips WHERE id = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let filename = optionalString(statement, column: 0) else { return nil }
        return imagesURL.appendingPathComponent(filename)
    }

    private func allImagePaths() throws -> [URL] {
        let statement = try prepare("SELECT imagePath FROM clips WHERE imagePath IS NOT NULL;")
        defer { sqlite3_finalize(statement) }
        var paths: [URL] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let filename = optionalString(statement, column: 0) {
                paths.append(imagesURL.appendingPathComponent(filename))
            }
        }
        return paths
    }

    private func decodeItem(_ statement: OpaquePointer?) throws -> ClipItem {
        guard let kind = ClipKind(rawValue: string(statement, column: 1)),
              let category = ClipCategory(rawValue: string(statement, column: 2)) else {
            throw ClipStoreError.decode("记录类型无效")
        }

        let metaJSON = string(statement, column: 11)
        guard let metaData = metaJSON.data(using: .utf8) else {
            throw ClipStoreError.decode("元信息编码无效")
        }
        let meta: [MetaEntry]
        do {
            meta = try decoder.decode([MetaEntry].self, from: metaData)
        } catch {
            throw ClipStoreError.decode(error.localizedDescription)
        }

        let imageURL = optionalString(statement, column: 9).map {
            imagesURL.appendingPathComponent($0)
        }
        return ClipItem(
            id: sqlite3_column_int64(statement, 0),
            kind: kind,
            category: category,
            isFavorite: sqlite3_column_int(statement, 3) != 0,
            sourceAppName: string(statement, column: 4),
            sourceBundleID: string(statement, column: 5),
            copiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            title: string(statement, column: 7),
            fullText: optionalString(statement, column: 8),
            imagePath: imageURL,
            imageAlt: optionalString(statement, column: 10),
            meta: meta,
            contentHash: string(statement, column: 12)
        )
    }

    private func decodePrompt(_ statement: OpaquePointer?) throws -> PromptItem {
        let variablesJSON = string(statement, column: 5)
        guard let variablesData = variablesJSON.data(using: .utf8) else {
            throw ClipStoreError.decode("提示词变量编码无效")
        }
        let variables: [PromptVariable]
        do {
            variables = try decoder.decode([PromptVariable].self, from: variablesData)
        } catch {
            throw ClipStoreError.decode("提示词变量无法解析：\(error.localizedDescription)")
        }

        let lastUsedAt: Date?
        if sqlite3_column_type(statement, 8) == SQLITE_NULL {
            lastUsedAt = nil
        } else {
            lastUsedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))
        }
        return PromptItem(
            id: sqlite3_column_int64(statement, 0),
            title: string(statement, column: 1),
            body: string(statement, column: 2),
            groupName: string(statement, column: 3),
            isFavorite: sqlite3_column_int(statement, 4) != 0,
            variables: variables,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
            lastUsedAt: lastUsedAt,
            useCount: Int(sqlite3_column_int64(statement, 9)),
            sortOrder: Int(sqlite3_column_int64(statement, 10))
        )
    }

    private func nextPromptSortOrder() throws -> Int {
        let statement = try prepare("SELECT COALESCE(MAX(sortOrder), 0) + 1 FROM prompts;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 1 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func hasColumn(named column: String, in table: String) throws -> Bool {
        let statement = try prepare("PRAGMA table_info(\(table));")
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if string(statement, column: 1) == column { return true }
        }
        return false
    }

    private func encodeVariables(_ variables: [PromptVariable]) throws -> String {
        String(decoding: try encoder.encode(variables), as: UTF8.self)
    }

    private func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? databaseMessage
            sqlite3_free(errorPointer)
            throw ClipStoreError.execute(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ClipStoreError.prepare(databaseMessage)
        }
        return statement
    }

    private func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) throws {
        guard sqlite3_bind_text(statement, index, value, -1, transient) == SQLITE_OK else {
            throw ClipStoreError.bind(databaseMessage)
        }
    }

    private func bindOptional(_ value: String?, to statement: OpaquePointer?, at index: Int32) throws {
        guard let value else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw ClipStoreError.bind(databaseMessage)
            }
            return
        }
        try bind(value, to: statement, at: index)
    }

    private func string(_ statement: OpaquePointer?, column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private func optionalString(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return string(statement, column: column)
    }

    private func sanitizedExtension(_ value: String) -> String {
        let allowed = value.lowercased().filter { $0.isLetter || $0.isNumber }
        return allowed.isEmpty ? "png" : allowed
    }

    private var databaseMessage: String {
        guard let database, let message = sqlite3_errmsg(database) else {
            return "未知 SQLite 错误"
        }
        return String(cString: message)
    }
}
