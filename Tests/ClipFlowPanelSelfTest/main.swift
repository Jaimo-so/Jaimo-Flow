import AppKit
import SwiftUI
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
    try require(abs(panel.frame.maxY - TopNotchGeometry.workspaceTop(on: screen)) <= 1, "\(context)：窗口没有保持靠上位置")
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

@MainActor
func findNoteEditor(in view: NSView, identifier: String) -> NSTextView? {
    if let editor = view as? NSTextView, editor.identifier?.rawValue == identifier { return editor }
    for child in view.subviews {
        if let editor = findNoteEditor(in: child, identifier: identifier) { return editor }
    }
    return nil
}

@MainActor
func finishWindowAnimation(_ panel: NSPanel) {
    // AppKit's animation completion needs its run loop, not just an async sleep.
    let deadline = Date().addingTimeInterval(1)
    while panel.isVisible && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}

@MainActor
func testTopNotch(controller: PanelController, model: AppModel, defaults: UserDefaults, directory: URL) async throws {
    let screenRect = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let air = TopNotchGeometry.frame(screen: screenRect, visible: NSRect(x: 0, y: 60, width: 1440, height: 815))
    try require(air.midX == 720 && air.maxY == 900 && air.height == 25, "无刘海屏幕入口未贴住菜单栏中央")
    let hiddenMenu = TopNotchGeometry.frame(screen: screenRect, visible: screenRect)
    try require(hiddenMenu.height == 24 && hiddenMenu.midX == 720, "自动隐藏菜单栏时入口消失")
    let hardware = TopNotchGeometry.frame(screen: screenRect, visible: screenRect, safeAreaTop: 38, hardwareWidth: 200)
    try require(hardware.height == 38 && hardware.width >= 200, "物理刘海屏幕未适配安全区")
    let offset = TopNotchGeometry.frame(screen: NSRect(x: -1440, y: 200, width: 1440, height: 900),
                                       visible: NSRect(x: -1440, y: 200, width: 1440, height: 875))
    try require(offset.midX == -720 && offset.maxY == 1100, "多屏坐标导致入口偏移")

    controller.hide()
    finishWindowAnimation(controller.panel)
    let notch = TopNotchController(panelController: controller, relayModel: FileRelayModel(rootURL: directory.appendingPathComponent("Relay")),
                                   defaults: defaults, monitorsPointer: false)
    controller.onVisibilityChanged = { [weak notch] in notch?.workspaceVisibilityChanged($0) }
    defer {
        controller.onVisibilityChanged = nil
        notch.hide()
        controller.hide()
        finishWindowAnimation(controller.panel)
    }
    notch.showIfEnabled()
    try require(notch.notchPanel.isVisible, "顶部入口未显示")
    let inside = NSPoint(x: notch.notchPanel.frame.midX, y: notch.notchPanel.frame.midY)
    let outside = NSPoint(x: notch.notchPanel.frame.minX - 2000, y: notch.notchPanel.frame.minY - 2000)
    notch.handlePointer(at: inside)
    notch.handlePointer(at: outside)
    try await Task.sleep(nanoseconds: 220_000_000)
    try require(!controller.isVisible, "鼠标快速划过入口仍弹出窗口")

    notch.handlePointer(at: inside)
    try await Task.sleep(nanoseconds: 220_000_000)
    try require(controller.isVisible, "悬停入口未展开工具站")
    try requireCentered(controller.panel, "悬停展开后")
    notch.handlePointer(at: NSPoint(x: controller.panel.frame.midX, y: controller.panel.frame.midY))
    try await Task.sleep(nanoseconds: 400_000_000)
    try require(controller.isVisible, "从刘海移入内容区误收起")

    notch.handlePointer(at: outside)
    try await Task.sleep(nanoseconds: 100_000_000)
    notch.handlePointer(at: inside)
    try await Task.sleep(nanoseconds: 400_000_000)
    try require(controller.isVisible, "移出后立即返回仍被旧任务关闭")

    model.settingsOpen = true
    notch.handlePointer(at: outside)
    try await Task.sleep(nanoseconds: 400_000_000)
    try require(controller.isVisible, "设置浮层打开时移出误关闭")
    model.settingsOpen = false
    notch.handlePointer(at: outside)
    try await Task.sleep(nanoseconds: 400_000_000)
    try require(!controller.isVisible, "移出内容区后未收起")
    try await Task.sleep(nanoseconds: 300_000_000)
    finishWindowAnimation(controller.panel)
    try require(!controller.panel.isVisible, "收起动画结束后窗口仍可见")

    // Reverse a close while its animation is running. The stale completion
    // must never order out the newly opened window or overwrite its size.
    notch.handlePointer(at: inside)
    try await Task.sleep(nanoseconds: 220_000_000)
    let sizeBefore = controller.panel.frame.size
    controller.hide()
    controller.showExpanded()
    try await Task.sleep(nanoseconds: 450_000_000)
    try require(controller.isVisible && controller.panel.isVisible && !controller.panel.ignoresMouseEvents,
                "快速收起重开被旧动画关闭或丢失输入")
    try require(controller.panel.frame.size == sizeBefore, "展开动画改变了工作区尺寸")

    notch.showRelay()
    try await Task.sleep(nanoseconds: 300_000_000)
    try require(notch.relayPanel.isVisible && !controller.isVisible, "文件中转面板与工具站状态冲突")
    notch.handlePointer(at: NSPoint(x: notch.relayPanel.frame.midX, y: notch.relayPanel.frame.midY))
    try await Task.sleep(nanoseconds: 400_000_000)
    try require(notch.relayPanel.isVisible, "文件中转面板内操作误收起")
    notch.handlePointer(at: outside)
    try await Task.sleep(nanoseconds: 600_000_000)
    try require(!notch.relayPanel.isVisible, "移出中转面板后未收起")

    notch.handlePointer(at: inside)
    notch.isEnabled = false
    try await Task.sleep(nanoseconds: 250_000_000)
    try require(!notch.notchPanel.isVisible && !controller.isVisible, "隐藏入口后延迟悬停仍打开工具站")
    notch.isEnabled = true
    try require(notch.notchPanel.isVisible, "隐藏后无法恢复入口")
}

