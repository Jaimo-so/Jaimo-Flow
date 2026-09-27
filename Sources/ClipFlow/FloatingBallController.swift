import AppKit
import SwiftUI

final class FloatingBallPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FileRelayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatingBallController: NSObject {
    private enum Key {
        static let isEnabled = "floatingBall.isEnabled"
        static let screenID = "floatingBall.screenID"
        static let edge = "floatingBall.edge"
        static let yFraction = "floatingBall.yFraction"
    }

    private let ballSize = NSSize(width: 62, height: 62)
    private let relaySize = NSSize(width: 370, height: 430)
    private let defaults: UserDefaults
    private let panelController: PanelController
    let relayModel: FileRelayModel

    private let ballPanel: FloatingBallPanel
    private let relayPanel: FileRelayPanel
    private var outsideClickMonitor: Any?

    var isEnabled: Bool {
        get { defaults.object(forKey: Key.isEnabled) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.isEnabled)
            newValue ? showBall() : hideBall()
        }
    }

    var isBallVisible: Bool { ballPanel.isVisible }

    init(
        panelController: PanelController,
        relayModel: FileRelayModel? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.panelController = panelController
        self.relayModel = relayModel ?? FileRelayModel()
        self.defaults = defaults
        ballPanel = FloatingBallPanel(
            contentRect: NSRect(origin: .zero, size: ballSize),
            styleMask: [.borderless, .nonactivatingPanel, .hudWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        relayPanel = FileRelayPanel(
            contentRect: NSRect(origin: .zero, size: relaySize),
            styleMask: [.borderless, .nonactivatingPanel, .hudWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        configureBallPanel()
        configureRelayPanel()
        installOutsideClickMonitor()
    }

    deinit {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
    }

    func showIfEnabled() {
        if isEnabled { showBall() }
    }

    func showBall() {
        guard isEnabled else { return }
        placeBallAtSavedPosition()
        ballPanel.orderFrontRegardless()
    }

    func hideBall() {
        relayPanel.orderOut(nil)
        ballPanel.orderOut(nil)
    }

    func toggleBallVisibility() {
        isEnabled.toggle()
    }

    func prepareForWorkspacePresentation() {
        relayPanel.orderOut(nil)
        ballPanel.orderOut(nil)
    }

    func restoreAfterWorkspaceHides() {
        showIfEnabled()
    }

    private func configureBallPanel() {
        ballPanel.level = .floating
        ballPanel.isOpaque = false
        ballPanel.backgroundColor = .clear
        ballPanel.hasShadow = true
        // 悬浮球使用 FloatingBallHostingView 的显式拖动实现，
        // 避免 AppKit 背景拖动与文件接收手势重复处理。
        ballPanel.isMovable = false
        ballPanel.isMovableByWindowBackground = false
        ballPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ballPanel.animationBehavior = .none
        ballPanel.isReleasedWhenClosed = false

        let root = FloatingBallView(model: relayModel)
        let hosting = FloatingBallHostingView(rootView: root)
        hosting.onClick = { [weak self] in self?.toggleRelayPanel() }
        hosting.onRightClick = { [weak self] event in self?.showContextMenu(for: event) }
        hosting.onFileDropTargetChanged = { [weak relayModel] targeted in
            relayModel?.isDropTargeted = targeted
        }
        hosting.onFileDrop = { [weak self] urls in
            guard let self else { return }
            self.relayModel.add(urls: urls)
            self.showRelayPanel()
        }
        hosting.onMoveEnded = { [weak self] in self?.snapBallToNearestEdge() }
        ballPanel.contentView = hosting
    }

    private func configureRelayPanel() {
        relayPanel.level = .floating
        relayPanel.isOpaque = false
        relayPanel.backgroundColor = .clear
        relayPanel.hasShadow = true
        // 文件条目的 SwiftUI onDrag 必须只启动文件拖出。
        // 如果允许窗口或背景移动，同一次拖动会让整个中转面板跟随鼠标。
        relayPanel.isMovable = false
        relayPanel.isMovableByWindowBackground = false
        relayPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        relayPanel.animationBehavior = .none
        relayPanel.isReleasedWhenClosed = false

        let root = FileRelayPanelView(
            model: relayModel,
            onOpenWorkspace: { [weak self] in
                self?.relayPanel.orderOut(nil)
                self?.panelController.show()
            }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 18
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        relayPanel.contentView = hosting
    }

    private func toggleRelayPanel() {
        relayPanel.isVisible ? relayPanel.orderOut(nil) : showRelayPanel()
    }

    private func showRelayPanel() {
        positionRelayPanel()
        relayPanel.makeKeyAndOrderFront(nil)
        relayPanel.orderFrontRegardless()
    }

    private func positionRelayPanel() {
        guard let screen = screenContainingBall() else { return }
        let visible = screen.visibleFrame
        let ball = ballPanel.frame
        let space: CGFloat = 10
        let preferredX = ball.midX < visible.midX
            ? ball.maxX + space
            : ball.minX - relaySize.width - space
        let x = min(max(preferredX, visible.minX + 8), visible.maxX - relaySize.width - 8)
        let y = min(
            max(ball.midY - relaySize.height / 2, visible.minY + 8),
            visible.maxY - relaySize.height - 8
        )
        relayPanel.setFrame(NSRect(x: x, y: y, width: relaySize.width, height: relaySize.height), display: true)
    }

    private func showContextMenu(for event: NSEvent) {
        let menu = NSMenu()
        let workspace = NSMenuItem(title: "打开 Jaimo Flow 工具站", action: #selector(openWorkspace), keyEquivalent: "")
        workspace.target = self
        menu.addItem(workspace)
        let relay = NSMenuItem(title: "打开文件中转站", action: #selector(openRelay), keyEquivalent: "")
        relay.target = self
        menu.addItem(relay)
        let settings = NSMenuItem(title: "偏好设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let hide = NSMenuItem(title: "隐藏悬浮球", action: #selector(disableBall), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Jaimo Flow", action: #selector(quitApplication), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        NSMenu.popUpContextMenu(menu, with: event, for: ballPanel.contentView ?? NSView())
    }

    @objc private func openWorkspace() {
        relayPanel.orderOut(nil)
        panelController.show()
    }

    @objc private func openRelay() {
        showRelayPanel()
    }

    @objc private func openSettings() {
        relayPanel.orderOut(nil)
        panelController.show(openSettings: true)
    }

    @objc private func disableBall() {
        isEnabled = false
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }

    private func installOutsideClickMonitor() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.relayPanel.isVisible else { return }
                let location = NSEvent.mouseLocation
                if !self.relayPanel.frame.contains(location), !self.ballPanel.frame.contains(location) {
                    self.relayPanel.orderOut(nil)
                }
            }
        }
    }

    private func placeBallAtSavedPosition() {
        let screen = savedScreen() ?? screenAtMouse() ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let edge = defaults.string(forKey: Key.edge) ?? "right"
        let yFraction = min(max(defaults.double(forKey: Key.yFraction), 0), 1)
        let resolvedFraction = defaults.object(forKey: Key.yFraction) == nil ? 0.62 : yFraction
        let x = edge == "left" ? visible.minX + 10 : visible.maxX - ballSize.width - 10
        let y = visible.minY + 10 + resolvedFraction * max(0, visible.height - ballSize.height - 20)
        ballPanel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: ballSize), display: true)
    }

    private func snapBallToNearestEdge() {
        guard let screen = screenContainingBall() else { return }
        let visible = screen.visibleFrame
        let useLeft = ballPanel.frame.midX < visible.midX
        let x = useLeft ? visible.minX + 10 : visible.maxX - ballSize.width - 10
        let y = min(max(ballPanel.frame.minY, visible.minY + 10), visible.maxY - ballSize.height - 10)
        ballPanel.setFrameOrigin(NSPoint(x: x, y: y))

        let availableHeight = max(1, visible.height - ballSize.height - 20)
        defaults.set(screenID(screen), forKey: Key.screenID)
        defaults.set(useLeft ? "left" : "right", forKey: Key.edge)
        defaults.set((y - visible.minY - 10) / availableHeight, forKey: Key.yFraction)
        if relayPanel.isVisible { positionRelayPanel() }
    }

    private func screenContainingBall() -> NSScreen? {
        let center = NSPoint(x: ballPanel.frame.midX, y: ballPanel.frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
            ?? screenAtMouse()
            ?? NSScreen.main
    }

    private func screenAtMouse() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) }
    }

    private func savedScreen() -> NSScreen? {
        guard let savedID = defaults.string(forKey: Key.screenID) else { return nil }
        return NSScreen.screens.first { screenID($0) == savedID }
    }

    private func screenID(_ screen: NSScreen) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.stringValue ?? screen.localizedName
    }
}

