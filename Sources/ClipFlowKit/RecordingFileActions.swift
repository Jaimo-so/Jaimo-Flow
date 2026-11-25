import Foundation

/// 录音转写工作台的文件侧操作：重命名（音频与字幕侧车一并改名）和导出文件名。
public enum RecordingExportFormat: String, CaseIterable, Equatable, Hashable, Sendable {
    case speakersText
    case plainText
    case srt

    public var fileExtension: String { self == .srt ? "srt" : "txt" }

    public var menuTitle: String {
        switch self {
        case .speakersText: return "导出字幕全文…"
        case .plainText: return "导出纯文本…"
        case .srt: return "导出 SRT 字幕…"
        }
    }

    public var successNotice: String {
        switch self {
        case .speakersText: return "已导出字幕全文"
        case .plainText: return "已导出纯文本"
        case .srt: return "已导出 SRT 字幕"
        }
    }

    public func defaultFileName(title: String) -> String {
        let stem = RecordingFileActions.sanitizeTitle(title)
        let resolved = stem.isEmpty ? "录音字幕" : stem
        switch self {
        case .speakersText:
            return "\(resolved).txt"
        case .plainText:
            return "\(resolved) 纯文本.txt"
        case .srt:
            return "\(resolved).srt"
        }
    }

    public func contents(formattedText: String, plainText: String, srtText: String) -> String {
        switch self {
        case .speakersText: return formattedText
        case .plainText: return plainText
        case .srt: return srtText
        }
    }
}

public struct RecordingFileMove: Equatable, Sendable {
    public let from: URL
    public let to: URL
    public let isOptional: Bool

    public init(from: URL, to: URL, isOptional: Bool = false) {
        self.from = from
        self.to = to
        self.isOptional = isOptional
    }
}

public struct RecordingRenamePlan: Equatable, Sendable {
    public let sourceAudio: URL
    public let destinationAudio: URL
    public let moves: [RecordingFileMove]

    public var isNoOp: Bool { sourceAudio == destinationAudio }
}

public enum RecordingFileActionError: Error, LocalizedError, Equatable, Sendable {
    case emptyTitle
    case recordingMissing
    case destinationExists(String)
    case moveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyTitle:
            return "请输入有效的录音名称。"
        case .recordingMissing:
            return "找不到要重命名的录音文件。"
        case .destinationExists(let name):
            return "已经有名为“\(name)”的录音，请换一个名称。"
        case .moveFailed(let detail):
            return detail
        }
    }
}

public enum RecordingFileActions {
    public static let defaultTitlePrefix = "Jaimo Flow 录音 "
    public static let maxTitleLength = 80

    public static func displayTitle(fromStem stem: String) -> String {
        if stem.hasPrefix(defaultTitlePrefix) {
            return String(stem.dropFirst(defaultTitlePrefix.count))
        }
        return stem
    }

    public static func displayTitle(for audioURL: URL) -> String {
        displayTitle(fromStem: audioURL.deletingPathExtension().lastPathComponent)
    }