@MainActor
func runTests() async throws {
    _ = NSApplication.shared
    let suite = "ClipFlowPanelSelfTest.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = PreferencesStore(defaults: defaults)
    try require(preferences.workspaceSize == NSSize(width: 849, height: 575), "首次启动的默认尺寸不正确")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClipFlowPanelNotes-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let memoURL = directory.appendingPathComponent("Memos/memos.json")
    let home = HomeDashboardModel(defaults: defaults, memoLibrary: MemoLibraryModel(fileURL: memoURL))
    let appModel = AppModel(preferences: preferences)
    let controller = PanelController(model: appModel, preferences: preferences, homeModel: home)
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

    home.quickNote = "收起窗口时保存便签\n最后追加的内容"
    let memoID = home.memoLibrary.createMemo()
    home.memoLibrary.updateBody("收起窗口时保存备忘录\n最后追加的内容")
    try require(!FileManager.default.fileExists(atPath: memoURL.path), "备忘录在窗口关闭前写入")
    home.memoLibraryOpen = true
    controller.handleOutsideClick()
    finishWindowAnimation(controller.panel)
    try require(!controller.panel.isVisible, "备忘录打开时点击软件外部没有收起窗口：接受输入=\(!controller.panel.ignoresMouseEvents)，透明度=\(controller.panel.alphaValue)，设置=\(appModel.settingsOpen)，提示词编辑=\(appModel.promptEditorOpen)，复盘=\(home.dailyReviewHistoryOpen)")
    try require(home.memoLibraryOpen && home.memoLibrary.selectedID == memoID, "收起窗口重置了备忘录界面或选中记录")
    try require(defaults.string(forKey: "home.quickNote") == home.quickNote, "收起窗口没有保存便签")
    try require(MemoLibraryModel(fileURL: memoURL).selectedItem?.body == home.memoLibrary.selectedItem?.body, "收起窗口没有保存备忘录")
    controller.showExpanded()
    try require(home.memoLibraryOpen && home.memoLibrary.selectedID == memoID, "重新打开未保留收起前的备忘录界面")
    try require(controller.panel.frame.size == resized, "隐藏后重新打开未恢复尺寸")
    try requireCentered(controller.panel, "隐藏重开后")
    home.closeMemoLibrary()

    controller.showExpanded(destination: .prompts)
    appModel.promptEditorOpen = true
    appModel.promptDraftTitle = "未保存的标题"
    appModel.promptDraftBody = "未保存的提示词正文"
    controller.handleOutsideClick()
    finishWindowAnimation(controller.panel)
    try require(!controller.panel.isVisible, "提示词编辑时点击软件外部没有收起窗口")
    controller.showExpanded(destination: .prompts)
    try require(appModel.promptEditorOpen, "重新打开后提示词编辑界面未保留")
    try require(appModel.promptDraftTitle == "未保存的标题" && appModel.promptDraftBody == "未保存的提示词正文", "外部点击收起丢失未保存的提示词")
    appModel.promptEditorOpen = false

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

    home.quickNote += "\n退出前追加"
    home.memoLibrary.selectedID = memoID
    home.memoLibrary.updateBody("正常退出前的最新正文")
    try require(controller.prepareForTermination(), "正常退出未保存笔记")
    try require(defaults.string(forKey: "home.quickNote") == home.quickNote, "退出前追加的便签未保存")
    try require(MemoLibraryModel(fileURL: memoURL).selectedItem?.body == "正常退出前的最新正文", "退出前修改的备忘录未保存")

    // Simulate a write failure without changing permissions or touching user data.
    let memoDirectory = memoURL.deletingLastPathComponent()
    try FileManager.default.removeItem(at: memoDirectory)
    try Data().write(to: memoDirectory)
    home.memoLibraryOpen = true
    home.memoLibrary.updateBody("写入失败也必须保留的内容")
    home.closeMemoLibrary()
    try require(home.memoLibraryOpen, "保存失败仍关闭了备忘录编辑面板")
    controller.handleOutsideClick()
    try require(!controller.panel.ignoresMouseEvents, "保存失败后窗口不能继续编辑")
    try require(home.memoLibraryOpen, "外部点击保存失败后关闭了备忘录界面")
    try require(!controller.prepareForTermination(), "保存失败时仍允许退出并丢失内存修改")
    try require(home.memoLibrary.selectedItem?.body == "写入失败也必须保留的内容", "关闭失败丢失编辑内容")
    try FileManager.default.removeItem(at: memoDirectory)
    home.closeMemoLibrary()
    try require(!home.memoLibraryOpen, "修复写入位置后不能保存并关闭面板")
    try require(MemoLibraryModel(fileURL: memoURL).selectedItem?.body == "写入失败也必须保留的内容", "失败后重试丢失正文")

    // Exercise the real native input buffers, including a Chinese IME marked
    // range, while SwiftUI refreshes the surrounding dashboard.
    controller.showExpanded(destination: .home)
    try await Task.sleep(nanoseconds: 150_000_000)
    guard let root = controller.panel.contentView,
          let quickEditor = findNoteEditor(in: root, identifier: "jaimo.quickNote.editor") else {
        throw PanelTestError.failed("未找到真实便签输入框")
    }
    controller.panel.makeFirstResponder(quickEditor)
    var expectedQuickNote = home.quickNote
    quickEditor.setSelectedRange(NSRange(location: (expectedQuickNote as NSString).length, length: 0))
    let savedQuickNote = defaults.string(forKey: "home.quickNote")
    for character in "连续输入不丢字" {
        quickEditor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        expectedQuickNote += String(character)
        try await Task.sleep(nanoseconds: 30_000_000)
        try require(quickEditor.string == expectedQuickNote && home.quickNote == expectedQuickNote, "便签连续输入被回填或丢字")
    }
    quickEditor.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    let composingText = quickEditor.string
    home.selectWidget(.quickNote)
    try await Task.sleep(nanoseconds: 50_000_000)
    try require(quickEditor.hasMarkedText() && quickEditor.string == composingText, "界面刷新打断中文输入法组合文本")
    quickEditor.insertText("中文", replacementRange: quickEditor.markedRange())
    expectedQuickNote += "中文"
    try require(quickEditor.string == expectedQuickNote && home.quickNote == expectedQuickNote, "中文提交后内容被旧文本覆盖")
    try require(defaults.string(forKey: "home.quickNote") == savedQuickNote, "真实便签输入期间提前保存")
    quickEditor.setSelectedRange(NSRange(location: 1, length: 0))
    home.selectWidget(.memo)
    try await Task.sleep(nanoseconds: 50_000_000)
    try require(quickEditor.selectedRange() == NSRange(location: 1, length: 0), "界面刷新重置了便签光标")

    let savedMemos = try Data(contentsOf: memoURL)
    home.memoLibrary.selectedID = memoID
    home.memoLibraryOpen = true
    try await Task.sleep(nanoseconds: 150_000_000)
    guard let memoEditor = findNoteEditor(in: root, identifier: "jaimo.memo.editor") else {
        throw PanelTestError.failed("未找到真实备忘录输入框")
    }
    controller.panel.makeFirstResponder(memoEditor)
    var expectedMemo = home.memoLibrary.selectedItem!.body
    memoEditor.setSelectedRange(NSRange(location: (expectedMemo as NSString).length, length: 0))
    for character in "连续编辑正文" {
        memoEditor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        expectedMemo += String(character)
        try await Task.sleep(nanoseconds: 30_000_000)
        try require(memoEditor.string == expectedMemo && home.memoLibrary.selectedItem?.body == expectedMemo, "备忘录真实输入丢失内容")
    }
    memoEditor.setMarkedText("pinyin", selectedRange: NSRange(location: 6, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    let composingMemo = memoEditor.string
    home.memoLibrary.selectedID = memoID
    try await Task.sleep(nanoseconds: 50_000_000)
    try require(memoEditor.hasMarkedText() && memoEditor.string == composingMemo, "备忘录刷新打断中文输入法组合文本")
    memoEditor.insertText("拼音", replacementRange: memoEditor.markedRange())
    expectedMemo += "拼音"
    try require(home.memoLibrary.selectedItem?.body == expectedMemo, "备忘录中文提交后文本不完整")
    let memosWhileTyping = try Data(contentsOf: memoURL)
    try require(memosWhileTyping == savedMemos, "真实备忘录输入期间提前保存")
    home.closeMemoLibrary()
    controller.hide()
    try require(defaults.string(forKey: "home.quickNote") == expectedQuickNote, "关闭未保存便签输入法提交的完整文本")
    try require(MemoLibraryModel(fileURL: memoURL).selectedItem?.body == expectedMemo, "关闭未保存备忘录连续输入的完整文本")

    try await testTopNotch(controller: controller, model: appModel, defaults: defaults, directory: directory)
    print("PASS: 刘海几何与多屏定位；悬停开关、防误触、移入内容区、快速重开、中转面板；笔记保存与中文输入；窗口缩放")
}

try await runTests()