private struct FloatingBallView: View {
    @ObservedObject var model: FileRelayModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        ZStack {
            Circle()
                .fill(theme.glass.opacity(0.98))
            Circle()
                .stroke(
                    model.isDropTargeted ? theme.accent : theme.hairline,
                    lineWidth: model.isDropTargeted ? 2.5 : 0.8
                )
            VStack(spacing: 1) {
                Image(systemName: model.isDropTargeted ? "tray.and.arrow.down.fill" : "arrow.left.arrow.right.circle.fill")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(model.isDropTargeted ? theme.accent : theme.foreground)
                Text(model.isDropTargeted ? "放入" : "J")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(theme.muted)
            }
            if !model.items.isEmpty {
                Text(model.items.count > 99 ? "99+" : "\(model.items.count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.82))
                    .padding(.horizontal, 5)
                    .frame(minWidth: 19, minHeight: 19)
                    .background(theme.accent)
                    .clipShape(Capsule())
                    .offset(x: 22, y: -22)
                    .monospacedDigit()
            }
        }
        .padding(3)
        .frame(width: 62, height: 62)
        .contentShape(Circle())
        .scaleEffect(model.isDropTargeted && !reduceMotion ? 1.05 : 1)
        .animation(reduceMotion ? nil : FlowMotion.release, value: model.isDropTargeted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Jaimo Flow 悬浮球，文件中转站有 \(model.items.count) 项")
    }
}

private final class FloatingBallHostingView<Content: View>: NSHostingView<Content> {
    var onClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var onFileDropTargetChanged: ((Bool) -> Void)?
    var onFileDrop: (([URL]) -> Void)?
    var onMoveEnded: (() -> Void)?

    private var initialMouseLocation: NSPoint?
    private var initialWindowOrigin: NSPoint?
    private var moved = false

    required init(rootView: Content) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? { self }

    override func mouseDown(with event: NSEvent) {
        initialMouseLocation = NSEvent.mouseLocation
        initialWindowOrigin = window?.frame.origin
        moved = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let initialMouseLocation, let initialWindowOrigin else { return }
        let current = NSEvent.mouseLocation
        let deltaX = current.x - initialMouseLocation.x
        let deltaY = current.y - initialMouseLocation.y
        if abs(deltaX) + abs(deltaY) > 3 { moved = true }
        window.setFrameOrigin(NSPoint(x: initialWindowOrigin.x + deltaX, y: initialWindowOrigin.y + deltaY))
    }

    override func mouseUp(with event: NSEvent) {
        if moved { onMoveEnded?() } else { onClick?() }
        initialMouseLocation = nil
        initialWindowOrigin = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(from: sender).isEmpty else { return [] }
        onFileDropTargetChanged?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onFileDropTargetChanged?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !fileURLs(from: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        onFileDropTargetChanged?(false)
        guard !urls.isEmpty else { return false }
        onFileDrop?(urls)
        return true
    }

    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [URL] ?? []
    }
}
