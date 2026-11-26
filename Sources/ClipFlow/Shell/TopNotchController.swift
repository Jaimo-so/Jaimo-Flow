import AppKit
import QuartzCore
import SwiftUI
import Combine

final class TopNotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FileRelayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum TopNotchGeometry {
    static func frame(screen: NSRect, visible: NSRect, safeAreaTop: CGFloat = 0, hardwareWidth: CGFloat = 0, hasItems: Bool = false) -> NSRect {
        let height = max(24, safeAreaTop, screen.maxY - visible.maxY)
        let width = min(hardwareWidth > 0 ? max(164, hardwareWidth + (hasItems ? 120 : 64)) : (hasItems ? 224 : 164), screen.width)
        return NSRect(x: screen.midX - width / 2, y: screen.maxY - height, width: width, height: height)
    }

    static func frame(on screen: NSScreen, hasItems: Bool = false) -> NSRect {
        let hardwareWidth: CGFloat
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            hardwareWidth = max(0, right.minX - left.maxX)
        } else {
            hardwareWidth = 0
        }
        return frame(screen: screen.frame, visible: screen.visibleFrame,
                     safeAreaTop: screen.safeAreaInsets.top, hardwareWidth: hardwareWidth, hasItems: hasItems)
    }

    static func workspaceTop(on screen: NSScreen) -> CGFloat {
        min(screen.visibleFrame.maxY, frame(on: screen).minY)
    }
}

@MainActor
private final class TopNotchAppearance: ObservableObject {
    @Published var expanded = false
    @Published var hardwareWidth: CGFloat = 0
}

@MainActor
final class TopNotchController: NSObject {
    private let defaults: UserDefaults
    private let panelController: PanelController
    let relayModel: FileRelayModel
    let notchPanel: TopNotchPanel
    let relayPanel: FileRelayPanel
    private let appearance = TopNotchAppearance()
    private var globalPointerMonitor: Any?
    private var localPointerMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var pendingOpen: DispatchWorkItem?
    private var pendingClose: DispatchWorkItem?
    private var relayPresented = false
    private var relayGeneration = 0
    private var requiresPointerExit = false
    private var isDraggingFiles = false
    private var dragOpenedRelay = false
    private var contextMenuOpen = false
    private var running = false
    private var idleDragChangeCount: Int
    private var lastPointerLocation = NSPoint.zero
    private var itemsObserver: AnyCancellable?
    private var dragOutObserver: AnyCancellable?

