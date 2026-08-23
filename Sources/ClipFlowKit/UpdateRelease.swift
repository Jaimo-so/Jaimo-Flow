import Foundation

public struct AppVersion: Comparable, Hashable, Sendable {
    public let components: [Int]

    public init?(_ rawValue: String) {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("v") { value.removeFirst() }
        value = String(value.split(separator: "-", maxSplits: 1).first ?? "")

        let parsed = value.split(separator: ".", omittingEmptySubsequences: false).compactMap { part -> Int? in
            guard !part.isEmpty, let number = Int(part), number >= 0 else { return nil }
            return number
        }
        guard !parsed.isEmpty,
              parsed.count == value.split(separator: ".", omittingEmptySubsequences: false).count else {
            return nil
        }

        var normalized = parsed
        while normalized.count > 1 && normalized.last == 0 { normalized.removeLast() }
        components = normalized
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

public struct GitHubReleaseAsset: Decodable, Hashable, Sendable {
    public let name: String
    public let browserDownloadURL: URL
    public let digest: String?

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case digest
    }
}

public struct GitHubReleasePayload: Decodable, Hashable, Sendable {
    public let tagName: String
    public let name: String?
    public let body: String?
    public let htmlURL: URL
    public let assets: [GitHubReleaseAsset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case assets
    }

    public func availableUpdate(currentVersion: String) throws -> AvailableUpdate? {
        guard let current = AppVersion(currentVersion) else {
            throw UpdateMetadataError.invalidCurrentVersion
        }
        guard let released = AppVersion(tagName) else {
            throw UpdateMetadataError.invalidReleaseVersion
        }
        guard released > current else { return nil }

        guard let installer = assets.first(where: {
            let name = $0.name.lowercased()
            return name.hasSuffix("-macos-apple-silicon.dmg")
        }) else {
            throw UpdateMetadataError.installerMissing
        }

        let checksumAsset = assets.first {
            $0.name.caseInsensitiveCompare(installer.name + ".sha256") == .orderedSame
        }
        let digest = Self.normalizedSHA256(installer.digest)
        guard digest != nil || checksumAsset != nil else {
            throw UpdateMetadataError.checksumMissing
        }

        let displayVersion = tagName.lowercased().hasPrefix("v")
            ? String(tagName.dropFirst())
            : tagName
        return AvailableUpdate(
            version: displayVersion,
            releaseName: name ?? "Jaimo Flow \(displayVersion)",
            releaseNotes: body ?? "",
            releasePageURL: htmlURL,
            installerName: installer.name,
            installerURL: installer.browserDownloadURL,
            expectedSHA256: digest,
            checksumURL: checksumAsset?.browserDownloadURL
        )
    }

    private static func normalizedSHA256(_ rawValue: String?) -> String? {
        guard var value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }
        if value.hasPrefix("sha256:") { value.removeFirst("sha256:".count) }
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdef")
        guard value.count == 64,
              value.unicodeScalars.allSatisfy(hexadecimal.contains) else {
            return nil
        }
        return value
    }
}

public struct AvailableUpdate: Hashable, Sendable {
    public let version: String
    public let releaseName: String
    public let releaseNotes: String
    public let releasePageURL: URL
    public let installerName: String
    public let installerURL: URL
    public let expectedSHA256: String?
    public let checksumURL: URL?

    public init(
        version: String,
        releaseName: String,
        releaseNotes: String,
        releasePageURL: URL,
        installerName: String,
        installerURL: URL,
        expectedSHA256: String?,
        checksumURL: URL?
    ) {
        self.version = version
        self.releaseName = releaseName
        self.releaseNotes = releaseNotes
        self.releasePageURL = releasePageURL
        self.installerName = installerName
        self.installerURL = installerURL
        self.expectedSHA256 = expectedSHA256
        self.checksumURL = checksumURL
    }
}

public enum UpdateMetadataError: Error, LocalizedError, Sendable {
    case invalidCurrentVersion
    case invalidReleaseVersion
    case installerMissing
    case checksumMissing

    public var errorDescription: String? {
        switch self {
        case .invalidCurrentVersion: return "当前版本号格式无效"
        case .invalidReleaseVersion: return "远程版本号格式无效"
        case .installerMissing: return "新版本缺少 Apple Silicon 安装包"
        case .checksumMissing: return "新版本缺少 SHA-256 校验信息"
        }
    }
}
