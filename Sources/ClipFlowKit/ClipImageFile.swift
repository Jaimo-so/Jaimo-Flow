import Foundation

/// Helpers for exporting a stored clipboard image without re-encoding it.
public enum ClipImageFile {
    public static func suggestedFileName(
        copiedAt: Date,
        sourceAppName: String,
        pathExtension: String,
        timeZone: TimeZone = .current,
        locale: Locale = Locale(identifier: "en_US_POSIX")
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let app = sanitizedFileNameComponent(sourceAppName)
        let ext = preferredExtension(pathExtension)
        return "\(app) \(formatter.string(from: copiedAt)).\(ext)"
    }

    public static func preferredExtension(for url: URL) -> String {
        preferredExtension(url.pathExtension)
    }

    public static func preferredExtension(_ raw: String) -> String {
        let trimmed = raw
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return trimmed.isEmpty ? "png" : trimmed
    }

    public static func sanitizedFileNameComponent(_ raw: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?*\"<>|")
            .union(.newlines)
            .union(.controlCharacters)
        var result = raw.components(separatedBy: illegal).joined(separator: " ")
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix(".") {
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if result.count > 40 {
            result = String(result.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result.isEmpty ? "图片" : result
    }

    /// Copies the original image bytes to the destination without re-encoding.
    public static func export(from source: URL, to destination: URL) throws {
        let data = try Data(contentsOf: source, options: [.mappedIfSafe])
        if source.standardizedFileURL == destination.standardizedFileURL {
            return
        }
        try data.write(to: destination, options: .atomic)
    }
}
