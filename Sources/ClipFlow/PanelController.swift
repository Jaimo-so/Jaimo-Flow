import AppKit
import Carbon
import ClipFlowKit
import QuartzCore
import SwiftUI

final class ClipFlowPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class ClipFlowHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let panel: ClipFlowPanel
    private let model: AppModel
    private let preferences: PreferencesStore
    private let shellModel: IslandShellModel
    private let homeModel: HomeDashboardModel
    private let applicationsModel: ApplicationsModel
    private var localKeyMonitor: Any?
    private var globalMouseMonitor: Any?
    private var isPresented = false
    private var visibilityGeneration = 0
    private var isApplyingPresentationFrame = false
    var onVisibilityChanged: ((Bool) -> Void)?

    private let minimumWorkspaceSize = NSSize(width: 520, height: 420)

    init(model: AppModel, preferences: PreferencesStore) {
        self.model = model
        self.preferences = preferences
        shellModel = IslandShellModel()
        homeModel = HomeDashboardModel()
        applicationsModel = ApplicationsModel()
        panel = ClipFlowPanel(
            contentRect: NSRect(origin: .zero, size: preferences.workspaceSize),
            styleMask: [
                .borderless,
                .nonactivatingPanel,
                .hudWindow,
                .utilityWindow,
                .resizable,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.delegate = self
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false

        let rootView = IslandRootView(
            model: model,
            shell: shellModel,
            homeModel: homeModel,
            applicationsModel: applicationsModel,
            onClose: { [weak self] in self?.hide() },
            onQuit: { NSApp.terminate(nil) }
        )
        let hostingView = ClipFlowHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.cornerRadius = 28
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        panel.contentView = hostingView

        model.onRequestClose = { [weak self] in self?.hide() }
        // The floating panel would otherwise cover the Finder window we reveal.
        homeModel.audioRecorder.onWillRevealRecording = { [weak self] in self?.hide() }
        installKeyMonitor()
        installOutsideClickMonitor()
    }

    deinit {
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
    }

    func toggle() {
        isPresented ? hide() : showExpanded()
    }

    func toggleHotKey() {
        toggle()
    }

    func show(openSettings: Bool = false) {
        showExpanded(destination: shellModel.destination, openSettings: openSettings)
    }

    func showExpanded(
        destination: ToolDestination? = nil,
        openSettings: Bool = false
    ) {
        if let destination { selectDestination(destination) }
        if openSettings { homeModel.memoLibraryOpen = false }
        model.settingsOpen = openSettings
        model.prepareForPresentation()
        applicationsModel.loadIfNeeded()
        present(size: expandedSizeForActiveScreen())

        if shellModel.destination == .prompts || shellModel.destination == .clipboard {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .clipFlowFocusSearch, object: nil)
            }
        }
    }

    func showUpdateSettings() {
        showExpanded(openSettings: true)
        model.updateManager.checkForUpdates()
    }

    func hide() {
        guard isPresented else { return }
        isPresented = false
        visibilityGeneration += 1
        let generation = visibilityGeneration
        releaseLocalDevices()
        homeModel.flushQuickNote()
        if shellModel.destination == .vibehub {
            shellModel.vibeHubLibrary.flush()
            shellModel.vibeHubAgent.discardSession()
        }
        model.cancelCredentialEditor()
        model.credentialDeleteConfirmationOpen = false
        // Stop accepting input immediately; the remaining fade is only visual.
        panel.ignoresMouseEvents = true
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : FlowMotion.windowOut
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.visibilityGeneration == generation, !self.isPresented else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
                self.panel.ignoresMouseEvents = false
                self.model.settingsOpen = false
                self.homeModel.memoLibraryOpen = false
                self.onVisibilityChanged?(false)
            }
        }
    }

    func prepareForTermination() {
        homeModel.audioRecorder.finishIfNeeded()
        releaseLocalDevices()
        homeModel.flushQuickNote()
        NotificationCenter.default.post(name: .jaimoFlushMemos, object: nil)
        if shellModel.destination == .vibehub {
            shellModel.vibeHubLibrary.flush()
            shellModel.vibeHubAgent.discardSession()
        }
    }

    private func present(size: NSSize) {
        let wasPresented = isPresented
        visibilityGeneration += 1
        isPresented = true
        panel.ignoresMouseEvents = false
        onVisibilityChanged?(true)
        positionAtTopCenter(size: size)
        panel.contentView?.layer?.cornerRadius = 28
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        let duration = wasPresented || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : FlowMotion.windowIn
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func expandedSizeForActiveScreen() -> NSSize {
        let preferred = preferences.workspaceSize
        guard let visible = activeScreen()?.visibleFrame else { return preferred }
        return NSSize(
            width: min(max(minimumWorkspaceSize.width, preferred.width), max(1, visible.width - 24)),
            height: min(max(minimumWorkspaceSize.height, preferred.height), max(1, visible.height - 16))
        )
    }

    private func positionAtTopCenter(size: NSSize) {
        // Fitting to a smaller screen must not replace the user's preferred size.
        isApplyingPresentationFrame = true
        defer { isApplyingPresentationFrame = false }
        panel.minSize = NSSize(width: 1, height: 1)
        panel.maxSize = NSSize(width: 10_000, height: 10_000)
        guard let visible = activeScreen()?.visibleFrame else {
            panel.setContentSize(size)
            panel.center()
            panel.minSize = minimumWorkspaceSize
            return
        }
        let fittedSize = NSSize(
            width: min(size.width, visible.width - 12),
            height: min(size.height, visible.height - 12)
        )
        let origin = NSPoint(
            x: visible.midX - fittedSize.width / 2,
            y: visible.maxY - fittedSize.height - 8
        )
        panel.setFrame(NSRect(origin: origin, size: fittedSize), display: true)
        panel.minSize = NSSize(
            width: min(minimumWorkspaceSize.width, fittedSize.width),
            height: min(minimumWorkspaceSize.height, fittedSize.height)
        )
        panel.maxSize = NSSize(width: visible.width - 12, height: visible.height - 12)
    }

    func windowDidResize(_ notification: Notification) {
        guard isPresented, !isApplyingPresentationFrame else { return }
        preferences.workspaceSize = panel.frame.size
        // Leave AppKit's drag anchor untouched while the mouse is held down.
        // Moving the origin here makes the resize edge move away from the cursor.
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard isPresented else { return }
        // Align to the top center only after AppKit releases the resize edge.
        alignWorkspaceToTopCenter()
    }

    private func alignWorkspaceToTopCenter() {
        guard let visible = panel.screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.maxY - panel.frame.height - 8
        ))
    }

    private func activeScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func selectDestination(_ destination: ToolDestination) {
        if shellModel.destination == .vibehub { shellModel.vibeHubLibrary.flush() }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if shellModel.destination != destination {
                shellModel.destination = destination
            }
            switch destination {
            case .prompts: model.setMode(.prompts)
            case .clipboard: model.setMode(.history)
            case .home, .applications, .vibehub: break
            }
        }
    }

    private func releaseLocalDevices() {
        NotificationCenter.default.post(name: .jaimoStopLocalDevices, object: nil)
    }

    private func installKeyMonitor() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let keyCode = event.keyCode
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let handled = MainActor.assumeIsolated {
                self.handleKey(keyCode: keyCode, flags: flags, key: key)
            }
            return handled ? nil : event
        }
    }

    private func installOutsideClickMonitor() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.panel.isVisible else { return }
                guard !self.hasBlockingModal else { return }
                self.hide()
            }
        }
    }

    private var hasBlockingModal: Bool {
        model.settingsOpen
            || model.promptEditorOpen
            || model.promptRunnerOpen
            || model.promptDeleteConfirmationOpen
            || model.credentialEditorOpen
            || model.credentialDeleteConfirmationOpen
            || homeModel.memoLibraryOpen
            || (shellModel.destination == .vibehub && shellModel.vibeHubAgent.panel != .closed)
    }

    private func handleKey(keyCode: UInt16, flags: NSEvent.ModifierFlags, key: String) -> Bool {
        guard isPresented else { return false }
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)
        let option = flags.contains(.option)

        if command, routeStandardTextCommand(key) {
            return true
        }

        if command && key == "q" {
            NSApp.terminate(nil)
            return true
        }

        if shellModel.destination == .vibehub, shellModel.vibeHubAgent.panel != .closed {
            if keyCode == UInt16(kVK_Escape) {
                shellModel.vibeHubAgent.dismissPanel()
                return true
            }
            if command && keyCode == UInt16(kVK_Return) {
                switch shellModel.vibeHubAgent.panel {
                case .composer: shellModel.vibeHubAgent.organizeForPreview()
                case .preview: shellModel.vibeHubAgent.saveReviewedPhrase()
                case .settings: shellModel.vibeHubAgent.saveSettings()
                case .closed: break
                }
                return true
            }
            return false
        }

        if command && key == "," {
            guard !model.promptEditorOpen,
                  !model.promptRunnerOpen,
                  !model.promptDeleteConfirmationOpen,
                  !model.credentialEditorOpen,
                  !model.credentialDeleteConfirmationOpen else { return true }
            model.settingsOpen.toggle()
            return true
        }

        if model.credentialEditorOpen {
            if keyCode == UInt16(kVK_Escape) {
                model.cancelCredentialEditor()
                return true
            }
            if command && key == "s" {
                model.saveCredentialDraft()
                return true
            }
            return false
        }

        if model.credentialDeleteConfirmationOpen {
            if keyCode == UInt16(kVK_Escape) {
                model.credentialDeleteConfirmationOpen = false
                return true
            }
            return false
        }

        if model.promptDeleteConfirmationOpen {
            if keyCode == UInt16(kVK_Escape) {
                model.promptDeleteConfirmationOpen = false
                return true
            }
            return false
        }

        if model.promptRunnerOpen {
            if keyCode == UInt16(kVK_Escape) {
                model.promptRunnerOpen = false
                return true
            }
            return false
        }

        if model.promptEditorOpen {
            if keyCode == UInt16(kVK_Escape) {
                model.promptEditorOpen = false
                return true
            }
            if command && key == "s" {
                model.savePromptDraft()
                return true
            }
            return false
        }

        if model.settingsOpen {
            if keyCode == UInt16(kVK_Escape) {
                model.settingsOpen = false
                return true
            }
            return false
        }

        if homeModel.memoLibraryOpen {
            if keyCode == UInt16(kVK_Escape) {
                homeModel.memoLibraryOpen = false
                return true
            }
            return false
        }

        if command, let destination = destinationForShortcut(key) {
            // The panel is already visible: changing tabs must not reposition
            // the window, repeat presentation work or reset list selection.
            selectDestination(destination)
            return true
        }

        if shellModel.destination == .home, option, homeModel.editingWidget != nil {
            if keyCode == UInt16(kVK_UpArrow) {
                homeModel.moveSelectedWidget(by: -1)
                return true
            }
            if keyCode == UInt16(kVK_DownArrow) {
                homeModel.moveSelectedWidget(by: 1)
                return true
            }
        }

        if command && key == "f" {
            switch shellModel.destination {
            case .vibehub:
                NotificationCenter.default.post(name: .jaimoFocusVibeHubSearch, object: nil)
                return true
            case .applications:
                NotificationCenter.default.post(name: .jaimoFocusApplicationSearch, object: nil)
                return true
            case .prompts, .clipboard:
                NotificationCenter.default.post(name: .clipFlowFocusSearch, object: nil)
                DispatchQueue.main.async { [weak panel] in
                    panel?.firstResponder?.tryToPerform(#selector(NSText.selectAll(_:)), with: nil)
                }
                return true
            case .home:
                return false
            }
        }

        if command && key == "n", shellModel.destination == .clipboard, model.isCredentialGroup {
            model.beginCreateCredential()
            return true
        }
        if command && key == "e", shellModel.destination == .clipboard, model.isCredentialGroup {
            model.beginEditCredential()
            return true
        }

        if command && key == "n" {
            if shellModel.destination == .vibehub {
                if shellModel.vibeHubLibrary.createPhrase() != nil {
                    NotificationCenter.default.post(name: .jaimoFocusVibeHubTitle, object: nil)
                }
                return true
            }
            showExpanded(destination: .prompts)
            model.beginCreatePrompt()
            return true
        }

        if command && key == "e", shellModel.destination == .prompts {
            model.beginEditSelectedPrompt()
            return true
        }

        if keyCode == UInt16(kVK_Escape) {
            if shellModel.destination == .clipboard, !model.query.isEmpty {
                model.query = ""
            } else if shellModel.destination == .prompts, !model.promptQuery.isEmpty {
                model.promptQuery = ""
            } else if shellModel.destination == .vibehub, !shellModel.vibeHubLibrary.query.isEmpty {
                shellModel.vibeHubLibrary.query = ""
            } else {
                hide()
            }
            return true
        }

        if shellModel.destination == .vibehub, command && key == "s" {
            shellModel.vibeHubLibrary.flush()
            return true
        }

        guard shellModel.destination == .prompts || shellModel.destination == .clipboard else {
            return false
        }
        if !model.isCredentialGroup {
            guard case .ready = model.phase else { return false }
        }

        if command && key == "s" {
            model.toggleFavorite()
            return true
        }
        if command && (keyCode == UInt16(kVK_Delete) || keyCode == UInt16(kVK_ForwardDelete)) {
            model.deleteSelected()
            return true
        }

        switch keyCode {
        case UInt16(kVK_Return) where model.isCredentialGroup,
             UInt16(kVK_ANSI_KeypadEnter) where model.isCredentialGroup:
            model.copySelected()
            return true
        case UInt16(kVK_UpArrow):
            model.moveSelection(-1)
            return true
        case UInt16(kVK_DownArrow):
            model.moveSelection(1)
            return true
        case UInt16(kVK_LeftArrow) where model.focusArea == .tabs:
            model.cycleFilter(-1)
            return true
        case UInt16(kVK_RightArrow) where model.focusArea == .tabs:
            model.cycleFilter(1)
            return true
        case UInt16(kVK_Home) where model.focusArea == .tabs:
            if model.libraryMode == .history { model.setFilter(.all) }
            else { model.setPromptScope(.all) }
            return true
        case UInt16(kVK_End) where model.focusArea == .tabs:
            if model.libraryMode == .history { model.setFilter(.apiKey) }
            else if let last = model.promptScopes.last { model.setPromptScope(last) }
            return true
        case UInt16(kVK_Tab) where model.focusArea == .other:
            model.cycleFilter(shift ? -1 : 1)
            return true
        default:
            return false
        }
    }

    private func destinationForShortcut(_ key: String) -> ToolDestination? {
        switch key {
        case "1": return .home
        case "2": return .applications
        case "3": return .prompts
        case "4": return .clipboard
        case "5": return .vibehub
        default: return nil
        }
    }

    private func routeStandardTextCommand(_ key: String) -> Bool {
        let action: Selector
        switch key {
        case "a": action = #selector(NSText.selectAll(_:))
        case "c": action = #selector(NSText.copy(_:))
        case "v": action = #selector(NSText.paste(_:))
        case "x": action = #selector(NSText.cut(_:))
        default: return false
        }
        guard let responder = panel.firstResponder else { return false }
        return responder.tryToPerform(action, with: nil)
    }
}