    var isEnabled: Bool {
        get { defaults.object(forKey: "topNotch.isEnabled") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "topNotch.isEnabled")
            newValue ? showIfEnabled() : hide()
        }
    }

    init(panelController: PanelController, relayModel: FileRelayModel? = nil,
         defaults: UserDefaults = .standard, monitorsPointer: Bool = true) {
        self.panelController = panelController
        self.relayModel = relayModel ?? FileRelayModel()
        self.defaults = defaults
        idleDragChangeCount = NSPasteboard(name: .drag).changeCount
        notchPanel = TopNotchPanel(contentRect: NSRect(x: 0, y: 0, width: 164, height: 24),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        relayPanel = FileRelayPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 96),
                                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                                   backing: .buffered, defer: false)
        super.init()
        configurePanels()
        itemsObserver = self.relayModel.$items.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshPosition() }
        }
        dragOutObserver = self.relayModel.$isDraggingOut.dropFirst().sink { [weak self] draggingOut in
            guard let self, !draggingOut else { return }
            self.idleDragChangeCount = NSPasteboard(name: .drag).changeCount
        }
        if monitorsPointer { installPointerMonitors() }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPosition() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPosition() }
        }
    }

    deinit {
        pendingOpen?.cancel()
        pendingClose?.cancel()
        if let globalPointerMonitor { NSEvent.removeMonitor(globalPointerMonitor) }
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    func showIfEnabled() {
        guard isEnabled else { return }
        running = true
        refreshPosition()
        notchPanel.orderFrontRegardless()
    }

    func hide() {
        running = false
        cancelPendingTransitions()
        hideRelay(animated: false)
        notchPanel.orderOut(nil)
    }

    func toggleVisibility() { isEnabled.toggle() }

    func workspaceVisibilityChanged(_ visible: Bool) {
        cancelPendingTransitions()
        appearance.expanded = visible || relayPresented
        if visible {
            hideRelay(animated: false)
        } else {
            // Explicit close / Escape must stay closed until the pointer leaves
            // the notch, even if the user moves a few pixels within it.
            requiresPointerExit = notchPanel.frame.contains(NSEvent.mouseLocation)
        }
    }

    private func configurePanels() {
        for panel in [notchPanel as NSPanel, relayPanel as NSPanel] {
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.isMovable = false
            panel.isMovableByWindowBackground = false
            panel.hidesOnDeactivate = false
            panel.acceptsMouseMovedEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.animationBehavior = .none
            panel.isReleasedWhenClosed = false
        }
        notchPanel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        notchPanel.hasShadow = false
        let hosting = TopNotchHostingView(rootView: TopNotchView(model: relayModel, appearance: appearance))
        hosting.onPointerChanged = { [weak self] in self?.handlePointer(at: NSEvent.mouseLocation) }
        hosting.onClick = { [weak self] in self?.handleNotchClick(at: NSEvent.mouseLocation) }
        hosting.onRightClick = { [weak self] event in self?.showContextMenu(for: event) }
        hosting.canAcceptDrop = { [weak self] in self?.relayModel.isDraggingOut == false }
        hosting.onFileDropTargetChanged = { [weak self] targeted in
            guard let self else { return }
            let active = targeted && !self.relayModel.isDraggingOut
            self.isDraggingFiles = active
            self.relayModel.isDropTargeted = active
            self.cancelPendingTransitions()
            if active && !self.relayPresented {
                self.dragOpenedRelay = true
                self.showRelay()
            }
        }
        hosting.onFileDrop = { [weak self] urls in
            self?.relayModel.add(urls: urls)
            self?.finishIncomingDrop()
            self?.showRelay()
        }
        notchPanel.contentView = hosting

        relayPanel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        relayPanel.hasShadow = true
        let relay = RelayHostingView(rootView: FileRelayAppearanceView(
            preferences: panelController.preferences,
            model: relayModel,
            onContextMenuChanged: { [weak self] open in
                guard let self else { return }
                self.contextMenuOpen = open
                self.cancelPendingTransitions()
                if !open { self.handlePointer(at: NSEvent.mouseLocation) }
            }
        ))
        relay.onDropTarget = { [weak self] targeted in
            guard let self else { return }
            self.isDraggingFiles = targeted && !self.relayModel.isDraggingOut
            self.relayModel.isDropTargeted = targeted && !self.relayModel.isDraggingOut
        }
        relay.canAcceptDrop = { [weak self] in self?.relayModel.isDraggingOut == false }
        relay.onDrop = { [weak self] urls in
            self?.relayModel.add(urls: urls)
            self?.finishIncomingDrop()
        }
        relayPanel.contentView = relay
    }

    private func refreshPosition() {
        guard running, isEnabled else { return }
        // The built-in display is the stable home for the notch on a MacBook;
        // an external-only setup uses the primary display.
        let screen = NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(number.uint32Value) != 0
        } ?? NSScreen.screens.first
        guard let screen else { return }
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            appearance.hardwareWidth = max(0, right.minX - left.maxX)
        } else { appearance.hardwareWidth = 0 }
        notchPanel.setFrame(TopNotchGeometry.frame(on: screen, hasItems: !relayModel.items.isEmpty), display: true)
        if relayPresented { positionRelay(on: screen) }
    }

    private func installPointerMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseUp, .rightMouseUp, .leftMouseDown, .keyDown]
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handleEvent(event) }
        }
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            if event.type == .keyDown && event.keyCode == 53, self?.relayPresented == true {
                self?.handleEscape()
                return nil
            }
            MainActor.assumeIsolated { self?.handleEvent(event) }
            return event
        }
    }

    func handleEscape() { hideRelay() }

    func handleNotchClick(at point: NSPoint) {
        if isOverBadge(point) { showRelay() } else { openWorkspace() }
    }

    private func isOverBadge(_ point: NSPoint) -> Bool {
        !relayModel.items.isEmpty && point.x >= notchPanel.frame.maxX - 60 && notchPanel.frame.contains(point)
    }

    func handleFileDrag(at point: NSPoint, hasFiles: Bool) {
        guard running, isEnabled, !relayModel.isDraggingOut else { return }
        let zone = notchPanel.frame.insetBy(dx: -24, dy: -20)
        if hasFiles && zone.contains(point) {
            relayModel.isDropTargeted = true
            dragOpenedRelay = true
            if !relayPresented { showRelay() }
        } else if dragOpenedRelay && !relayPanel.frame.insetBy(dx: -6, dy: -6).contains(point) {
            relayModel.isDropTargeted = false
            dragOpenedRelay = false
            if !relayModel.isPinned && !relayModel.isDraggingOut { hideRelay() }
        }
    }

    private func finishIncomingDrop() {
        dragOpenedRelay = false
        isDraggingFiles = false
        relayModel.isDropTargeted = false
        idleDragChangeCount = NSPasteboard(name: .drag).changeCount
    }

    private func handleEvent(_ event: NSEvent) {
        let point = NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDragged, .leftMouseUp:
            let pasteboard = NSPasteboard(name: .drag)
            handlePointerEvent(type: event.type, at: point,
                               dragChangeCount: pasteboard.changeCount,
                               hasFileURL: event.type == .leftMouseDragged && pasteboard.availableType(from: [.fileURL]) != nil)
        case .leftMouseDown:
            handlePointerEvent(type: event.type, at: point, dragChangeCount: idleDragChangeCount, hasFileURL: false)
        default:
            handlePointer(at: point)
        }
    }

    func handlePointerEvent(type: NSEvent.EventType, at point: NSPoint, dragChangeCount: Int, hasFileURL: Bool) {
        if type == .leftMouseDragged {
            let incoming = !relayModel.isDraggingOut && dragChangeCount != idleDragChangeCount && hasFileURL
            handleFileDrag(at: point, hasFiles: incoming)
        } else if type == .leftMouseUp {
            dragOpenedRelay = false
            relayModel.isDropTargeted = false
            isDraggingFiles = false
            idleDragChangeCount = dragChangeCount
        } else if type == .leftMouseDown && relayPresented && !relayModel.isPinned && !relayPanel.frame.contains(point) && !notchPanel.frame.contains(point) {
            hideRelay()
        }
        handlePointer(at: point)
    }

    func handlePointer(at point: NSPoint) {
        lastPointerLocation = point
        guard running, isEnabled, !contextMenuOpen, !isDraggingFiles else { return }
        let overNotch = notchPanel.frame.contains(point)
        if !overNotch { requiresPointerExit = false }
        let overWorkspace = panelController.isVisible && (panelController.panel.frame.insetBy(dx: -6, dy: -6).contains(point)
            || (panelController.panel.attachedSheet?.frame.insetBy(dx: -6, dy: -6).contains(point) ?? false)
            || (NSApp.modalWindow?.frame.insetBy(dx: -6, dy: -6).contains(point) ?? false))
        let overRelay = relayPresented && relayPanel.frame.insetBy(dx: -6, dy: -6).contains(point)
        if overNotch || overWorkspace || overRelay {
            pendingClose?.cancel()
            pendingClose = nil
            if overNotch, !requiresPointerExit, !panelController.isVisible, !relayPresented,
               pendingOpen == nil, NSEvent.pressedMouseButtons == 0 {
                let work = DispatchWorkItem { [weak self] in
                    self?.pendingOpen = nil
                    guard let self else { return }
                    if self.isOverBadge(self.lastPointerLocation) { self.showRelay() } else { self.openWorkspace() }
                }
                pendingOpen = work
                DispatchQueue.main.asyncAfter(deadline: .now() + FlowMotion.notchHoverDelay, execute: work)
            }
        } else {
            pendingOpen?.cancel()
            pendingOpen = nil
            guard (panelController.isVisible || relayPresented), pendingClose == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingClose = nil
                if self.relayPresented {
                    if NSEvent.pressedMouseButtons == 0 && !self.relayModel.isPinned && !self.relayModel.isDraggingOut { self.hideRelay() }
                } else {
                    self.panelController.hideAfterPointerExit()
                }
            }
            pendingClose = work
            DispatchQueue.main.asyncAfter(deadline: .now() + FlowMotion.notchDismissDelay, execute: work)
        }
    }

    private func cancelPendingTransitions() {
        pendingOpen?.cancel()
        pendingClose?.cancel()
        pendingOpen = nil
        pendingClose = nil
    }

    @objc private func openWorkspace() {
        cancelPendingTransitions()
        hideRelay(animated: false)
        guard !panelController.isVisible else { return }
        panelController.showExpanded(on: notchPanel.screen)
    }

    @objc func showRelay() {
        cancelPendingTransitions()
        if panelController.isVisible {
            panelController.hide()
            guard !panelController.isVisible else { return }
        }
        guard let screen = notchPanel.screen ?? NSScreen.screens.first else { return }
        positionRelay(on: screen)
        relayGeneration += 1
        let wasVisible = relayPresented
        relayPresented = true
        relayPanel.ignoresMouseEvents = false
        if !wasVisible { relayPanel.alphaValue = 0 }
        relayPanel.makeKeyAndOrderFront(nil)
        relayPanel.orderFrontRegardless()
        relayPanel.invalidateShadow()
        appearance.expanded = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : FlowMotion.windowIn
            relayPanel.animator().alphaValue = 1
        }
    }

    private func positionRelay(on screen: NSScreen) {
        let frame = screen.frame
        let top = TopNotchGeometry.workspaceTop(on: screen)
        let notchWidth = TopNotchGeometry.frame(on: screen, hasItems: !relayModel.items.isEmpty).width
        let width = max(1, min(max(300, notchWidth + 76), frame.width - 24))
        let height = min(96, max(1, top - frame.minY))
        relayPanel.setFrame(NSRect(x: frame.midX - width / 2,
                                  y: top - height,
                                  width: width, height: height), display: true)
        relayPanel.invalidateShadow()
    }

    private func hideRelay(animated: Bool = true) {
        guard relayPresented || relayPanel.isVisible else { return }
        relayGeneration += 1
        let generation = relayGeneration
        relayPresented = false
        relayPanel.ignoresMouseEvents = true
        appearance.expanded = panelController.isVisible
        NSAnimationContext.runAnimationGroup { context in
            context.duration = !animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : FlowMotion.windowOut
            relayPanel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.relayGeneration == generation, !self.relayPresented else { return }
                self.relayPanel.orderOut(nil)
                self.relayPanel.alphaValue = 1
                self.relayPanel.ignoresMouseEvents = false
            }
        }
    }

    private func showContextMenu(for event: NSEvent) {
        contextMenuOpen = true
        cancelPendingTransitions()
        defer {
            contextMenuOpen = false
            handlePointer(at: NSEvent.mouseLocation)
        }
        let menu = NSMenu()
        for (title, action) in [("打开 Jaimo Flow 工具站", #selector(openWorkspace)),
                                ("打开文件中转站", #selector(showRelay)),
                                ("偏好设置…", #selector(openSettings))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if !relayModel.items.isEmpty {
            let clearItem = NSMenuItem(title: "清空文件中转", action: #selector(clearRelayItems), keyEquivalent: "")
            clearItem.target = self
            menu.addItem(clearItem)
        }
        menu.addItem(.separator())
        let hideItem = NSMenuItem(title: "隐藏顶部刘海", action: #selector(disableNotch), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Jaimo Flow", action: #selector(quitApplication), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        NSMenu.popUpContextMenu(menu, with: event, for: notchPanel.contentView ?? NSView())
    }

    @objc private func openSettings() {
        openWorkspace()
        panelController.show(openSettings: true)
    }
    @objc private func clearRelayItems() { relayModel.clearAll() }
    @objc private func disableNotch() { isEnabled = false }
    @objc private func quitApplication() { NSApp.terminate(nil) }
}

private struct TopNotchShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = min(10, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct TopNotchView: View {
    @ObservedObject var model: FileRelayModel
    @ObservedObject var appearance: TopNotchAppearance

    var body: some View {
        ZStack {
            if appearance.hardwareWidth > 0 {
                HStack(spacing: 0) {
                    Image(systemName: "waveform")
                        .frame(width: model.items.isEmpty ? 32 : 60, height: 24)
                    Spacer(minLength: appearance.hardwareWidth)
                    if model.items.isEmpty {
                        Image(systemName: appearance.expanded ? "chevron.up" : "chevron.down")
                            .frame(width: 32, height: 24)
                    } else { badge }
                }
            } else if model.items.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "waveform")
                    Text("Jaimo Flow")
                    Image(systemName: appearance.expanded ? "chevron.up" : "chevron.down")
                }.frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 0) {
                    HStack(spacing: 5) {
                        Image(systemName: "waveform")
                        Text("Jaimo Flow")
                        Image(systemName: appearance.expanded ? "chevron.up" : "chevron.down")
                    }
                    .frame(maxWidth: .infinity)
                    badge
                }
            }
        }
        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TopNotchShape().fill(.black))
        .contentShape(TopNotchShape())
    }

    private var badge: some View {
        HStack(spacing: 4) {
            Image(systemName: "tray.fill")
            Text(model.items.count > 99 ? "99+" : "\(model.items.count)").monospacedDigit()
        }.frame(width: 52, height: 22)
         .background(Color.white.opacity(0.16), in: Capsule())
         .frame(width: 60, height: 24)
         .accessibilityLabel("打开文件小兜，\(model.items.count) 项")
    }
}

