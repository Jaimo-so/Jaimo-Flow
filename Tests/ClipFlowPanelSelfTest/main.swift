import AppKit
@testable import ClipFlow

enum PanelTestError: Error {
    case failed(String)
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw PanelTestError.failed(message) }
}

@MainActor
func requireCentered(_ panel: NSPanel, _ context: String) throws {
    guard let screen = panel.screen else { throw PanelTestError.failed("找不到窗口所在屏幕") }
    try require(abs(panel.frame.midX - screen.visibleFrame.midX) <= 1, "\(context)：窗口没有水平居中")
    try require(abs(panel.frame.maxY - (screen.visibleFrame.maxY - 8)) <= 1, "\(context)：窗口没有保持靠上位置")
}

@MainActor
func resizeWorkspace(_ controller: PanelController, to size: NSSize) throws {
    let initialFrame = controller.panel.frame
    // Model successive frames supplied by AppKit during a held edge drag.
    // The delegate must never move that edge before the gesture finishes.
    let initialSize = controller.panel.frame.size
    for step in 1...5 {
        let progress = CGFloat(step) / 5
        let intermediateSize = NSSize(
            width: initialSize.width + (size.width - initialSize.width) * progress,
            height: initialSize.height + (size.height - initialSize.height) * progress
        )
        // A bottom/right edge drag keeps the top-left corner fixed, including
        // when a top-aligned window grows taller.
        let proposedOrigin = NSPoint(x: initialFrame.minX, y: initialFrame.maxY - intermediateSize.height)
        controller.panel.setFrame(NSRect(origin: proposedOrigin, size: intermediateSize), display: true)
        try require(controller.panel.frame.origin == proposedOrigin, "拖动过程中窗口被强制移位，缩放边缘会逃离鼠标")
    }
    controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: controller.panel))
    try requireCentered(controller.panel, "松开缩放边缘后")
}

try MainActor.assumeIsolated {
    _ = NSApplication.shared
    let suite = "ClipFlowPanelSelfTest.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = PreferencesStore(defaults: defaults)
    try require(preferences.workspaceSize == NSSize(width: 948, height: 680), "首次启动的默认尺寸不正确")
    let controller = PanelController(model: AppModel(preferences: preferences), preferences: preferences)
    defer { controller.panel.orderOut(nil) }

    controller.showExpanded()
    try requireCentered(controller.panel, "首次展开")
    try require(controller.panel.minSize.width < controller.panel.maxSize.width, "窗口宽度仍被锁定")
    try require(controller.panel.minSize.height < controller.panel.maxSize.height, "窗口高度仍被锁定")
    let resized = NSSize(width: 720, height: 520)
    try resizeWorkspace(controller, to: resized)
    try require(preferences.workspaceSize == resized, "调整窗口后未保存尺寸")
    try requireCentered(controller.panel, "缩小后")

    try resizeWorkspace(controller, to: NSSize(width: 820, height: 600))
    try requireCentered(controller.panel, "放大后")
    try resizeWorkspace(controller, to: resized)
    controller.panel.setFrameOrigin(NSPoint(x: controller.panel.frame.minX + 30, y: controller.panel.frame.minY - 20))
    controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: controller.panel))
    try requireCentered(controller.panel, "拖动结束后")

    controller.hide()
    controller.showExpanded()
    try require(controller.panel.frame.size == resized, "隐藏后重新打开未恢复尺寸")
    try requireCentered(controller.panel, "隐藏重开后")

    let restored = PreferencesStore(defaults: UserDefaults(suiteName: suite)!)
    try require(restored.workspaceSize == resized, "重新读取偏好设置丢失尺寸")
    let reopened = PanelController(model: AppModel(preferences: restored), preferences: restored)
    defer { reopened.panel.orderOut(nil) }
    reopened.showExpanded()
    try require(reopened.panel.frame.size == resized, "新建窗口未恢复保存的尺寸")
    try requireCentered(reopened.panel, "新窗口恢复后")

    let oversized = NSSize(width: 8_000, height: 8_000)
    restored.workspaceSize = oversized
    reopened.hide()
    reopened.showExpanded()
    try require(reopened.panel.frame.width < oversized.width, "窗口没有适配屏幕宽度")
    try require(reopened.panel.frame.height < oversized.height, "窗口没有适配屏幕高度")
    try requireCentered(reopened.panel, "适配屏幕后")
    try require(restored.workspaceSize == oversized, "适配屏幕覆盖了用户保存的尺寸")
    try require(PreferencesStore(defaults: defaults).workspaceSize == oversized, "适配屏幕污染了持久化尺寸")

    print("PASS: 连续缩放时不移位，松开后水平居中并靠上；隐藏重开、新窗口恢复、尺寸保存与屏幕适配正确")
}