    public static func sanitizeTitle(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
            .union(.newlines)
            .union(.controlCharacters)
        var scalars: [Character] = []
        var lastWasSpace = false
        for character in raw {
            let isForbidden = character.unicodeScalars.contains { forbidden.contains($0) }
            if isForbidden || character == "/" {
                if !lastWasSpace && !scalars.isEmpty {
                    scalars.append(" ")
                    lastWasSpace = true
                }
                continue
            }
            if character.isWhitespace {
                if !lastWasSpace && !scalars.isEmpty {
                    scalars.append(" ")
                    lastWasSpace = true
                }
                continue
            }
            if character == "." && scalars.isEmpty {
                continue
            }
            scalars.append(character)
            lastWasSpace = false
        }
        var sanitized = String(scalars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if sanitized.count > maxTitleLength {
            sanitized = String(sanitized.prefix(maxTitleLength))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        return sanitized
    }

    public static func uniqueStem(
        desired: String,
        usedStems: Set<String>,
        excluding: String? = nil
    ) -> String {
        let used = normalizedStemSet(usedStems, excluding: excluding)
        if !used.contains(normalizeStem(desired)) {
            return desired
        }
        var index = 2
        while used.contains(normalizeStem("\(desired) \(index)")) {
            index += 1
        }
        return "\(desired) \(index)"
    }

    public static func occupiedStems(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> Set<String> {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return Set(files.compactMap { stem(forFileURL: $0) })
    }

    public static func transcriptJSONURL(for recordingURL: URL) -> URL {
        recordingURL.deletingPathExtension().appendingPathExtension("transcript.json")
    }

    public static func plainTextURL(for recordingURL: URL) -> URL {
        recordingURL.deletingPathExtension().appendingPathExtension("txt")
    }

    public static func planRename(
        audioURL: URL,
        desiredTitle: String,
        occupiedStems: Set<String>
    ) throws -> RecordingRenamePlan {
        let currentStem = audioURL.deletingPathExtension().lastPathComponent
        let sanitized = sanitizeTitle(desiredTitle)
        guard !sanitized.isEmpty else { throw RecordingFileActionError.emptyTitle }

        let unchanged = normalizeStem(sanitized) == normalizeStem(currentStem)
            || (currentStem.hasPrefix(defaultTitlePrefix)
                && normalizeStem(sanitized) == normalizeStem(displayTitle(fromStem: currentStem)))
        let newStem = unchanged
            ? currentStem
            : uniqueStem(desired: sanitized, usedStems: occupiedStems, excluding: currentStem)

        let destination = audioURL
            .deletingLastPathComponent()
            .appendingPathComponent(newStem)
            .appendingPathExtension(audioURL.pathExtension.isEmpty ? "m4a" : audioURL.pathExtension)

        guard audioURL != destination else {
            return RecordingRenamePlan(sourceAudio: audioURL, destinationAudio: destination, moves: [])
        }

        return RecordingRenamePlan(
            sourceAudio: audioURL,
            destinationAudio: destination,
            moves: [
                RecordingFileMove(from: audioURL, to: destination),
                RecordingFileMove(from: transcriptJSONURL(for: audioURL), to: transcriptJSONURL(for: destination), isOptional: true),
                RecordingFileMove(from: plainTextURL(for: audioURL), to: plainTextURL(for: destination), isOptional: true)
            ]
        )
    }

    @discardableResult
    public static func applyRename(
        _ plan: RecordingRenamePlan,
        fileManager: FileManager = .default
    ) throws -> URL {
        if plan.isNoOp { return plan.sourceAudio }
        guard fileManager.fileExists(atPath: plan.sourceAudio.path) else {
            throw RecordingFileActionError.recordingMissing
        }

        var completed: [RecordingFileMove] = []
        do {
            for move in plan.moves {
                let sourceExists = fileManager.fileExists(atPath: move.from.path)
                if !sourceExists {
                    if move.isOptional { continue }
                    throw RecordingFileActionError.recordingMissing
                }
                if fileManager.fileExists(atPath: move.to.path) {
                    throw RecordingFileActionError.destinationExists(move.to.lastPathComponent)
                }
                try fileManager.moveItem(at: move.from, to: move.to)
                completed.append(move)
            }
        } catch {
            for move in completed.reversed() {
                try? fileManager.moveItem(at: move.to, to: move.from)
            }
            if let actionError = error as? RecordingFileActionError {
                throw actionError
            }
            throw RecordingFileActionError.moveFailed("重命名失败：\(error.localizedDescription)")
        }
        return plan.destinationAudio
    }

    public static func matchesSearch(title: String, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty { return true }
        return title.localizedCaseInsensitiveContains(needle)
    }

    public static func filteredTitles(_ titles: [String], query: String) -> [String] {
        titles.filter { matchesSearch(title: $0, query: query) }
    }

    private static func stem(forFileURL url: URL) -> String? {
        let name = url.lastPathComponent
        if name.hasPrefix(".") { return nil }
        if name.hasSuffix(".transcript.json") {
            return String(name.dropLast(".transcript.json".count))
        }
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? nil : stem
    }

    private static func normalizeStem(_ stem: String) -> String {
        stem.lowercased()
    }

    private static func normalizedStemSet(_ stems: Set<String>, excluding: String?) -> Set<String> {
        var used = Set(stems.map(normalizeStem))
        if let excluding {
            used.remove(normalizeStem(excluding))
        }
        return used
    }
}
