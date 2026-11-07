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
    var isVisible: Bool { isPresented }

    private let minimumWorkspaceSize = NSSize(width: 520, height: 420)

    init(model: AppModel, preferences: PreferencesStore, homeModel providedHomeModel: HomeDashboardModel? = nil) {
        self.model = model
        self.preferences = preferences
        shellModel = IslandShellModel()
        homeModel = providedHomeModel ?? HomeDashboardModel()
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
        openSettings: Bool = false,
        on screen: NSScreen? = nil
    ) {
        if let destination { selectDestination(destination) }
        if openSettings {
            homeModel.memoLibraryOpen = false
            homeModel.dailyReviewHistoryOpen = false
        }
        model.settingsOpen = openSettings
        model.prepareForPresentation()
        applicationsModel.loadIfNeeded()
        let presentationScreen = screen ?? activeScreen()
        present(size: expandedSizeForActiveScreen(presentationScreen), on: presentationScreen)

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
        guard homeModel.flushNotes() else {
            model.showToast("笔记保存失败，内容已保留，请重试关闭")
            return
        }
        isPresented = false
        visibilityGeneration += 1
        let generation = visibilityGeneration
        releaseLocalDevices()
        if shellModel.destination == .vibehub {
            shellModel.vibeHubLibrary.flush()
            shellModel.vibeHubAgent.discardSession()
        }
        model.cancelCredentialEditor()
        model.credentialDeleteConfirmationOpen = false
        // Stop accepting input immediately; the remaining fade is only visual.
        panel.ignoresMouseEvents = true
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : FlowMotion.windowOut
        animateWorkspace(opening: false, duration: duration)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.visibilityGeneration == generation, !self.isPresented else { return }
                self.panel.orderOut(nil)
                self.panel.contentView?.layer?.removeAnimation(forKey: "notchReveal")
                self.panel.alphaValue = 1
                self.panel.ignoresMouseEvents = false
                self.model.settingsOpen = false
                self.homeModel.dailyReviewHistoryOpen = false
                self.onVisibilityChanged?(false)
            }
        }
    }

    func hideAfterPointerExit() {
        guard !hasBlockingModal, panel.attachedSheet == nil, !panel.inLiveResize,
              NSEvent.pressedMouseButtons == 0 else { return }
        hide()
    }

    @discardableResult
    func prepareForTermination() -> Bool {
        guard homeModel.flushNotes() else {
            showExpanded(destination: .home)
            model.showToast("笔记保存失败，内容已保留，请重试保存后退出")
            return false
        }
        homeModel.audioRecorder.finishIfNeeded()
        releaseLocalDevices()
        if shellModel.destination == .vibehub {
            shellModel.vibeHubLibrary.flush()
            shellModel.vibeHubAgent.discardSession()
        }
        return true
    }

    private func present(size: NSSize, on screen: NSScreen?) {
        let wasPresented = isPresented
        visibilityGeneration += 1
        isPresented = true
        panel.ignoresMouseEvents = false
        onVisibilityChanged?(true)
        positionAtTopCenter(size: size, on: screen)
        panel.contentView?.layer?.cornerRadius = 28
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        let duration = wasPresented || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : FlowMotion.windowIn
        if !wasPresented { animateWorkspace(opening: true, duration: duration) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func animateWorkspace(opening: Bool, duration: TimeInterval) {
        guard let layer = panel.contentView?.layer else { return }
        let current = layer.animation(forKey: "notchReveal") == nil ? nil : layer.presentation()?.transform
        layer.removeAnimation(forKey: "notchReveal")
        guard duration > 0 else { return }
        // Transform the rendered surface, keeping layout, resize anchors and
        // the user's saved workspace dimensions stable throughout the reveal.
        let scale: CGFloat = 0.96
        var tucked = CATransform3DMakeScale(scale, scale, 1)
        tucked.m41 = layer.bounds.width * (0.5 - layer.anchorPoint.x) * (1 - scale)
        let topY: CGFloat = layer.isGeometryFlipped ? 0 : layer.bounds.height
        tucked.m42 = (topY - layer.bounds.height * layer.anchorPoint.y) * (1 - scale)
            + (layer.isGeometryFlipped ? -10 : 10)
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: current ?? (opening ? tucked : CATransform3DIdentity))
        animation.toValue = NSValue(caTransform3D: opening ? CATransform3DIdentity : tucked)
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: opening ? .easeOut : .easeInEaseOut)
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "notchReveal")
    }

    private func expandedSizeForActiveScreen(_ screen: NSScreen?) -> NSSize {
        let preferred = preferences.workspaceSize
        guard let screen else { return preferred }
        let visible = screen.visibleFrame
        let availableHeight = TopNotchGeometry.workspaceTop(on: screen) - visible.minY
        return NSSize(
            width: min(max(minimumWorkspaceSize.width, preferred.width), max(1, visible.width - 24)),
            height: min(max(minimumWorkspaceSize.height, preferred.height), max(1, availableHeight - 16))
        )
    }

    private func positionAtTopCenter(size: NSSize, on screen: NSScreen?) {
        // Fitting to a smaller screen must not replace the user's preferred size.
        isApplyingPresentationFrame = true
        defer { isApplyingPresentationFrame = false }
        panel.minSize = NSSize(width: 1, height: 1)
        panel.maxSize = NSSize(width: 10_000, height: 10_000)
        guard let screen else {
            panel.setContentSize(size)
            panel.center()
            panel.minSize = minimumWorkspaceSize
            return
        }
        let visible = screen.visibleFrame
        let availableHeight = TopNotchGeometry.workspaceTop(on: screen) - visible.minY
        let fittedSize = NSSize(
            width: min(size.width, visible.width - 12),
            height: min(size.height, availableHeight - 12)
        )
        let origin = NSPoint(
            x: visible.midX - fittedSize.width / 2,
            y: TopNotchGeometry.workspaceTop(on: screen) - fittedSize.height
        )
        panel.setFrame(NSRect(origin: origin, size: fittedSize), display: true)
        panel.minSize = NSSize(
            width: min(minimumWorkspaceSize.width, fittedSize.width),
            height: min(minimumWorkspaceSize.height, fittedSize.height)
        )
        panel.maxSize = NSSize(width: visible.width - 12, height: availableHeight - 12)
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
        guard let screen = panel.screen else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: TopNotchGeometry.workspaceTop(on: screen) - panel.frame.height
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
                self?.handleOutsideClick()
            }
        }
    }

    func handleOutsideClick() {
        guard panel.isVisible, !hasBlockingModal else { return }
        hide()
    }

    private var hasBlockingModal: Bool {
        model.settingsOpen
            || model.promptRunnerOpen
            || model.promptDeleteConfirmationOpen
            || model.credentialEditorOpen
            || model.credentialDeleteConfirmationOpen
            || homeModel.dailyReviewHistoryOpen
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
                homeModel.closeMemoLibrary()
                return true
            }
            return false
        }

        if homeModel.dailyReviewHistoryOpen {
            if keyCode == UInt16(kVK_Escape) {
                homeModel.dailyReviewHistoryOpen = false
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
        if command && key == "o", shellModel.destination == .clipboard, model.selectedOpenableURL != nil {
            model.openSelectedLink()
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
