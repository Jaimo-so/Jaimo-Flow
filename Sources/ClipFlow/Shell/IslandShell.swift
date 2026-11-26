import AppKit
import Combine
import SwiftUI

enum ToolDestination: String, CaseIterable, Identifiable {
    case home
    case applications
    case prompts
    case clipboard
    case vibehub
    case terminal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "首页"
        case .applications: return "应用"
        case .prompts: return "提示词"
        case .clipboard: return "剪切板"
        case .vibehub: return "Vibehub"
        case .terminal: return "终端"
        }
    }

    var symbolName: String {
        switch self {
        case .home: return "house"
        case .applications: return "square.grid.2x2"
        case .prompts: return "sparkles"
        case .clipboard: return "doc.on.clipboard"
        case .vibehub: return "text.bubble"
        case .terminal: return "terminal"
        }
    }
}

@MainActor
final class IslandShellModel: ObservableObject {
    @Published private(set) var destination: ToolDestination {
        didSet { defaults.set(destination.rawValue, forKey: Self.destinationKey) }
    }

    private static let destinationKey = "island.lastDestination"
    private let defaults: UserDefaults
    @Published private var terminalEnabled: Bool
    private var terminalPreferenceSubscription: AnyCancellable?
    @Published private(set) var terminalSession: TerminalSession?
    var isTerminalSessionLoaded: Bool { terminalSession != nil }
    var isTerminalChoosingFolder: Bool { terminalSession?.isChoosingFolder == true }
    lazy var vibeHubLibrary = VibeHubLibraryModel()
    private var vibeHubAgentSubscription: AnyCancellable?
    lazy var vibeHubAgent: VibeHubAgentModel = {
        let agent = VibeHubAgentModel(library: vibeHubLibrary, defaults: defaults)
        vibeHubAgentSubscription = agent.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        return agent
    }()

    init(preferences: PreferencesStore) {
        defaults = preferences.defaults
        terminalEnabled = preferences.terminalEnabled
        let savedDestination = ToolDestination(rawValue: preferences.defaults.string(forKey: Self.destinationKey) ?? "") ?? .home
        if savedDestination == .terminal, !preferences.terminalEnabled {
            destination = .home
            preferences.defaults.set(ToolDestination.home.rawValue, forKey: Self.destinationKey)
        } else {
            destination = savedDestination
        }
        terminalPreferenceSubscription = preferences.$terminalEnabled.dropFirst().removeDuplicates().sink { [weak self] enabled in
            self?.setTerminalEnabled(enabled)
        }
    }

    var availableDestinations: [ToolDestination] {
        ToolDestination.allCases.filter { $0 != .terminal || terminalEnabled }
    }

    func selectDestination(_ destination: ToolDestination) {
        guard self.destination != destination, availableDestinations.contains(destination) else { return }
        self.destination = destination
    }

    private func setTerminalEnabled(_ enabled: Bool) {
        guard terminalEnabled != enabled else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            terminalEnabled = enabled
            if !enabled {
                if destination == .terminal { selectDestination(.home) }
                terminalSession?.shutdown()
                terminalSession = nil
            }
        }
    }

    func activateTerminalIfSelected() {
        guard terminalEnabled, destination == .terminal, terminalSession == nil else { return }
        terminalSession = TerminalSession()
    }
}

struct AppearanceRootView: View {
    @ObservedObject var preferences: PreferencesStore
    @Environment(\.colorScheme) private var systemColorScheme
    let content: IslandRootView

    var body: some View {
        content
            .environment(\.colorScheme, preferences.appearance.colorScheme ?? systemColorScheme)
    }
}

