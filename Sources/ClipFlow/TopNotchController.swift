import AppKit
import QuartzCore
import SwiftUI

final class TopNotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FileRelayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum TopNotchGeometry {
    static func frame(screen: NSRect, visible: NSRect, safeAreaTop: CGFloat = 0, hardwareWidth: CGFloat = 0) -> NSRect {
        let height = max(24, safeAreaTop, screen.maxY - visible.maxY)
        let width = min(max(164, hardwareWidth + 16), screen.width)
        return NSRect(x: screen.midX - width / 2, y: screen.maxY - height, width: width, height: height)
    }

    static func frame(on screen: NSScreen) -> NSRect {
        let hardwareWidth: CGFloat
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            hardwareWidth = max(0, right.minX - left.maxX)
        } else {
            hardwareWidth = 0
        }
        return frame(screen: screen.frame, visible: screen.visibleFrame,
                     safeAreaTop: screen.safeAreaInsets.top, hardwareWidth: hardwareWidth)
    }

    static func workspaceTop(on screen: NSScreen) -> CGFloat {
        min(screen.visibleFrame.maxY, frame(on: screen).minY)
    }
}

@MainActor
private final class TopNotchAppearance: ObservableObject {
    @Published var expanded = false
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
    private var contextMenuOpen = false
    private var running = false

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
        notchPanel = TopNotchPanel(contentRect: NSRect(x: 0, y: 0, width: 164, height: 24),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        relayPanel = FileRelayPanel(contentRect: NSRect(x: 0, y: 0, width: 370, height: 430),
                                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                                   backing: .buffered, defer: false)
        super.init()
        configurePanels()
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
        hosting.onClick = { [weak self] in self?.openWorkspace() }
        hosting.onRightClick = { [weak self] event in self?.showContextMenu(for: event) }
        hosting.onFileDropTargetChanged = { [weak self] targeted in
            guard let self else { return }
            self.isDraggingFiles = targeted
            self.relayModel.isDropTargeted = targeted
            self.cancelPendingTransitions()
        }
        hosting.onFileDrop = { [weak self] urls in
            self?.relayModel.add(urls: urls)
            self?.showRelay()
        }
        notchPanel.contentView = hosting

        relayPanel.level = .floating
        relayPanel.hasShadow = true
        let relay = NSHostingView(rootView: FileRelayPanelView(model: relayModel, onOpenWorkspace: { [weak self] in
            self?.openWorkspace()
        }))
        relay.wantsLayer = true
        relay.layer?.cornerRadius = 18
        relay.layer?.cornerCurve = .continuous
        relay.layer?.masksToBounds = true
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
        notchPanel.setFrame(TopNotchGeometry.frame(on: screen), display: true)
        if relayPresented { positionRelay(on: screen) }
    }

    private func installPointerMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseUp, .rightMouseUp]
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.handlePointer(at: NSEvent.mouseLocation) }
        }
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handlePointer(at: NSEvent.mouseLocation) }
            return event
        }
    }

    func handlePointer(at point: NSPoint) {
        guard running, isEnabled, !contextMenuOpen, !isDraggingFiles else { return }
        let overNotch = notchPanel.frame.contains(point)
        if !overNotch { requiresPointerExit = false }
        let overWorkspace = panelController.isVisible && panelController.panel.frame.insetBy(dx: -6, dy: -6).contains(point)
        let overRelay = relayPresented && relayPanel.frame.insetBy(dx: -6, dy: -6).contains(point)
        if overNotch || overWorkspace || overRelay {
            pendingClose?.cancel()
            pendingClose = nil
            if overNotch, !requiresPointerExit, !panelController.isVisible, !relayPresented,
               pendingOpen == nil, NSEvent.pressedMouseButtons == 0 {
                let work = DispatchWorkItem { [weak self] in
                    self?.pendingOpen = nil
                    self?.openWorkspace()
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
                    if NSEvent.pressedMouseButtons == 0 { self.hideRelay() }
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
        appearance.expanded = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : FlowMotion.windowIn
            relayPanel.animator().alphaValue = 1
        }
    }

    private func positionRelay(on screen: NSScreen) {
        let visible = screen.visibleFrame
        let size = NSSize(width: min(370, visible.width - 24), height: min(430, visible.height - 16))
        relayPanel.setFrame(NSRect(x: visible.midX - size.width / 2,
                                  y: TopNotchGeometry.workspaceTop(on: screen) - size.height,
                                  width: size.width, height: size.height), display: true)
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
        HStack(spacing: 8) {
            Image(systemName: model.isDropTargeted ? "tray.and.arrow.down.fill" : "waveform")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(red: 0.72, green: 0.89, blue: 0.68))
            Text(model.isDropTargeted ? "放入文件" : "Jaimo Flow")
                .font(.system(size: 10.5, weight: .medium))
            if !model.items.isEmpty {
                Text(model.items.count > 99 ? "99+" : "\(model.items.count)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
                    .monospacedDigit()
            }
            Image(systemName: appearance.expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
        }
        .foregroundStyle(.white.opacity(0.92))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TopNotchShape().fill(.black))
        .contentShape(TopNotchShape())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Jaimo Flow 顶部刘海，移入展开工具站，文件中转站有 \(model.items.count) 项")
    }
}

private final class TopNotchHostingView<Content: View>: NSHostingView<Content> {
    var onClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var onPointerChanged: (() -> Void)?
    var onFileDropTargetChanged: ((Bool) -> Void)?
    var onFileDrop: (([URL]) -> Void)?
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
        guard !fileURLs(from: sender).isEmpty else { return [] }
        onFileDropTargetChanged?(true)
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { onFileDropTargetChanged?(false); onPointerChanged?() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !fileURLs(from: sender).isEmpty }
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
