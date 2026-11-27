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

enum NavigationDisplayStyle: String, CaseIterable, Identifiable {
    case iconAndTitle
    case iconOnly

    var id: String { rawValue }
    var title: String { self == .iconOnly ? "仅图标" : "图标 + 名称" }

    func showsLabels(width: CGFloat, destinationCount: Int) -> Bool {
        self == .iconAndTitle && width >= (destinationCount > 6 ? 780 : 760)
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
        static let navigationDisplayStyle = "navigation.displayStyle"
        static let appearance = "appearance"
        static let terminalEnabled = "module.terminalEnabled"
        static let recordingEnabled = "module.recordingEnabled"
        static let mirrorEnabled = "module.mirrorEnabled"
        static let quotaEnabled = "module.quotaEnabled"
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

    var terminalEnabled: Bool {
        get { isDestinationEnabled(.terminal) }
        set { setDestinationEnabled(newValue, for: .terminal) }
    }

    @Published var recordingEnabled: Bool {
        didSet { defaults.set(recordingEnabled, forKey: Key.recordingEnabled) }
    }

    @Published var mirrorEnabled: Bool {
        didSet { defaults.set(mirrorEnabled, forKey: Key.mirrorEnabled) }
    }

    var quotaEnabled: Bool {
        get { isDestinationEnabled(.quota) }
        set { setDestinationEnabled(newValue, for: .quota) }
    }

    @Published var navigationDisplayStyle: NavigationDisplayStyle {
        didSet { defaults.set(navigationDisplayStyle.rawValue, forKey: Key.navigationDisplayStyle) }
    }

    @Published private(set) var enabledDestinations: [ToolDestination]
    var canDisableDestinationForSaving: ((ToolDestination) -> Bool)?

    private static func destinationKey(_ destination: ToolDestination) -> String {
        switch destination {
        case .terminal: return Key.terminalEnabled
        case .quota: return Key.quotaEnabled
        default: return "navigation.\(destination.rawValue)Enabled"
        }
    }

    func isDestinationEnabled(_ destination: ToolDestination) -> Bool {
        enabledDestinations.contains(destination)
    }

    func canDisableDestination(_ destination: ToolDestination) -> Bool {
        !isDestinationEnabled(destination) || enabledDestinations.count > 1
    }

    func setDestinationEnabled(_ enabled: Bool, for destination: ToolDestination) {
        guard enabled != isDestinationEnabled(destination) else { return }
        if !enabled {
            guard canDisableDestination(destination), canDisableDestinationForSaving?(destination) != false else { return }
        }
        defaults.set(enabled, forKey: Self.destinationKey(destination))
        enabledDestinations = ToolDestination.allCases.filter {
            $0 == destination ? enabled : isDestinationEnabled($0)
        }
    }

    func resetNavigationPreferences() {
        navigationDisplayStyle = .iconAndTitle
        for destination in ToolDestination.allCases {
            defaults.set(true, forKey: Self.destinationKey(destination))
        }
        enabledDestinations = ToolDestination.allCases
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
            Key.mirrorEnabled: true,
            Key.quotaEnabled: true
        ])
        closeAfterCopy = defaults.bool(forKey: Key.closeAfterCopy)
        appearance = FlowAppearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        recordingEnabled = defaults.bool(forKey: Key.recordingEnabled)
        mirrorEnabled = defaults.bool(forKey: Key.mirrorEnabled)
        navigationDisplayStyle = NavigationDisplayStyle(
            rawValue: defaults.string(forKey: Key.navigationDisplayStyle) ?? ""
        ) ?? .iconAndTitle
        let enabled = ToolDestination.allCases.filter {
            defaults.object(forKey: Self.destinationKey($0)) as? Bool ?? true
        }
        enabledDestinations = enabled.isEmpty ? [.home] : enabled
        if enabled.isEmpty { defaults.set(true, forKey: Self.destinationKey(.home)) }
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