struct IslandRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var shell: IslandShellModel
    @ObservedObject var homeModel: HomeDashboardModel
    @ObservedObject var applicationsModel: ApplicationsModel
    let onSelectDestination: (ToolDestination) -> Void
    let onSavePrompt: () -> Void
    let onSettingsClosed: () -> Void
    let onRecentApplicationsAppear: () -> Void
    let onClose: () -> Void
    let onQuit: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        ZStack {
            FlowWindowBackground(theme: theme).ignoresSafeArea()

            expandedContent(theme)

            if model.settingsOpen {
                SettingsView(model: model, homeModel: homeModel)
                    .transition(FlowMotion.reveal(reduceMotion: reduceMotion))
                    .zIndex(30)
            }

            if let message = model.toastMessage {
                IslandToast(message: message)
                    .transition(FlowMotion.reveal(reduceMotion: reduceMotion, distance: 10))
                    .zIndex(40)
            }
        }
        .foregroundStyle(theme.foreground)
        .clipShape(RoundedRectangle(cornerRadius: WindowMetrics.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: WindowMetrics.cornerRadius, style: .continuous)
                .strokeBorder(theme.highlight, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .animation(reduceMotion ? FlowMotion.reduced : FlowMotion.content, value: model.settingsOpen)
        .animation(reduceMotion ? FlowMotion.reduced : FlowMotion.content, value: model.toastMessage)
        .onChange(of: model.settingsOpen) { if !$0 { onSettingsClosed() } }
    }

    private func expandedContent(_ theme: ClipFlowTheme) -> some View {
        VStack(spacing: 0) {
            topBar(theme)
                .disabled(libraryModalOpen)
                .accessibilityHidden(libraryModalOpen)
            ZStack {
                if shell.destination != .terminal {
                    destinationContent
                        .disabled(isLibraryDestination && model.libraryDialogOpen)
                }
                if let terminalSession = shell.terminalSession {
                    TerminalWorkspace(session: terminalSession, active: shell.destination == .terminal)
                        .opacity(shell.destination == .terminal ? 1 : 0)
                        .allowsHitTesting(shell.destination == .terminal)
                        .accessibilityHidden(shell.destination != .terminal)
                }
                if isLibraryDestination {
                    PromptLibraryDialogs(model: model.prompts, onSave: onSavePrompt)
                        .zIndex(22)
                    CredentialLibraryDialogs(model: model.credentials)
                        .zIndex(28)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .disabled(model.settingsOpen)
    }

    private var isLibraryDestination: Bool {
        shell.destination == .clipboard || shell.destination == .prompts
    }

    private var libraryModalOpen: Bool {
        model.libraryDialogOpen
            || homeModel.memoLibraryOpen
            || homeModel.dailyReviewHistoryOpen
            || homeModel.recordingWorkspaceOpen
            || (shell.destination == .vibehub && shell.vibeHubAgent.panel != .closed)
    }

    private func topBar(_ theme: ClipFlowTheme) -> some View {
        GeometryReader { proxy in
            let showLabels = proxy.size.width >= 760
            let showBrandName = proxy.size.width >= 800
            ZStack {
                HStack {
                    HStack(spacing: 6) {
                        IslandBrandMark(size: 26)
                        if showBrandName {
                            Text("Jaimo Flow")
                                .font(.system(size: 13, weight: .semibold))
                        }
                    }
                    .padding(.leading, 7)
                    .padding(.trailing, showBrandName ? 13 : 7)
                    .frame(height: 40)
                    .flowGlass(Capsule(), fill: theme.chip, theme: theme)
                    .accessibilityLabel("Jaimo Flow")

                    Spacer()
                    windowActions(theme)
                }

                HStack(spacing: 2) {
                    ForEach(shell.availableDestinations) { destination in
                        let selected = shell.destination == destination
                        Button {
                            if !selected { onSelectDestination(destination) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: destination.symbolName)
                                    .foregroundStyle(selected ? theme.accent : theme.foregroundSecondary)
                                if showLabels {
                                    Text(destination.title)
                                        .fontWeight(selected ? .semibold : .medium)
                                }
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(selected ? theme.foreground : theme.foregroundSecondary)
                            .fixedSize()
                            .padding(.horizontal, showLabels ? 12 : 9)
                            .frame(minWidth: showLabels ? 58 : 34, minHeight: 32)
                            .background {
                                if selected {
                                    Capsule().fill(theme.chipHigh)
                                        .overlay { Capsule().strokeBorder(theme.highlight) }
                                        .shadow(color: .black.opacity(0.09), radius: 3, y: 2)
                                }
                            }
                            .contentShape(Capsule())
                        }
                        .buttonStyle(IslandNavigationButtonStyle())
                        .accessibilityLabel(destination.title)
                        .help(destination.title)
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                    }
                }
                .padding(4)
                .flowGlass(Capsule(), fill: theme.chip, theme: theme)
                .shadow(color: .black.opacity(0.07), radius: 5, y: 3)
            }
            .padding(.horizontal, 18)
            .frame(maxHeight: .infinity)
        }
        .frame(height: 62)
    }

    private func windowActions(_ theme: ClipFlowTheme) -> some View {
        HStack(spacing: 3) {
            Button {
                model.settingsOpen = true
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(FlowIconButtonStyle())
            .accessibilityLabel("打开设置")
            .help("设置（⌘,）")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(FlowIconButtonStyle())
            .accessibilityLabel("隐藏 Jaimo Flow")
            .help("隐藏 Jaimo Flow")

            Button(action: onQuit) {
                Image(systemName: "power")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(FlowIconButtonStyle(danger: true))
            .accessibilityLabel("退出 Jaimo Flow")
            .help("退出 Jaimo Flow（⌘Q）")
        }
        .padding(4)
        .flowGlass(Capsule(), fill: theme.chip, theme: theme)
    }

    @ViewBuilder
    private var destinationContent: some View {
        switch shell.destination {
        case .home:
            HomeDashboardView(
                model: homeModel,
                applicationsModel: applicationsModel,
                audioRecorderModel: homeModel.audioRecorder,
                cameraModel: homeModel.camera,
                memoModel: homeModel.memoLibrary,
                onOpenApplications: { onSelectDestination(.applications) },
                onRecentApplicationsAppear: onRecentApplicationsAppear
            )
        case .applications:
            ApplicationsView(model: applicationsModel)
        case .prompts:
            PromptLibraryPage(
                model: model.prompts,
                phase: model.phase,
                onReload: model.load,
                onSelectRow: { model.focusArea = .other },
                onSearchFocusChange: model.setSearchFocused
            )
        case .clipboard:
            ClipboardPage(app: model, phase: model.phase)
        case .vibehub:
            VibeHubLibraryView(library: shell.vibeHubLibrary, appModel: model, agent: shell.vibeHubAgent)
        case .terminal:
            EmptyView()
        }
    }
}

private struct IslandBrandMark: View {
    let size: CGFloat
    // Decode the same icon used by Finder and the Dock only once.
    private static let appIcon: NSImage = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }()

    var body: some View {
        Image(nsImage: Self.appIcon)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct IslandNavigationButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Capsule()
                    .fill(hovering ? ClipFlowTheme(scheme: colorScheme).chip.opacity(0.5) : .clear)
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
            .onHover { hovering = $0 }
            .transaction {
                $0.animation = nil
                $0.disablesAnimations = true
            }
    }
}

private struct IslandToast: View {
    let message: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        VStack {
            Spacer()
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.foreground)
                .padding(.horizontal, 15)
                .padding(.vertical, 8)
                .background(theme.glass.opacity(0.98))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.hairline, lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .shadow(color: .black.opacity(0.34), radius: 16, y: 8)
                .padding(.bottom, shellToastBottomPadding)
                .accessibilityLabel(message)
                .accessibilityAddTraits(.updatesFrequently)
        }
        .allowsHitTesting(false)
    }

    private var shellToastBottomPadding: CGFloat { 24 }
}

extension Notification.Name {
    static let jaimoFocusQuickNote = Notification.Name("jaimo.focusQuickNote")
    static let jaimoStartCamera = Notification.Name("jaimo.startCamera")
    static let jaimoFocusApplicationSearch = Notification.Name("jaimo.focusApplicationSearch")
    static let jaimoStopLocalDevices = Notification.Name("jaimo.stopLocalDevices")
    static let jaimoFocusVibeHubSearch = Notification.Name("jaimo.focusVibeHubSearch")
    static let jaimoFocusVibeHubTitle = Notification.Name("jaimo.focusVibeHubTitle")
}
