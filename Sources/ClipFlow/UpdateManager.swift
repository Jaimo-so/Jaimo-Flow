import AppKit
import ClipFlowKit
import CryptoKit
import Darwin
import Foundation

@MainActor
final class UpdateManager: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AvailableUpdate)
        case downloading(AvailableUpdate)
        case verifying(AvailableUpdate)
        case installing(AvailableUpdate)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    var onUpdateAvailable: ((String) -> Void)?

    let currentVersion: String
    let currentBuild: String
    let repositoryLabel: String

    private let repositoryOwner: String
    private let repositoryName: String
    private let defaults: UserDefaults
    private var activeTask: Task<Void, Never>?

    private static let lastSuccessfulCheckKey = "lastSuccessfulUpdateCheck"
    private static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "开发版"
        currentBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "0"
        repositoryOwner = bundle.object(forInfoDictionaryKey: "ClipFlowUpdateRepositoryOwner") as? String
            ?? "Jaimo-so"
        repositoryName = bundle.object(forInfoDictionaryKey: "ClipFlowUpdateRepositoryName") as? String
            ?? "Jaimo-Flow"
        repositoryLabel = "\(repositoryOwner)/\(repositoryName)"
        self.defaults = defaults
        if let helperFailure = Self.consumeHelperFailure() {
            state = .failed("上次更新未完成，已恢复原版本。\(helperFailure)")
        }
    }

    var statusText: String {
        switch state {
        case .idle: return "尚未检查更新"
        case .checking: return "正在连接 GitHub…"
        case .upToDate: return "已是最新版本"
        case .available(let update): return "发现新版本 \(update.version)"
        case .downloading: return "正在下载安装包…"
        case .verifying: return "正在校验安装包…"
        case .installing: return "正在安装，即将重新启动…"
        case .failed: return "更新检查失败"
        }
    }

    var actionTitle: String {
        switch state {
        case .available: return "一键更新"
        case .checking: return "检查中…"
        case .downloading: return "下载中…"
        case .verifying: return "校验中…"
        case .installing: return "安装中…"
        case .idle, .upToDate, .failed: return "检查更新"
        }
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .verifying, .installing: return true
        case .idle, .upToDate, .available, .failed: return false
        }
    }

    var hasAvailableUpdate: Bool {
        if case .available = state { return true }
        return false
    }

    var errorMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    var releaseNotes: String? {
        guard case .available(let update) = state else { return nil }
        let notes = update.releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes.isEmpty ? nil : notes
    }

    func checkIfNeeded() {
        guard !isBusy else { return }
        if let lastCheck = defaults.object(forKey: Self.lastSuccessfulCheckKey) as? Date,
           Date().timeIntervalSince(lastCheck) < Self.automaticCheckInterval {
            return
        }
        checkForUpdates(manual: false)
    }

    func checkForUpdates(manual: Bool = true) {
        guard !isBusy else { return }
        activeTask?.cancel()
        state = .checking

        let owner = repositoryOwner
        let repository = repositoryName
        let installedVersion = currentVersion
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let update = try await Self.fetchLatestRelease(
                    owner: owner,
                    repository: repository,
                    currentVersion: installedVersion
                )
                try Task.checkCancellation()
                defaults.set(Date(), forKey: Self.lastSuccessfulCheckKey)
                if let update {
                    state = .available(update)
                    if !manual { onUpdateAvailable?(update.version) }
                } else {
                    state = .upToDate
                }
            } catch is CancellationError {
                return
            } catch {
                state = .failed(Self.userMessage(for: error))
            }
        }
    }

    func performPrimaryAction() {
        guard !isBusy else { return }
        if case .available(let update) = state {
            install(update)
        } else {
            checkForUpdates()
        }
    }

    private func install(_ update: AvailableUpdate) {
        let currentApplication = Bundle.main.bundleURL.standardizedFileURL
        let destinationParent = currentApplication.deletingLastPathComponent()
        guard currentApplication.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: destinationParent.path) else {
            state = .failed("请先将 Jaimo Flow 拖入“应用程序”文件夹，再执行一键更新")
            return
        }

        activeTask?.cancel()
        state = .downloading(update)
        activeTask = Task { [weak self] in
            guard let self else { return }
            let updateRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
                "JaimoClipUpdate-\(UUID().uuidString)",
                isDirectory: true
            )
            do {
                try FileManager.default.createDirectory(
                    at: updateRoot,
                    withIntermediateDirectories: true
                )
                let expectedHash = try await Self.expectedSHA256(for: update)
                let installerURL = try await Self.downloadInstaller(update, into: updateRoot)
                try Task.checkCancellation()
                state = .verifying(update)

                let prepared = try await Task.detached(priority: .userInitiated) {
                    try Self.prepareInstallation(
                        installerURL: installerURL,
                        expectedSHA256: expectedHash,
                        expectedVersion: update.version,
                        currentApplication: currentApplication,
                        updateRoot: updateRoot
                    )
                }.value
                try Task.checkCancellation()

                try Self.launchUpdaterHelper(prepared)
                state = .installing(update)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    NSApp.terminate(nil)
                }
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: updateRoot)
            } catch {
                try? FileManager.default.removeItem(at: updateRoot)
                state = .failed(Self.userMessage(for: error))
            }
        }
    }
}

