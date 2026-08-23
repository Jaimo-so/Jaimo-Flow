import Darwin
import Foundation

enum UpdaterError: Error, LocalizedError {
    case invalidArguments
    case invalidPath
    case invalidApplication
    case destinationNotWritable
    case applicationDidNotExit
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments: return "更新器参数无效"
        case .invalidPath: return "更新路径无效"
        case .invalidApplication: return "待安装应用验证失败"
        case .destinationNotWritable: return "应用所在文件夹不可写"
        case .applicationDidNotExit: return "Jaimo Flow 未能及时退出"
        case .commandFailed(let command): return "命令执行失败：\(command)"
        }
    }
}

struct UpdaterOptions {
    let processID: pid_t
    let source: URL
    let destination: URL
    let cleanupRoot: URL

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 1
        while index + 1 < arguments.count {
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard let pidValue = values["--pid"],
              let rawPID = Int32(pidValue),
              rawPID > 0,
              let sourcePath = values["--source"],
              let destinationPath = values["--destination"],
              let cleanupPath = values["--cleanup"] else {
            throw UpdaterError.invalidArguments
        }
        processID = rawPID
        source = URL(fileURLWithPath: sourcePath).standardizedFileURL
        destination = URL(fileURLWithPath: destinationPath).standardizedFileURL
        cleanupRoot = URL(fileURLWithPath: cleanupPath).standardizedFileURL
    }
}

func bundleIdentifier(at url: URL) -> String? {
    Bundle(url: url)?.bundleIdentifier
}

func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw UpdaterError.commandFailed(executable)
    }
}

func launch(_ application: URL) {
    try? run("/usr/bin/open", [application.path])
}

func writeFailureLog(_ error: Error) {
    let message = "\(Date()) Jaimo Flow update failed: \(error.localizedDescription)\n"
    let url = URL(fileURLWithPath: "/tmp/Jaimo-Flow-update-error.log")
    guard let data = message.data(using: .utf8) else { return }
    if FileManager.default.fileExists(atPath: url.path),
       let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: url, options: [.atomic])
    }
}

func performUpdate(_ options: UpdaterOptions) throws {
    let fileManager = FileManager.default
    let temporaryRoot = fileManager.temporaryDirectory.standardizedFileURL.path
    let cleanupPath = options.cleanupRoot.path
    guard cleanupPath.hasPrefix(temporaryRoot + "/"),
          options.source.path.hasPrefix(cleanupPath + "/"),
          options.source.pathExtension == "app",
          options.destination.pathExtension == "app" else {
        throw UpdaterError.invalidPath
    }

    guard let currentIdentifier = bundleIdentifier(at: options.destination),
          currentIdentifier == "com.clipflow.mac",
          bundleIdentifier(at: options.source) == currentIdentifier else {
        throw UpdaterError.invalidApplication
    }

    let destinationParent = options.destination.deletingLastPathComponent()
    guard fileManager.isWritableFile(atPath: destinationParent.path) else {
        throw UpdaterError.destinationNotWritable
    }

    for _ in 0..<300 {
        if kill(options.processID, 0) != 0 { break }
        usleep(100_000)
    }
    guard kill(options.processID, 0) != 0 else {
        throw UpdaterError.applicationDidNotExit
    }

    let backup = destinationParent.appendingPathComponent(
        ".Jaimo-Flow-backup-\(UUID().uuidString).app",
        isDirectory: true
    )
    try fileManager.moveItem(at: options.destination, to: backup)

    do {
        try run("/usr/bin/ditto", [options.source.path, options.destination.path])
        guard bundleIdentifier(at: options.destination) == currentIdentifier else {
            throw UpdaterError.invalidApplication
        }
        try fileManager.removeItem(at: backup)
    } catch {
        try? fileManager.removeItem(at: options.destination)
        try? fileManager.moveItem(at: backup, to: options.destination)
        launch(options.destination)
        throw error
    }

    launch(options.destination)
    try? fileManager.removeItem(at: options.cleanupRoot)
}

do {
    let options = try UpdaterOptions(arguments: CommandLine.arguments)
    try performUpdate(options)
} catch {
    writeFailureLog(error)
    exit(1)
}
