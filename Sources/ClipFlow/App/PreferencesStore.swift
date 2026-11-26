import SwiftUI
import ServiceManagement

enum FlowAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case black

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "白天 · 液态玻璃"
        case .black: return "黑夜 · 控制中心"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .black: return .dark
        }
    }
}

struct ExcludedApp: Codable, Hashable, Identifiable {
    let name: String
    let bundleID: String
    var id: String { bundleID }
}

@MainActor
final class PreferencesStore: ObservableObject {
    private enum Key {
        static let closeAfterCopy = "closeAfterCopy"
        static let excludedApps = "excludedApps"
        static let promptGroupOrder = "promptGroupOrder"
        static let workspaceSize = "island.workspaceSize"
        static let appearance = "appearance"
        static let terminalEnabled = "module.terminalEnabled"
        static let recordingEnabled = "module.recordingEnabled"
        static let mirrorEnabled = "module.mirrorEnabled"
    }

    static let defaultExcludedApps = [
        ExcludedApp(name: "1Password", bundleID: "com.1password.1password"),
        ExcludedApp(name: "钥匙串访问", bundleID: "com.apple.keychainaccess"),
        ExcludedApp(name: "终端", bundleID: "com.apple.Terminal")
    ]

    @Published var closeAfterCopy: Bool {
        didSet { defaults.set(closeAfterCopy, forKey: Key.closeAfterCopy) }
    }

    @Published var appearance: FlowAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    @Published var terminalEnabled: Bool {
        didSet { defaults.set(terminalEnabled, forKey: Key.terminalEnabled) }
    }

    @Published var recordingEnabled: Bool {
        didSet { defaults.set(recordingEnabled, forKey: Key.recordingEnabled) }
    }

    @Published var mirrorEnabled: Bool {
        didSet { defaults.set(mirrorEnabled, forKey: Key.mirrorEnabled) }
    }

    @Published private(set) var excludedApps: [ExcludedApp] {
        didSet { persistExcludedApps() }
    }

    @Published private(set) var promptGroupOrder: [String] {
        didSet { defaults.set(promptGroupOrder, forKey: Key.promptGroupOrder) }
    }

    static let defaultWorkspaceSize = CGSize(width: 849, height: 575)

    var workspaceSize: CGSize {
        didSet {
            defaults.set(
                ["width": Double(workspaceSize.width), "height": Double(workspaceSize.height)],
                forKey: Key.workspaceSize
            )
        }
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.closeAfterCopy: true,
            Key.terminalEnabled: true,
            Key.recordingEnabled: true,
            Key.mirrorEnabled: true
        ])
        closeAfterCopy = defaults.bool(forKey: Key.closeAfterCopy)
        appearance = FlowAppearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        terminalEnabled = defaults.bool(forKey: Key.terminalEnabled)
        recordingEnabled = defaults.bool(forKey: Key.recordingEnabled)
        mirrorEnabled = defaults.bool(forKey: Key.mirrorEnabled)
        promptGroupOrder = defaults.stringArray(forKey: Key.promptGroupOrder) ?? []
        if let saved = defaults.dictionary(forKey: Key.workspaceSize),
           let width = saved["width"] as? Double,
           let height = saved["height"] as? Double,
           width.isFinite, height.isFinite, width > 0, height > 0 {
            workspaceSize = CGSize(width: width, height: height)
        } else {
            workspaceSize = Self.defaultWorkspaceSize
        }

        if let data = defaults.data(forKey: Key.excludedApps),
           let decoded = try? JSONDecoder().decode([ExcludedApp].self, from: data) {
            excludedApps = decoded
        } else {
            excludedApps = Self.defaultExcludedApps
        }
    }

    var launchAtLoginEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        guard #available(macOS 13.0, *) else { return }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        objectWillChange.send()
    }

    func removeExcludedApp(_ app: ExcludedApp) {
        excludedApps.removeAll { $0.bundleID == app.bundleID }
    }

    func setPromptGroupOrder(_ groups: [String]) {
        promptGroupOrder = groups
    }

    func isExcluded(bundleID: String) -> Bool {
        if excludedApps.contains(where: { $0.bundleID == bundleID }) { return true }
        let lowered = bundleID.lowercased()
        return excludedApps.contains(where: { $0.name == "1Password" })
            && (lowered.contains("1password") || lowered.contains("agilebits"))
    }

    private func persistExcludedApps() {
        guard let data = try? JSONEncoder().encode(excludedApps) else { return }
        defaults.set(data, forKey: Key.excludedApps)
    }
}