private extension UpdateManager {
    struct PreparedInstallation: Sendable {
        let helperURL: URL
        let stagedApplicationURL: URL
        let destinationApplicationURL: URL
        let cleanupRoot: URL
    }

    enum UpdateError: Error, LocalizedError {
        case invalidUpdateURL
        case invalidServerResponse
        case httpStatus(Int)
        case checksumUnavailable
        case checksumMismatch
        case invalidDiskImage
        case applicationMissing
        case invalidApplication
        case versionMismatch
        case unsupportedArchitecture
        case signatureInvalid
        case signingIdentityMismatch
        case helperMissing
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidUpdateURL: return "更新地址无效"
            case .invalidServerResponse: return "更新服务器返回了无效数据"
            case .httpStatus(404): return "更新源尚未发布 Release，请发布首个版本后重试"
            case .httpStatus(let status): return "更新服务器请求失败（HTTP \(status)）"
            case .checksumUnavailable: return "安装包缺少 SHA-256 校验信息"
            case .checksumMismatch: return "安装包校验失败，已停止安装"
            case .invalidDiskImage: return "无法打开下载的安装镜像"
            case .applicationMissing: return "安装镜像中没有找到 Jaimo Flow.app"
            case .invalidApplication: return "下载的应用标识不正确"
            case .versionMismatch: return "下载的应用版本与发布版本不一致"
            case .unsupportedArchitecture: return "下载的应用不是 Apple Silicon 版本"
            case .signatureInvalid: return "下载的应用代码签名无效"
            case .signingIdentityMismatch: return "下载的应用签名身份与当前版本不一致"
            case .helperMissing: return "应用内缺少更新安装组件"
            case .commandFailed(let command): return "更新步骤执行失败：\(command)"
            }
        }
    }

    nonisolated static func fetchLatestRelease(
        owner: String,
        repository: String,
        currentVersion: String
    ) async throws -> AvailableUpdate? {
        guard let url = URL(
            string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest"
        ) else {
            throw UpdateError.invalidUpdateURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Jaimo-Flow/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response)
        let payload = try JSONDecoder().decode(GitHubReleasePayload.self, from: data)
        return try payload.availableUpdate(currentVersion: currentVersion)
    }

    nonisolated static func expectedSHA256(for update: AvailableUpdate) async throws -> String {
        if let expected = update.expectedSHA256 { return expected }
        guard let checksumURL = update.checksumURL,
              checksumURL.scheme == "https",
              checksumURL.host?.lowercased() == "github.com" else {
            throw UpdateError.checksumUnavailable
        }
        var request = URLRequest(url: checksumURL)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Jaimo-Flow/\(update.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response)
        guard let text = String(data: data, encoding: .utf8) else {
            throw UpdateError.checksumUnavailable
        }
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdef")
        guard let value = text.lowercased().split(whereSeparator: { $0.isWhitespace }).first(where: {
            $0.count == 64 && $0.unicodeScalars.allSatisfy(hexadecimal.contains)
        }) else {
            throw UpdateError.checksumUnavailable
        }
        return String(value)
    }

    nonisolated static func downloadInstaller(_ update: AvailableUpdate, into directory: URL) async throws -> URL {
        guard update.installerURL.scheme == "https",
              update.installerURL.host?.lowercased() == "github.com" else {
            throw UpdateError.invalidUpdateURL
        }
        var request = URLRequest(url: update.installerURL)
        request.timeoutInterval = 120
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Jaimo-Flow/\(update.version)", forHTTPHeaderField: "User-Agent")
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        try validateHTTPResponse(response)

        let destination = directory.appendingPathComponent(update.installerName)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    nonisolated static func validateHTTPResponse(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else {
            throw UpdateError.invalidServerResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw UpdateError.httpStatus(response.statusCode)
        }
    }

    nonisolated static func prepareInstallation(
        installerURL: URL,
        expectedSHA256: String,
        expectedVersion: String,
        currentApplication: URL,
        updateRoot: URL
    ) throws -> PreparedInstallation {
        guard try sha256(at: installerURL) == expectedSHA256.lowercased() else {
            throw UpdateError.checksumMismatch
        }

        let mountPoint = try mountDiskImage(installerURL)
        defer { try? run("/usr/bin/hdiutil", ["detach", mountPoint.path]) }

        let candidateNames = ["Jaimo Flow.app", "Jaimo clip.app", "ClipFlow.app"]
        guard let candidate = candidateNames
            .map({ mountPoint.appendingPathComponent($0, isDirectory: true) })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw UpdateError.applicationMissing
        }
        try validateApplication(
            candidate,
            expectedVersion: expectedVersion,
            currentApplication: currentApplication
        )

        let stagedApplication = updateRoot.appendingPathComponent("StagedJaimoClip.app", isDirectory: true)
        try run("/usr/bin/ditto", [candidate.path, stagedApplication.path])
        try validateApplication(
            stagedApplication,
            expectedVersion: expectedVersion,
            currentApplication: currentApplication
        )

        let bundledHelper = currentApplication
            .appendingPathComponent("Contents/Helpers/ClipFlowUpdater")
        guard FileManager.default.isExecutableFile(atPath: bundledHelper.path) else {
            throw UpdateError.helperMissing
        }
        let copiedHelper = updateRoot.appendingPathComponent("ClipFlowUpdater")
        try FileManager.default.copyItem(at: bundledHelper, to: copiedHelper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: copiedHelper.path
        )

        return PreparedInstallation(
            helperURL: copiedHelper,
            stagedApplicationURL: stagedApplication,
            destinationApplicationURL: currentApplication,
            cleanupRoot: updateRoot
        )
    }

    nonisolated static func validateApplication(
        _ application: URL,
        expectedVersion: String,
        currentApplication: URL
    ) throws {
        guard let bundle = Bundle(url: application),
              bundle.bundleIdentifier == "com.clipflow.mac" else {
            throw UpdateError.invalidApplication
        }
        let candidateVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard let candidateVersion,
              AppVersion(candidateVersion) == AppVersion(expectedVersion) else {
            throw UpdateError.versionMismatch
        }

        guard let executableName = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String else {
            throw UpdateError.invalidApplication
        }
        let executable = application.appendingPathComponent("Contents/MacOS/\(executableName)")
        let architectures = try runCapture("/usr/bin/lipo", ["-archs", executable.path])
        guard architectures.split(whereSeparator: { $0.isWhitespace }).contains("arm64") else {
            throw UpdateError.unsupportedArchitecture
        }

        do {
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", application.path])
        } catch {
            throw UpdateError.signatureInvalid
        }

        let currentTeam = try signingTeamIdentifier(at: currentApplication)
        let candidateTeam = try signingTeamIdentifier(at: application)
        if let currentTeam, currentTeam != "not set", currentTeam != candidateTeam {
            throw UpdateError.signingIdentityMismatch
        }
    }

    nonisolated static func signingTeamIdentifier(at application: URL) throws -> String? {
        let output = try runCapture(
            "/usr/bin/codesign",
            ["-dv", "--verbose=4", application.path],
            mergeStandardError: true
        )
        return output
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("TeamIdentifier=") })
            .map { String($0.dropFirst("TeamIdentifier=".count)) }
    }

    nonisolated static func mountDiskImage(_ installerURL: URL) throws -> URL {
        let data = try runCaptureData(
            "/usr/bin/hdiutil",
            ["attach", "-readonly", "-nobrowse", "-plist", installerURL.path]
        )
        guard let propertyList = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any],
        let entities = propertyList["system-entities"] as? [[String: Any]],
        let mountPath = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw UpdateError.invalidDiskImage
        }
        return URL(fileURLWithPath: mountPath, isDirectory: true)
    }

    nonisolated static func sha256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func launchUpdaterHelper(_ prepared: PreparedInstallation) throws {
        let process = Process()
        process.executableURL = prepared.helperURL
        process.arguments = [
            "--pid", String(getpid()),
            "--source", prepared.stagedApplicationURL.path,
            "--destination", prepared.destinationApplicationURL.path,
            "--cleanup", prepared.cleanupRoot.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    nonisolated static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.commandFailed(executable)
        }
    }

    nonisolated static func runCapture(
        _ executable: String,
        _ arguments: [String],
        mergeStandardError: Bool = false
    ) throws -> String {
        let data = try runCaptureData(
            executable,
            arguments,
            mergeStandardError: mergeStandardError
        )
        return String(data: data, encoding: .utf8) ?? ""
    }

    nonisolated static func runCaptureData(
        _ executable: String,
        _ arguments: [String],
        mergeStandardError: Bool = false
    ) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = mergeStandardError ? output : FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.commandFailed(executable)
        }
        return data
    }

    nonisolated static func userMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost:
                return "无法连接更新服务器，请检查网络后重试"
            case .timedOut:
                return "连接更新服务器超时，请稍后重试"
            default:
                return urlError.localizedDescription
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    nonisolated static func consumeHelperFailure() -> String? {
        let url = URL(fileURLWithPath: "/tmp/Jaimo-Flow-update-error.log")
        guard let data = try? Data(contentsOf: url),
              let contents = String(data: data, encoding: .utf8) else {
            return nil
        }
        try? FileManager.default.removeItem(at: url)
        let lastLine = contents
            .split(separator: "\n")
            .last
            .map(String.init) ?? "更新助手执行失败"
        let detail = lastLine
            .split(separator: ":", maxSplits: 1)
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? lastLine
        return detail.count > 240 ? String(detail.prefix(240)) + "…" : detail
    }
}
