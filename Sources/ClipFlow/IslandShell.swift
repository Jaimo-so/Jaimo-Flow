import AppKit
import Combine
import SwiftUI

enum ToolDestination: String, CaseIterable, Identifiable {
    case home
    case applications
    case prompts
    case clipboard
    case vibehub

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "首页"
        case .applications: return "应用"
        case .prompts: return "提示词"
        case .clipboard: return "剪切板"
        case .vibehub: return "Vibehub"
        }
    }

    var symbolName: String {
        switch self {
        case .home: return "house"
        case .applications: return "square.grid.2x2"
        case .prompts: return "sparkles"
        case .clipboard: return "doc.on.clipboard"
        case .vibehub: return "text.bubble"
        }
    }
}

@MainActor
final class IslandShellModel: ObservableObject {
    @Published var destination: ToolDestination {
        didSet { defaults.set(destination.rawValue, forKey: Self.destinationKey) }
    }

    private static let destinationKey = "island.lastDestination"
    private let defaults: UserDefaults
    lazy var vibeHubLibrary = VibeHubLibraryModel()
    private var vibeHubAgentSubscription: AnyCancellable?
    lazy var vibeHubAgent: VibeHubAgentModel = {
        let agent = VibeHubAgentModel(library: vibeHubLibrary, defaults: defaults)
        vibeHubAgentSubscription = agent.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        return agent
    }()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        destination = ToolDestination(rawValue: defaults.string(forKey: Self.destinationKey) ?? "") ?? .home
    }
}

struct IslandRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var shell: IslandShellModel
    @ObservedObject var homeModel: HomeDashboardModel
    @ObservedObject var applicationsModel: ApplicationsModel
    let onClose: () -> Void
    let onQuit: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        ZStack {
            VisualEffectBackground().ignoresSafeArea()
            theme.canvas.opacity(0.97).ignoresSafeArea()

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
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(theme.hairline, lineWidth: 0.5)
        }
        .animation(reduceMotion ? FlowMotion.reduced : FlowMotion.content, value: model.settingsOpen)
        .animation(reduceMotion ? FlowMotion.reduced : FlowMotion.content, value: model.toastMessage)
    }

    private func expandedContent(_ theme: ClipFlowTheme) -> some View {
        VStack(spacing: 0) {
            topBar(theme)
                .disabled(libraryModalOpen)
                .accessibilityHidden(libraryModalOpen)
            Rectangle().fill(theme.hairline).frame(height: 0.5)
            destinationContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .disabled(model.settingsOpen)
    }

    private var libraryModalOpen: Bool {
        model.promptEditorOpen
            || model.promptRunnerOpen
            || model.promptDeleteConfirmationOpen
            || model.credentialEditorOpen
            || model.credentialDeleteConfirmationOpen
            || homeModel.memoLibraryOpen
            || (shell.destination == .vibehub && shell.vibeHubAgent.panel != .closed)
    }

    private func topBar(_ theme: ClipFlowTheme) -> some View {
        GeometryReader { proxy in
            HStack(spacing: proxy.size.width < 720 ? 8 : 18) {
                HStack(spacing: 9) {
                    IslandBrandMark(size: 28)
                    if proxy.size.width >= 820 {
                        Text("Jaimo Flow")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .padding(.leading, 2)

                HStack(spacing: 2) {
                    ForEach(ToolDestination.allCases) { destination in
                        Button {
                            selectDestination(destination)
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: destination.symbolName)
                                    .font(.system(size: 13, weight: .medium))
                                if proxy.size.width >= 650 {
                                    Text(destination.title)
                                        .font(.system(size: 12, weight: shell.destination == destination ? .semibold : .regular))
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                            }
                            .foregroundStyle(shell.destination == destination ? theme.foreground : theme.muted)
                            .frame(minWidth: proxy.size.width >= 650 ? (destination == .vibehub ? 86 : 70) : 42, maxHeight: .infinity)
                            .background {
                                if shell.destination == destination {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(theme.chip)
                                        .padding(.vertical, 10)
                                }
                            }
                            .overlay(alignment: .bottom) {
                                if shell.destination == destination {
                                    Capsule()
                                        .fill(theme.accent)
                                        .frame(height: 2)
                                        .padding(.horizontal, 14)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(IslandNavigationButtonStyle())
                        .accessibilityLabel(destination.title)
                        .help(destination.title)
                        .accessibilityAddTraits(shell.destination == destination ? [.isSelected] : [])
                    }
                }
                .frame(maxHeight: .infinity)

                Spacer(minLength: 4)

                HStack(spacing: 3) {
                    Button {
                        model.settingsOpen = true
                    } label: {
                        Image(systemName: "gearshape")
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(FlowIconButtonStyle())
                    .accessibilityLabel("打开设置")
                    .help("设置（⌘,）")

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(FlowIconButtonStyle())
                    .accessibilityLabel("隐藏 Jaimo Flow")
                    .help("隐藏 Jaimo Flow")

                    Button(action: onQuit) {
                        Image(systemName: "power")
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(FlowIconButtonStyle(danger: true))
                    .accessibilityLabel("退出 Jaimo Flow")
                    .help("退出 Jaimo Flow（⌘Q）")
                }
            }
            .padding(.horizontal, 22)
        }
        .frame(height: 61)
    }

    @ViewBuilder
    private var destinationContent: some View {
        switch shell.destination {
        case .home:
            HomeDashboardView(
                model: homeModel,
                applicationsModel: applicationsModel,
                audioRecorderModel: homeModel.audioRecorder,
                memoModel: homeModel.memoLibrary,
                onOpenApplications: { selectDestination(.applications) }
            )
        case .applications:
            ApplicationsView(model: applicationsModel)
        case .prompts:
            ContentView(model: model, fixedMode: .prompts, embedded: true)
                .id("prompts-library")
        case .clipboard:
            ContentView(model: model, fixedMode: .history, embedded: true)
                .id("clipboard-library")
        case .vibehub:
            VibeHubLibraryView(library: shell.vibeHubLibrary, appModel: model, agent: shell.vibeHubAgent)
        }
    }

    private func selectDestination(_ destination: ToolDestination) {
        guard shell.destination != destination else { return }
        if shell.destination == .vibehub { shell.vibeHubLibrary.flush() }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            shell.destination = destination
            switch destination {
            case .prompts: model.setMode(.prompts)
            case .clipboard: model.setMode(.history)
            case .home, .applications, .vibehub: break
            }
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
                RoundedRectangle(cornerRadius: 10, style: .continuous)
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
    static let jaimoFlushMemos = Notification.Name("jaimo.flushMemos")
    static let jaimoFocusVibeHubSearch = Notification.Name("jaimo.focusVibeHubSearch")
    static let jaimoFocusVibeHubTitle = Notification.Name("jaimo.focusVibeHubTitle")
}