private final class TopNotchHostingView<Content: View>: NSHostingView<Content> {
    var onClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var onPointerChanged: (() -> Void)?
    var onFileDropTargetChanged: ((Bool) -> Void)?
    var onFileDrop: (([URL]) -> Void)?
    var canAcceptDrop: (() -> Bool)?
    private var pointerTrackingArea: NSTrackingArea?

    required init(rootView: Content) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
        setAccessibilityRole(.button)
        setAccessibilityLabel("Jaimo Flow 顶部刘海")
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        pointerTrackingArea = area
    }
    override func hitTest(_ point: NSPoint) -> NSView? { self }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { onPointerChanged?() }
    override func mouseExited(with event: NSEvent) { onPointerChanged?() }
    override func mouseUp(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canAcceptDrop?() != false, !fileURLs(from: sender).isEmpty else { return [] }
        onFileDropTargetChanged?(true)
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { onFileDropTargetChanged?(false); onPointerChanged?() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { canAcceptDrop?() != false && !fileURLs(from: sender).isEmpty }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        onFileDropTargetChanged?(false)
        guard !urls.isEmpty else { return false }
        onFileDrop?(urls)
        return true
    }
    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}

private final class RelayHostingView<Content: View>: NSHostingView<Content> {
    var onDropTarget: ((Bool) -> Void)?
    var onDrop: (([URL]) -> Void)?
    var canAcceptDrop: (() -> Bool)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    required init(rootView: Content) { super.init(rootView: rootView); registerForDraggedTypes([.fileURL]) }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    private func urls(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canAcceptDrop?() != false, !urls(sender).isEmpty else { return [] }; onDropTarget?(true); return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { onDropTarget?(false) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { canAcceptDrop?() != false && !urls(sender).isEmpty }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let values = urls(sender); onDropTarget?(false); guard !values.isEmpty else { return false }; onDrop?(values); return true
    }
}
