import AppKit
import Carbon
import ClipFlowKit
import SwiftUI
import WebKit
@testable import ClipFlow

enum PanelTestError: Error {
    case failed(String)
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw PanelTestError.failed(message) }
}

@MainActor
func findTerminalWebView(in view: NSView) -> WKWebView? {
    if let webView = view as? WKWebView { return webView }
    return view.subviews.lazy.compactMap { findTerminalWebView(in: $0) }.first
}


private struct PanelQuotaFetcher: QuotaFetching {
    func fetchQuota(for account: QuotaAccountConfig) async throws -> QuotaAccountSnapshot {
        // Leave the request active long enough to verify the model releases it when disabled.
        try await Task.sleep(nanoseconds: 30_000_000_000)
        throw PanelTestError.failed("面板自检查询等待过久")
    }
}

@MainActor
private func makePanelQuotaMonitor(in directory: URL) -> QuotaMonitorModel {
    QuotaMonitorModel(fileURL: directory.appendingPathComponent("PanelQuota/state.json"), fetcher: PanelQuotaFetcher())
}

@MainActor
func testQuotaPageRefresh(directory: URL) async throws {
    let suite = "ClipFlowPanelSelfTest.Quota.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(ToolDestination.quota.rawValue, forKey: "island.lastDestination")
    let preferences = PreferencesStore(defaults: defaults)
    let app = AppModel(preferences: preferences)
    let home = HomeDashboardModel(defaults: defaults,
                                  memoLibrary: MemoLibraryModel(fileURL: directory.appendingPathComponent("QuotaPanelMemos.json")),
                                  recordingsDirectory: directory.appendingPathComponent("QuotaPanelRecordings"),
                                  dailyReview: DailyReviewModel(fileURL: directory.appendingPathComponent("QuotaPanelReviews.json")),
                                  mirrorDirectory: directory.appendingPathComponent("QuotaPanelMirror"))
    home.hide(.recentApplications)

    let url = directory.appendingPathComponent("QuotaPage/state.json")
    let baseline = Date(timeIntervalSince1970: 1_800_000_000)
    var now = baseline.addingTimeInterval(299)
    var state = QuotaPersistedState.empty
    let accountIDs = Set(state.accounts.map(\.id))
    for (index, account) in state.accounts.enumerated() {
        state.snapshots[account.id] = QuotaAccountSnapshot(
            accountID: account.id, provider: account.provider, accountEmail: nil, planLabel: nil, buckets: [],
            resetCreditsCount: nil, creditBalance: nil, fetchedAt: baseline.addingTimeInterval(Double(index))
        )
    }
    try JSONFileStore<QuotaPersistedState>(fileURL: url).save(state)
    let controller = PanelController(model: app, preferences: preferences, homeModel: home,
                                     quotaMonitorFactory: { QuotaMonitorModel(fileURL: url, fetcher: PanelQuotaFetcher(), now: { now }) })
    let shell = controller.shellModel
    defer {
        _ = controller.prepareForTermination()
        controller.hide()
        finishWindowAnimation(controller.panel)
    }

    try require(shell.destination == .quota && !shell.isQuotaMonitorLoaded, "恢复额度页时在后台加载了模型")
    controller.showExpanded(openSettings: true)
    try require(!shell.isQuotaMonitorLoaded, "直接打开设置时加载了额度模型")
    try await Task.sleep(nanoseconds: 150_000_000)
    app.settingsOpen = false
    let loadDeadline = Date().addingTimeInterval(2)
    while !shell.isQuotaMonitorLoaded && Date() < loadDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
    guard let monitor = shell.quotaMonitor else { throw PanelTestError.failed("关闭设置后未加载额度页") }
    try require(!monitor.isRefreshing && monitor.snapshots == state.snapshots, "首次显示未满五分钟的额度页时触发了查询")

    controller.hide()
    now = baseline.addingTimeInterval(300)
    controller.showExpanded()
    try require(!monitor.isRefreshing, "重新打开恰好五分钟的额度快照时触发了查询")
    controller.hide()
    now = baseline.addingTimeInterval(301)
    try require(!monitor.isRefreshing, "额度页隐藏时触发了过期查询")
    controller.showExpanded()
    try require(shell.quotaMonitor === monitor && monitor.refreshingAccountIDs == [state.accounts[0].id],
                "重新打开额度页时没有只查询超过五分钟的账号")

    controller.showExpanded(destination: .home)
    monitor.cancelAll()
    now = baseline.addingTimeInterval(302)
    controller.hide()
    controller.showExpanded(destination: .applications)
    try require(!monitor.isRefreshing, "打开其他页面时查询了过期额度")
    controller.showExpanded(destination: .quota)
    try require(monitor.refreshingAccountIDs == accountIDs, "切回额度页时未查询过期账号")

    controller.showExpanded(openSettings: true)
    monitor.cancelAll()
    controller.showExpanded(openSettings: true)
    try require(!monitor.isRefreshing, "设置打开时查询了已加载的过期额度")
    try await Task.sleep(nanoseconds: 150_000_000)
    app.settingsOpen = false
    let refreshDeadline = Date().addingTimeInterval(2)
    while !monitor.isRefreshing && Date() < refreshDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
    try require(monitor.refreshingAccountIDs == accountIDs, "关闭设置返回额度页时未刷新过期快照")

    preferences.quotaEnabled = false
    try require(shell.destination == .home && !shell.isQuotaMonitorLoaded && !monitor.isRefreshing,
                "禁用额度模块后未回到首页、释放模型或取消查询")
    preferences.quotaEnabled = true
    try require(!shell.isQuotaMonitorLoaded, "重新启用额度模块时在首页加载了模型")
    controller.showExpanded(destination: .quota)
    try require(shell.quotaMonitor !== monitor && shell.quotaMonitor?.refreshingAccountIDs == accountIDs,
                "重新启用后进入额度页时未查询磁盘中过期的快照")
}

@MainActor
func testModulePreferences(directory: URL) async throws {
    let suite = "ClipFlowPanelSelfTest.Modules.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = PreferencesStore(defaults: defaults)
    try require(preferences.terminalEnabled && preferences.recordingEnabled && preferences.mirrorEnabled
                && preferences.quotaEnabled, "新用户及无模块偏好的旧用户应默认启用四个模块")

    let recordings = directory.appendingPathComponent("ModuleRecordings")
    try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    let recording = recordings.appendingPathComponent("2026-11-26.m4a")
    let recordingBytes = Data([0])
    try recordingBytes.write(to: recording)
    let mirror = directory.appendingPathComponent("ModuleMirror")
    try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
    let cover = mirror.appendingPathComponent("cover.tiff")
    let image = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { rect in
        NSColor.white.setFill()
        rect.fill()
        return true
    }
    guard let coverBytes = image.tiffRepresentation else { throw PanelTestError.failed("无法生成临时镜子封面") }
    try coverBytes.write(to: cover)
    let memoLibrary = MemoLibraryModel(fileURL: directory.appendingPathComponent("ModuleMemos.json"))
    let dailyReview = DailyReviewModel(fileURL: directory.appendingPathComponent("ModuleReviews.json"))
    let home = HomeDashboardModel(defaults: defaults, memoLibrary: memoLibrary, recordingsDirectory: recordings,
                                  dailyReview: dailyReview, mirrorDirectory: mirror)
    home.hide(.recentApplications)
    let app = AppModel(preferences: preferences)
    let controller = PanelController(model: app, preferences: preferences, homeModel: home,
                                     quotaMonitorFactory: { makePanelQuotaMonitor(in: directory) })
    defer {
        controller.hide()
        finishWindowAnimation(controller.panel)
    }
    let shell = controller.shellModel
    try require(shell.availableDestinations == ToolDestination.allCases, "模块默认开启时应保留所有导航")
    try require(home.visibleWidgets.contains(.camera) && home.visibleWidgets.contains(.audioRecorder),
                "镜子与录音应按默认组件布局显示")

    func press(_ code: Int, _ key: String, modifiers: NSEvent.ModifierFlags = .command) throws {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: controller.panel.windowNumber, context: nil,
                                           characters: key, charactersIgnoringModifiers: key, isARepeat: false,
                                           keyCode: UInt16(code)) else {
            throw PanelTestError.failed("无法构造额度快捷键事件")
        }
        NSApp.sendEvent(event)
    }

    try require(!shell.isQuotaMonitorLoaded, "创建面板时提前加载额度")
    controller.showExpanded(destination: .applications)
    try require(!shell.isQuotaMonitorLoaded, "进入应用页时提前加载额度")
    try press(kVK_ANSI_7, "7")
    guard let retiredQuota = shell.quotaMonitor else { throw PanelTestError.failed("⌘7 未加载额度模块") }
    try require(shell.destination == .quota && retiredQuota.refreshingAccountIDs.count == 2,
                "首次进入额度页未并发查询默认账号")
    retiredQuota.beginAddAccount()
    controller.handleOutsideClick()
    try require(shell.isQuotaModalOpen && controller.isVisible, "账号编辑打开时外部点击收起了面板")
    try press(kVK_Escape, "\u{1b}", modifiers: [])
    try require(!shell.isQuotaModalOpen && controller.isVisible, "Escape 未先关闭账号编辑")
    retiredQuota.beginAddAccount()

    preferences.quotaEnabled = false
    try require(shell.destination == .home && !shell.availableDestinations.contains(.quota)
                && !shell.isQuotaMonitorLoaded && !retiredQuota.isRefreshing && !retiredQuota.editorOpen,
                "关闭额度后未回落首页、取消查询或释放编辑器与模型")
    try require(defaults.string(forKey: "island.lastDestination") == ToolDestination.home.rawValue
                && !defaults.bool(forKey: "module.quotaEnabled"), "额度开关或回落页未持久化")
    try press(kVK_ANSI_7, "7")
    try require(shell.destination == .home && !shell.isQuotaMonitorLoaded, "禁用后 ⌘7 仍打开额度页")

    defaults.set(ToolDestination.quota.rawValue, forKey: "island.lastDestination")
    let quotaDisabledShell = IslandShellModel(preferences: PreferencesStore(defaults: defaults),
                                              quotaMonitorFactory: { makePanelQuotaMonitor(in: directory) })
    quotaDisabledShell.activateQuotaIfSelected()
    try require(quotaDisabledShell.destination == .home && !quotaDisabledShell.isQuotaMonitorLoaded
                && defaults.string(forKey: "island.lastDestination") == ToolDestination.home.rawValue,
                "启动时恢复被禁用的额度页面没有回落到首页")

    preferences.quotaEnabled = true
    try require(PreferencesStore(defaults: defaults).quotaEnabled && shell.availableDestinations.contains(.quota)
                && !shell.isQuotaMonitorLoaded, "重新开启额度未恢复入口或提前加载模型")
    try press(kVK_ANSI_7, "7")
    guard let reopenedQuota = shell.quotaMonitor else { throw PanelTestError.failed("重新开启额度后 ⌘7 未加载模型") }
    try require(shell.destination == .quota && reopenedQuota !== retiredQuota && !reopenedQuota.isRefreshing,
                "重新开启额度复用了旧模型或同一会话重复自动查询")
    try press(kVK_ANSI_R, "r")
    try require(reopenedQuota.refreshingAccountIDs.count == 2, "⌘R 未刷新额度")
    try require(controller.prepareForTermination() && !reopenedQuota.isRefreshing, "退出时未取消额度查询")

    controller.showExpanded(destination: .terminal)
    try await Task.sleep(nanoseconds: 150_000_000)
    guard let retiredSession = shell.terminalSession else { throw PanelTestError.failed("进入终端后未加载会话") }
    try require(controller.panel.contentView.flatMap(findTerminalWebView(in:)) != nil, "终端 WKWebView 未挂载")

    preferences.terminalEnabled = false
    try require(shell.destination == .home && !shell.availableDestinations.contains(.terminal),
                "关闭终端后未回落到首页或仍显示终端导航")
    try require(!shell.isTerminalSessionLoaded && retiredSession.webView == nil,
                "关闭终端后仍保留会话或会话仍持有 WKWebView")
    try require(defaults.string(forKey: "island.lastDestination") == ToolDestination.home.rawValue,
                "关闭当前终端后未持久化回落的首页")
    let unmountDeadline = Date().addingTimeInterval(2)
    while controller.panel.contentView.flatMap(findTerminalWebView(in:)) != nil && Date() < unmountDeadline {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    try require(controller.panel.contentView.flatMap(findTerminalWebView(in:)) == nil, "关闭终端后 WKWebView 仍挂载在窗口中")
    controller.showExpanded(destination: .terminal)
    try require(shell.destination == .home && !shell.isTerminalSessionLoaded, "禁用后显式导航重新加载了终端")
    guard let shortcut = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: controller.panel.windowNumber, context: nil,
                                          characters: "6", charactersIgnoringModifiers: "6", isARepeat: false,
                                          keyCode: UInt16(kVK_ANSI_6)) else {
        throw PanelTestError.failed("无法构造终端快捷键事件")
    }
    NSApp.sendEvent(shortcut)
    try require(shell.destination == .home && !shell.isTerminalSessionLoaded, "禁用后 ⌘6 仍打开终端")

    defaults.set(ToolDestination.terminal.rawValue, forKey: "island.lastDestination")
    let restoredShell = IslandShellModel(preferences: PreferencesStore(defaults: defaults),
                                         quotaMonitorFactory: { makePanelQuotaMonitor(in: directory) })
    restoredShell.activateTerminalIfSelected()
    try require(restoredShell.destination == .home && !restoredShell.isTerminalSessionLoaded
                && defaults.string(forKey: "island.lastDestination") == ToolDestination.home.rawValue,
                "启动时恢复被禁用的终端页面没有回落到首页")

    controller.showExpanded(destination: .home)
    home.openRecordingWorkspace(selecting: recording)
    guard let retiredTranscription = home.recordingTranscription else { throw PanelTestError.failed("打开录音工作台未加载转写管理器") }
    try require(home.recordingWorkspaceOpen && retiredTranscription.playback.currentURL == recording,
                "录音关闭前未建立工作台和播放选择")
    let initialHidden = home.hiddenWidgets
    let initialStoredHidden = defaults.stringArray(forKey: "home.hiddenWidgets")
    preferences.recordingEnabled = false
    preferences.mirrorEnabled = false
    try require(!home.recordingWorkspaceOpen && !home.isRecordingTranscriptionLoaded
                && retiredTranscription.playback.currentURL == nil && !retiredTranscription.playback.isPlaying,
                "关闭录音后工作台、转写管理器或播放器未释放")
    home.openRecordingWorkspace(selecting: recording)
    home.audioRecorder.onDidFinishRecording?(recording)
    try require(!home.recordingWorkspaceOpen && !home.isRecordingTranscriptionLoaded,
                "录音模块关闭时仍可打开工作台或加载转写")
    for widget in [HomeDashboardModel.WidgetID.audioRecorder, .camera] {
        try require(!home.visibleWidgets.contains(widget) && !home.restorableWidgets.contains(widget),
                    "关闭的模块仍出现在首页或恢复菜单")
    }
    try require(home.hiddenWidgets == initialHidden && defaults.stringArray(forKey: "home.hiddenWidgets") == initialStoredHidden,
                "关闭模块改写了原有隐藏组件偏好")
    let savedRecording = try Data(contentsOf: recording)
    try require(savedRecording == recordingBytes, "关闭录音后本地录音文件未保留")
    let savedCover = try Data(contentsOf: cover)
    try require(savedCover == coverBytes, "关闭镜子后封面内容发生变化")
    try require(home.mirrorPhotoURL?.standardizedFileURL.path == cover.standardizedFileURL.path,
                "关闭镜子后未保留原封面路径")
    let disabled = PreferencesStore(defaults: defaults)
    try require(!disabled.terminalEnabled && !disabled.recordingEnabled && !disabled.mirrorEnabled
                && !defaults.bool(forKey: "module.terminalEnabled")
                && !defaults.bool(forKey: "module.recordingEnabled") && !defaults.bool(forKey: "module.mirrorEnabled"),
                "三个模块开关的关闭状态未通过指定键持久化")
    let disabledHome = HomeDashboardModel(defaults: defaults, memoLibrary: memoLibrary, recordingsDirectory: recordings,
                                          dailyReview: dailyReview, mirrorDirectory: mirror)
    let disabledController = PanelController(model: AppModel(preferences: disabled), preferences: disabled, homeModel: disabledHome,
                                             quotaMonitorFactory: { makePanelQuotaMonitor(in: directory) })
    try require(!disabledController.shellModel.availableDestinations.contains(.terminal)
                && !disabledHome.visibleWidgets.contains(.audioRecorder) && !disabledHome.visibleWidgets.contains(.camera),
                "新面板没有应用已持久化的关闭状态")

    preferences.terminalEnabled = true
    preferences.recordingEnabled = true
    preferences.mirrorEnabled = true
    try require(shell.availableDestinations == ToolDestination.allCases && shell.destination == .home && !shell.isTerminalSessionLoaded,
                "重新启用终端后未恢复入口，或提前切页并创建会话")
    try require(home.visibleWidgets.contains(.audioRecorder) && home.visibleWidgets.contains(.camera)
                && !home.isRecordingTranscriptionLoaded && !home.camera.isRunning,
                "重新启用后未恢复原可见组件，或提前启动录音转写或摄像头")
    NSApp.sendEvent(shortcut)
    try require(shell.destination == .terminal && shell.terminalSession != nil && shell.terminalSession !== retiredSession,
                "重新启用后 ⌘6 未加载新的终端会话")
    controller.showExpanded(destination: .home)
    home.openRecordingWorkspace(selecting: recording)
    try require(home.recordingWorkspaceOpen && home.recordingTranscription != nil && home.recordingTranscription !== retiredTranscription,
                "重新启用录音后未按需创建新的转写管理器")
    home.closeRecordingWorkspace()

    home.hide(.audioRecorder)
    home.hide(.camera)
    let storedHidden = defaults.stringArray(forKey: "home.hiddenWidgets")
    preferences.recordingEnabled = false
    preferences.mirrorEnabled = false
    home.restore(.audioRecorder)
    home.restore(.camera)
    try require(!home.restorableWidgets.contains(.audioRecorder) && !home.restorableWidgets.contains(.camera),
                "关闭的模块仍可从恢复菜单找回")
    preferences.recordingEnabled = true
    preferences.mirrorEnabled = true
    try require(home.hiddenWidgets == initialHidden.union([.audioRecorder, .camera])
                && defaults.stringArray(forKey: "home.hiddenWidgets") == storedHidden
                && !home.visibleWidgets.contains(.audioRecorder) && !home.visibleWidgets.contains(.camera)
                && home.restorableWidgets.contains(.audioRecorder) && home.restorableWidgets.contains(.camera),
                "重新开启模块后未还原用户此前隐藏的组件布局")
    let reenabled = PreferencesStore(defaults: defaults)
    try require(reenabled.terminalEnabled && reenabled.recordingEnabled && reenabled.mirrorEnabled,
                "三个模块开关的重新启用状态未持久化")
    preferences.terminalEnabled = false
    try require(shell.destination == .home && !shell.isTerminalSessionLoaded,
                "在其他页面关闭已加载的终端时改变了页面或保留了会话")
}

@MainActor
func testClipboardIncrementalUpdates(preferences: PreferencesStore, directory: URL) async throws {
    let store = try SQLiteClipStore(baseDirectory: directory.appendingPathComponent("Clipboard"))
    func capture(_ title: String, at timestamp: TimeInterval) -> CapturedClip {
        CapturedClip(kind: .text, category: .text, sourceAppName: "SelfTest", sourceBundleID: "com.clipflow.selftest",
                     copiedAt: Date(timeIntervalSince1970: timestamp), title: title, fullText: title,
                     meta: [], contentHash: ClipClassifier.hash(Data(title.utf8)))
    }

    let favorite = try store.insert(capture("收藏", at: 0))!
    try store.setFavorite(id: favorite.id, isFavorite: true)
    for timestamp in 1...ClipboardLibraryModel.historyLimit {
        try store.insert(capture("历史 \(timestamp)", at: TimeInterval(timestamp)))
    }

    let appModel = AppModel(preferences: preferences, store: store)
    appModel.load()
    let deadline = Date().addingTimeInterval(3)
    while appModel.clipboard.items.isEmpty && Date() < deadline {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    try require(appModel.clipboard.items.count == ClipboardLibraryModel.historyLimit + 1, "加载旧库时收藏占用了普通历史额度")
    _ = appModel.clipboard.filteredItems

    var unrelatedChanges = 0
    let observations = [
        appModel.objectWillChange.sink { unrelatedChanges += 1 },
        appModel.prompts.objectWillChange.sink { unrelatedChanges += 1 },
        appModel.credentials.objectWillChange.sink { unrelatedChanges += 1 }
    ]
    defer { observations.forEach { $0.cancel() } }

    let newest = capture("同一时间的新记录", at: TimeInterval(ClipboardLibraryModel.historyLimit))
    let captures = [newest, newest, capture("立即淘汰的旧记录", at: -1), capture("插在中间的记录", at: 75.5)]
    for captured in captures {
        appModel.receive(captured)
        let storedItems = try store.loadAll()
        try require(appModel.clipboard.items == storedItems && appModel.clipboard.filteredItems == storedItems, "增量更新后应用列表或缓存与 SQLite 不一致")
        try require(appModel.clipboard.items.first?.title == newest.title && appModel.clipboard.selectedID == storedItems.first?.id,
                    "相同时间的新记录没有置顶或选中")
        try require(appModel.clipboard.items.count == ClipboardLibraryModel.historyLimit + 1 && appModel.clipboard.items.last?.id == favorite.id,
                    "增量更新未保留收藏及 150 条普通历史")
    }
    try require(unrelatedChanges == 0, "剪贴板增量更新触发了协调器或其他资料库的观察通知")
}

@MainActor
func testLibraryShortcuts(directory: URL) async throws {
    let suite = "ClipFlowPanelSelfTest.Shortcuts.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let preferences = PreferencesStore(defaults: defaults)
    preferences.closeAfterCopy = false
    let store = try SQLiteClipStore(baseDirectory: directory.appendingPathComponent("ShortcutLibrary"))
    let credentials = CredentialStore(service: suite)
    let credentialID = try credentials.save(id: nil, title: "示例密钥", secret: "test-secret")
    let pasteboard = NSPasteboard(name: .init(suite))
    defer {
        try? credentials.delete(id: credentialID)
        pasteboard.releaseGlobally()
        defaults.removePersistentDomain(forName: suite)
    }
    let captured = CapturedClip(kind: .text, category: .text, sourceAppName: "SelfTest", sourceBundleID: "com.clipflow.selftest",
                                copiedAt: Date(), title: "剪贴板正文", fullText: "剪贴板正文",
                                meta: [], contentHash: ClipClassifier.hash(Data("剪贴板正文".utf8)))
    _ = try store.insert(captured)
    _ = try store.createPrompt(title: "既有提示词", body: "既有正文", groupName: "自检", variables: [])
    let model = AppModel(preferences: preferences, credentialStore: credentials, store: store)
    model.clipboardMonitor = ClipboardMonitor(pasteboard: pasteboard)
    let home = HomeDashboardModel(defaults: defaults, memoLibrary: MemoLibraryModel(fileURL: directory.appendingPathComponent("ShortcutMemos.json")))
    let controller = PanelController(model: model, preferences: preferences, homeModel: home,
                                     quotaMonitorFactory: { makePanelQuotaMonitor(in: directory) })
    defer {
        controller.hide()
        finishWindowAnimation(controller.panel)
    }

    func press(_ keyCode: Int, _ characters: String, modifiers: NSEvent.ModifierFlags = [], keyEquivalent: Bool = false) throws {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: controller.panel.windowNumber, context: nil,
                                           characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: UInt16(keyCode)) else {
            throw PanelTestError.failed("无法构造自检键盘事件")
        }
        if keyEquivalent {
            // Preview buttons receive Return through AppKit's key-equivalent dispatch.
            _ = controller.panel.performKeyEquivalent(with: event)
        } else {
            NSApp.sendEvent(event)
        }
    }

    func pressReturnWhenRendered(until actionRan: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        // A ready model can precede SwiftUI registering the preview's Return shortcut.
        repeat {
            controller.panel.contentView?.layoutSubtreeIfNeeded()
            try press(kVK_Return, "\r", keyEquivalent: true)
            if actionRan() { return }
            try await Task.sleep(for: .milliseconds(20))
        } while clock.now < deadline
    }

    model.load()
    controller.showExpanded(destination: .clipboard)
    let deadline = Date().addingTimeInterval(3)
    while (model.clipboard.items.isEmpty || model.focusArea != .search) && Date() < deadline {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    try require(model.clipboard.selectedItem?.title == "剪贴板正文", "剪切板展开后未选中首条记录")
    model.focusArea = .other
    try press(kVK_ANSI_F, "f", modifiers: .command)
    try require(model.focusArea == .search, "⌘F 未聚焦剪切板搜索框")
    model.clipboard.query = "正文"
    try press(kVK_Escape, "\u{1b}")
    try require(model.clipboard.query.isEmpty && controller.isVisible, "ESC 未先清空剪切板搜索")
    try await pressReturnWhenRendered { pasteboard.string(forType: .string) != nil }
    try require(pasteboard.string(forType: .string) == captured.fullText, "↵ 未复制选中的剪贴板记录")

    model.beginPromptFromClipboard()
    model.prompts.promptDraftTitle = ""
    try press(kVK_ANSI_S, "s", modifiers: .command)
    try require(model.prompts.promptEditorOpen && controller.shellModel.destination == .clipboard, "保存失败后丢失编辑器或离开剪切板")
    model.prompts.promptDraftTitle = "从剪贴板保存"
    try press(kVK_ANSI_S, "s", modifiers: .command)
    try require(!model.prompts.promptEditorOpen && controller.shellModel.destination == .prompts
                && model.prompts.selectedPrompt?.body == captured.fullText, "保存剪贴板记录后未进入并选中新提示词")
    let savedID = model.prompts.selectedPromptID
    try press(kVK_UpArrow, "\u{f700}")
    try require(model.prompts.selectedPromptID != savedID, "↑ 未移动提示词选中项")
    try press(kVK_DownArrow, "\u{f701}")
    try require(model.prompts.selectedPromptID == savedID, "↓ 未回到刚保存的提示词")
    pasteboard.clearContents()
    let previousUseCount = model.prompts.selectedPrompt?.useCount
    try await pressReturnWhenRendered { model.prompts.selectedPrompt?.useCount != previousUseCount }
    try require(model.prompts.selectedPrompt?.useCount != previousUseCount
                && pasteboard.string(forType: .string) == captured.fullText, "↵ 未使用选中的提示词")

    try press(kVK_ANSI_4, "4", modifiers: .command)
    model.focusArea = .other
    try press(kVK_Tab, "\t", modifiers: .shift)
    try require(model.clipboard.isCredentialGroup, "⇧Tab 未切换到 API Key 分组")
    try press(kVK_Return, "\r")
    try require(pasteboard.string(forType: .string) == "test-secret", "↵ 未复制选中的 API Key")
    try press(kVK_ANSI_E, "e", modifiers: .command)
    try require(model.credentials.editingCredentialID == credentialID && model.credentials.credentialEditorOpen, "⌘E 未打开 API Key 编辑器")
    try press(kVK_Escape, "\u{1b}")
    try press(kVK_ANSI_N, "n", modifiers: .command)
    try require(model.credentials.editingCredentialID == nil && model.credentials.credentialEditorOpen, "⌘N 未新建 API Key")
    try press(kVK_Escape, "\u{1b}")
    try press(kVK_Delete, "\u{7f}", modifiers: .command)
    try require(model.credentials.credentialDeleteConfirmationOpen, "⌘⌫ 未打开 API Key 删除确认")
    try press(kVK_Escape, "\u{1b}")

    try press(kVK_ANSI_3, "3", modifiers: .command)
    try press(kVK_ANSI_S, "s", modifiers: .command)
    try require(model.prompts.selectedPromptID == savedID && model.prompts.selectedPrompt?.isFavorite == true, "剪切板停在 API Key 分组时，⌘S 未收藏提示词")
    try press(kVK_ANSI_E, "e", modifiers: .command)
    try require(model.prompts.editingPromptID == savedID && model.prompts.promptEditorOpen, "⌘E 未编辑提示词")
    try press(kVK_Escape, "\u{1b}")
    try press(kVK_Delete, "\u{7f}", modifiers: .command)
    try require(model.prompts.promptDeleteConfirmationOpen && !model.credentials.credentialDeleteConfirmationOpen, "⌘⌫ 路由到了错误的删除确认")
    try press(kVK_Escape, "\u{1b}")
    try press(kVK_ANSI_N, "n", modifiers: .command)
    try require(model.prompts.editingPromptID == nil && model.prompts.promptEditorOpen, "⌘N 未打开新建提示词")
    try press(kVK_Escape, "\u{1b}")
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
    let hardwareWithItems = TopNotchGeometry.frame(screen: screenRect, visible: screenRect, safeAreaTop: 38, hardwareWidth: 200, hasItems: true)
    try require(hardware.height == 38 && hardware.width == 264 && hardware.midX == 720, "物理刘海空态耳翼几何错误")
    try require(hardwareWithItems.width == 320 && hardwareWithItems.midX == hardware.midX, "物理刘海非空态未为徽标预留耳翼")
    let airWithItems = TopNotchGeometry.frame(screen: screenRect, visible: screenRect, hasItems: true)
    try require(hiddenMenu.width == 164 && airWithItems.width == 224, "无物理刘海的空态或徽标宽度错误")
    let offset = TopNotchGeometry.frame(screen: NSRect(x: -1440, y: 200, width: 1440, height: 900),
                                       visible: NSRect(x: -1440, y: 200, width: 1440, height: 875))
    try require(offset.midX == -720 && offset.maxY == 1100, "多屏坐标导致入口偏移")

    controller.hide()
    finishWindowAnimation(controller.panel)
    let notch = TopNotchController(panelController: controller, relayModel: FileRelayModel(rootURL: directory.appendingPathComponent("Relay"), defaults: defaults),
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
    try require(!controller.isVisible, "设置浮层打开时移出内容区未收起")
    try await Task.sleep(nanoseconds: 300_000_000)
    finishWindowAnimation(controller.panel)
    try require(!controller.panel.isVisible, "收起动画结束后窗口仍可见")
    try require(model.settingsOpen, "移出后设置浮层状态丢失")
    controller.showExpanded()
    try require(model.settingsOpen, "重新打开后设置浮层未恢复")
    model.settingsOpen = false

    controller.showExpanded(destination: .prompts)
    model.prompts.promptEditorOpen = true
    model.prompts.promptDraftBody = "保留草稿"
    controller.hideAfterPointerExit()
    try require(!controller.isVisible && model.prompts.promptEditorOpen, "移出时提示词弹窗状态丢失")
    try require(model.prompts.promptDraftBody == "保留草稿", "移出时丢失提示词草稿")
    finishWindowAnimation(controller.panel)
    controller.showExpanded(destination: .prompts)
    try require(model.prompts.promptEditorOpen && model.prompts.promptDraftBody == "保留草稿", "重新打开未恢复提示词弹窗和草稿")
    model.prompts.promptEditorOpen = false
    controller.hide()
    finishWindowAnimation(controller.panel)

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
    try require(controller.hasEventMonitors, "快速收起重开时旧动画卸载了事件监听")
    try require(controller.panel.frame.size == sizeBefore, "展开动画改变了工作区尺寸")

    let sourceA = directory.appendingPathComponent("source-a.txt")
    let sourceB = directory.appendingPathComponent("source-b.txt")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("原始 A".utf8).write(to: sourceA)
    try Data("原始 B".utf8).write(to: sourceB)
    try require(!notch.relayModel.removeAfterDrag, "拖出后移除默认应关闭")
    notch.relayModel.add(urls: [sourceA, directory.appendingPathComponent("不存在")])
    notch.relayModel.add(urls: [sourceB])
    let importDeadline = Date().addingTimeInterval(5)
    while (notch.relayModel.isImporting || notch.relayModel.items.count < 2) && Date() < importDeadline {
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    try require(notch.relayModel.items.count == 2, "连续导入丢失文件或单项失败影响其他文件")
    try require(notch.relayModel.errorMessage != nil, "连续导入掩盖了失败反馈")
    try Data("修改后的原件".utf8).write(to: sourceA)
    let itemA = notch.relayModel.items.first { $0.originalName == sourceA.lastPathComponent }!
    let copiedA = try String(contentsOf: notch.relayModel.storedURL(for: itemA), encoding: .utf8)
    try require(copiedA == "原始 A", "中转文件不是独立副本")
    try require(FileRelayModel(rootURL: directory.appendingPathComponent("Relay"), defaults: defaults).items.count == 2, "索引未持久化")
    controller.hide()
    finishWindowAnimation(controller.panel)
    notch.handlePointer(at: outside)
    try await Task.sleep(nanoseconds: 100_000_000)
    let badgePoint = NSPoint(x: notch.notchPanel.frame.maxX - 15, y: notch.notchPanel.frame.midY)
    // Moving from the body to the badge before the hover timer fires must use the latest point.
    notch.handlePointer(at: inside)
    try await Task.sleep(nanoseconds: 50_000_000)
    notch.handlePointer(at: badgePoint)
    try await Task.sleep(nanoseconds: 200_000_000)
    try require(notch.relayPanel.isVisible && !controller.isVisible, "悬停期间移至徽标未打开小兜")
    notch.handleEscape()
    try await Task.sleep(nanoseconds: 300_000_000)
    notch.handleNotchClick(at: badgePoint)
    try require(notch.relayPanel.isVisible && !controller.isVisible, "点击徽标未打开小兜")
    notch.handleEscape()
    try await Task.sleep(nanoseconds: 300_000_000)

    let baseline = NSPasteboard(name: .drag).changeCount
    notch.handlePointerEvent(type: .leftMouseUp, at: outside, dragChangeCount: baseline, hasFileURL: true)
    notch.handlePointerEvent(type: .leftMouseDragged, at: inside, dragChangeCount: baseline, hasFileURL: true)
    try require(!notch.relayModel.isDropTargeted && !notch.relayPanel.isVisible, "残留拖拽剪贴板误触发小兜")
    notch.handlePointerEvent(type: .leftMouseDragged, at: inside, dragChangeCount: baseline + 1, hasFileURL: false)
    try require(!notch.relayModel.isDropTargeted && !notch.relayPanel.isVisible, "非文件拖拽误触发小兜")
    notch.relayModel.isDraggingOut = true
    notch.handlePointerEvent(type: .leftMouseDragged, at: inside, dragChangeCount: baseline + 1, hasFileURL: true)
    try require(!notch.relayModel.isDropTargeted && !notch.relayPanel.isVisible, "拖出文件误触发拖入落区")
    notch.relayModel.isDraggingOut = false
    notch.handlePointerEvent(type: .leftMouseDragged, at: inside, dragChangeCount: baseline + 1, hasFileURL: true)
    try require(notch.relayPanel.isVisible && notch.relayModel.isDropTargeted, "文件拖近刘海未张开小兜")
    notch.handleFileDrag(at: outside, hasFiles: true)
    try await Task.sleep(nanoseconds: 300_000_000)
    try require(!notch.relayPanel.isVisible, "拖离小兜未收起")

    notch.showRelay()
    try await Task.sleep(nanoseconds: 300_000_000)
    try require(notch.relayPanel.isVisible && !controller.isVisible, "文件中转面板与工具站状态冲突")
    if let screen = notch.relayPanel.screen {
        try require(abs(notch.relayPanel.frame.maxY - TopNotchGeometry.workspaceTop(on: screen)) <= 1, "小兜未贴合刘海下沿")
        try require(notch.relayPanel.frame.height <= 97, "小兜高度超出紧凑形态")
    }
    notch.handlePointer(at: NSPoint(x: notch.relayPanel.frame.midX, y: notch.relayPanel.frame.midY))
    try await Task.sleep(nanoseconds: 400_000_000)
    try require(notch.relayPanel.isVisible, "文件中转面板内操作误收起")
    notch.relayModel.isPinned = true
    try await verifyAppearance(notch.relayPanel, preferences: controller.preferences)
    notch.handlePointerEvent(type: .leftMouseDown, at: outside, dragChangeCount: baseline, hasFileURL: false)
    try require(notch.relayPanel.isVisible, "固定时外部点击关闭小兜")
    notch.handlePointer(at: outside)
    try await Task.sleep(nanoseconds: 400_000_000)
    try require(notch.relayPanel.isVisible, "固定时小兜被自动收起")
    notch.relayModel.isPinned = false
    notch.relayModel.isDraggingOut = true
    notch.handlePointer(at: outside)
    try await Task.sleep(nanoseconds: 400_000_000)
    try require(notch.relayPanel.isVisible, "拖出期间小兜被自动收起")
    notch.relayModel.isDraggingOut = false
    notch.handleEscape()
    try await Task.sleep(nanoseconds: 300_000_000)
    try require(!notch.relayPanel.isVisible, "Escape 未收起小兜")
    notch.showRelay()
    notch.handlePointer(at: outside)
    try await Task.sleep(nanoseconds: 600_000_000)
    try require(!notch.relayPanel.isVisible, "移出中转面板后未收起")

    notch.handlePointer(at: inside)
    notch.isEnabled = false
    try await Task.sleep(nanoseconds: 250_000_000)
    try require(!notch.notchPanel.isVisible && !controller.isVisible, "隐藏入口后延迟悬停仍打开工具站")
    notch.isEnabled = true
    try require(notch.notchPanel.isVisible, "隐藏后无法恢复入口")

    controller.showExpanded(destination: .home)
    try await verifyAppearance(controller.panel, preferences: controller.preferences)
}

@MainActor
func verifyAppearance(_ panel: NSPanel, preferences: PreferencesStore) async throws {
    let originalSystemAppearance = NSApp.appearance
    let originalPreference = preferences.appearance
    defer {
        NSApp.appearance = originalSystemAppearance
        preferences.appearance = originalPreference
    }

    func hasMaterial(_ view: NSView, named name: NSAppearance.Name) -> Bool {
        if let effect = view as? NSVisualEffectView, effect.state == .active,
           effect.blendingMode == .behindWindow, effect.appearance?.name == name { return true }
        return view.subviews.contains { hasMaterial($0, named: name) }
    }

    guard let root = panel.contentView else { throw PanelTestError.failed("外观测试缺少面板视图") }
    for system in [NSAppearance.Name.aqua, .darkAqua] {
        NSApp.appearance = NSAppearance(named: system)
        let forced: FlowAppearance = system == .aqua ? .black : .light
        for preference in [forced, .system] {
            preferences.appearance = preference
            try await Task.sleep(nanoseconds: 150_000_000)
            let expected: NSAppearance.Name = preference == .system ? system : (forced == .black ? .darkAqua : .aqua)
            try require(hasMaterial(root, named: expected), "原生材质没有切换到预期外观：\(preference.title)、\(system)")
        }
    }
}

@MainActor
func runTests() async throws {
    _ = NSApplication.shared
    let standardDestinationBefore = UserDefaults.standard.string(forKey: "island.lastDestination")
    let suite = "ClipFlowPanelSelfTest.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    for (raw, expected) in [("system", FlowAppearance.system), ("black", .black), ("light", .light)] {
        defaults.set(raw, forKey: "appearance")
        try require(PreferencesStore(defaults: defaults).appearance == expected, "无法读取外观偏好 \(raw)")
    }
    defaults.removeObject(forKey: "appearance")
    let preferences = PreferencesStore(defaults: defaults)
    try require(preferences.workspaceSize == NSSize(width: 849, height: 575), "首次启动的默认尺寸不正确")
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("ClipFlowPanelNotes-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let memoURL = directory.appendingPathComponent("Memos/memos.json")
    let recordings = directory.appendingPathComponent("Recordings")
    try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    let latestRecording = recordings.appendingPathComponent("2026-11-26.m4a")
    try Data([0]).write(to: latestRecording)
    let home = HomeDashboardModel(defaults: defaults, memoLibrary: MemoLibraryModel(fileURL: memoURL), recordingsDirectory: recordings)
    home.hide(.recentApplications)
    let appModel = AppModel(preferences: preferences)
    let controller = PanelController(model: appModel, preferences: preferences, homeModel: home,
                                     quotaMonitorFactory: { makePanelQuotaMonitor(in: directory) })
    defer { controller.panel.orderOut(nil) }

    let destinations = ToolDestination.allCases
    try require(preferences.enabledDestinations == destinations && preferences.navigationDisplayStyle == .iconAndTitle,
                "默认应开启七页并显示图标与名称")
    try require(!NavigationDisplayStyle.iconOnly.showsLabels(width: 1200, destinationCount: 7)
                && !NavigationDisplayStyle.iconAndTitle.showsLabels(width: 779, destinationCount: 7)
                && NavigationDisplayStyle.iconAndTitle.showsLabels(width: 780, destinationCount: 7)
                && !NavigationDisplayStyle.iconAndTitle.showsLabels(width: 759, destinationCount: 6)
                && NavigationDisplayStyle.iconAndTitle.showsLabels(width: 760, destinationCount: 6),
                "导航样式或宽度边界不正确")
    preferences.navigationDisplayStyle = .iconOnly
    try require(PreferencesStore(defaults: defaults).navigationDisplayStyle == .iconOnly, "显示方式未持久化")
    for (offset, destination) in destinations.enumerated() {
        controller.shellModel.selectDestination(destination)
        preferences.setDestinationEnabled(false, for: destination)
        let remaining = destinations.filter { $0 != destination }
        try require(PreferencesStore(defaults: defaults).enabledDestinations == remaining, "页面开关未独立持久化")
        try require(controller.shellModel.destination == remaining[0], "当前页关闭后没有回到首个启用页")
        defaults.set(destination.rawValue, forKey: "island.lastDestination")
        let restoredShell = IslandShellModel(preferences: preferences)
        try require(restoredShell.destination == remaining[0]
                    && defaults.string(forKey: "island.lastDestination") == remaining[0].rawValue,
                    "启动没有回落并写回首个启用页")
        for (index, page) in destinations.enumerated() {
            try require(controller.destinationForShortcut(String(index + 1)) == (index == offset ? nil : page),
                        "关闭页面后快捷键仍然有效，或启用页面的键位变化")
        }
        preferences.setDestinationEnabled(true, for: destination)
    }
    for last in destinations {
        preferences.resetNavigationPreferences()
        for destination in destinations where destination != last {
            preferences.setDestinationEnabled(false, for: destination)
        }
        preferences.setDestinationEnabled(false, for: last)
        if last == .terminal { preferences.terminalEnabled = false }
        if last == .quota { preferences.quotaEnabled = false }
        try require(!preferences.canDisableDestination(last) && preferences.enabledDestinations == [last]
                    && PreferencesStore(defaults: defaults).enabledDestinations == [last],
                    "最后一个页面可被关闭或拒绝后的状态未持久化")
    }
    for destination in destinations {
        let key: String
        switch destination {
        case .terminal: key = "module.terminalEnabled"
        case .quota: key = "module.quotaEnabled"
        default: key = "navigation.\(destination.rawValue)Enabled"
        }
        defaults.set(false, forKey: key)
    }
    defaults.set("invalid", forKey: "navigation.displayStyle")
    let repaired = PreferencesStore(defaults: defaults)
    try require(repaired.enabledDestinations == [.home] && defaults.bool(forKey: "navigation.homeEnabled")
                && repaired.navigationDisplayStyle == .iconAndTitle, "无有效页面或显示方式时没有恢复")
    preferences.navigationDisplayStyle = .iconOnly
    preferences.resetNavigationPreferences()
    let reset = PreferencesStore(defaults: defaults)
    try require(reset.enabledDestinations == destinations && reset.navigationDisplayStyle == .iconAndTitle,
                "恢复默认没有更新全部页面及显示方式")
    controller.shellModel.selectDestination(.home)

    try require(!controller.hasEventMonitors && !controller.shellModel.isTerminalSessionLoaded
                && !controller.shellModel.isQuotaMonitorLoaded && !home.isRecordingTranscriptionLoaded,
                "创建隐藏面板时提前注册监听或初始化终端、账号额度、录音转写")
    try require(!controller.shellModel.isTerminalChoosingFolder, "未打开的终端不应处于选文件夹状态")
    home.audioRecorder.onDidFinishRecording?(latestRecording)
    try require(!home.isRecordingTranscriptionLoaded, "未配置自动转写时完成录音提前初始化转写管理器")

    controller.showExpanded()
    try require(controller.hasEventMonitors, "展开后未注册事件监听")
    try require(!controller.shellModel.isQuotaMonitorLoaded, "展开首页时提前初始化账号额度")
    try require(!controller.applicationsModel.isLoading && controller.applicationsModel.applications.isEmpty,
                "隐藏最近使用组件后展开首页仍扫描了应用目录")
    try require(controller.panel.contentView?.layer?.cornerRadius == 30, "窗口外壳与玻璃圆角不一致")
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
    try require(!controller.hasEventMonitors && !controller.shellModel.isTerminalSessionLoaded && !home.isRecordingTranscriptionLoaded,
                "点击外部收起后仍保留监听，或隐藏路径提前初始化了终端、录音转写")
    try require(!controller.panel.isVisible, "备忘录打开时点击软件外部没有收起窗口：接受输入=\(!controller.panel.ignoresMouseEvents)，透明度=\(controller.panel.alphaValue)，设置=\(appModel.settingsOpen)，提示词编辑=\(appModel.prompts.promptEditorOpen)，复盘=\(home.dailyReviewHistoryOpen)")
    try require(home.memoLibraryOpen && home.memoLibrary.selectedID == memoID, "收起窗口重置了备忘录界面或选中记录")
    try require(defaults.string(forKey: "home.quickNote") == home.quickNote, "收起窗口没有保存便签")
    try require(MemoLibraryModel(fileURL: memoURL).selectedItem?.body == home.memoLibrary.selectedItem?.body, "收起窗口没有保存备忘录")
    controller.showExpanded()
    try require(home.memoLibraryOpen && home.memoLibrary.selectedID == memoID, "重新打开未保留收起前的备忘录界面")
    try require(controller.panel.frame.size == resized, "隐藏后重新打开未恢复尺寸")
    try requireCentered(controller.panel, "隐藏重开后")
    home.closeMemoLibrary()

    controller.showExpanded(destination: .prompts)
    appModel.prompts.promptEditorOpen = true
    appModel.prompts.promptDraftTitle = "未保存的标题"
    appModel.prompts.promptDraftBody = "未保存的提示词正文"
    controller.handleOutsideClick()
    finishWindowAnimation(controller.panel)
    try require(!controller.panel.isVisible, "提示词编辑时点击软件外部没有收起窗口")
    controller.showExpanded(destination: .prompts)
    try require(appModel.prompts.promptEditorOpen, "重新打开后提示词编辑界面未保留")
    try require(appModel.prompts.promptDraftTitle == "未保存的标题" && appModel.prompts.promptDraftBody == "未保存的提示词正文", "外部点击收起丢失未保存的提示词")
    appModel.prompts.promptEditorOpen = false

    do {
        let restored = PreferencesStore(defaults: UserDefaults(suiteName: suite)!)
        try require(restored.workspaceSize == resized, "重新读取偏好设置丢失尺寸")
        let reopenedHome = HomeDashboardModel(
            defaults: restored.defaults,
            memoLibrary: MemoLibraryModel(fileURL: directory.appendingPathComponent("Memos/reopened.json")),
            recordingsDirectory: recordings
        )
        let reopened = PanelController(model: AppModel(preferences: restored), preferences: restored, homeModel: reopenedHome,
                                       quotaMonitorFactory: { makePanelQuotaMonitor(in: directory) })
        defer {
            reopened.hide()
            reopened.panel.orderOut(nil)
        }
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
    }

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
    let hideDeadline = Date().addingTimeInterval(1)
    while controller.hasEventMonitors && Date() < hideDeadline {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    try require(!controller.hasEventMonitors, "完成刘海交互并收起后仍保留主面板监听")
    try require(!controller.shellModel.isTerminalSessionLoaded && !home.isRecordingTranscriptionLoaded,
                "打开首页、设置、提示词或进行刘海交互后，提前初始化了终端或录音转写")
    controller.showExpanded(destination: .home)
    home.restore(.recentApplications)
    try await Task.sleep(nanoseconds: 150_000_000)
    try require(controller.applicationsModel.isLoading || !controller.applicationsModel.applications.isEmpty,
                "在可见首页恢复最近使用组件后未按需加载应用")
    try require(!home.isRecordingTranscriptionLoaded && !controller.shellModel.isTerminalSessionLoaded,
                "首页渲染提前创建了录音转写或终端会话")
    try require(controller.panel.contentView.flatMap(findTerminalWebView(in:)) == nil, "未访问终端时挂载了 WKWebView")

    home.openRecordingWorkspace(selecting: latestRecording)
    guard let transcription = home.recordingTranscription else { throw PanelTestError.failed("打开录音工作台未创建转写管理器") }
    try require(home.recordingWorkspaceOpen && transcription.selectedRecordingURL == latestRecording,
                "首次打开录音工作台没有保留所选录音")
    try require(transcription.canDeleteRecording?(latestRecording) == true, "懒加载未绑定录音删除检查")
    let recordingDeadline = Date().addingTimeInterval(3)
    while transcription.recordings.isEmpty && Date() < recordingDeadline {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    guard let recordedURL = transcription.recordings.first?.url else {
        throw PanelTestError.failed("首次打开录音工作台未读取临时录音")
    }
    try transcription.deleteRecording(recordedURL)
    try require(home.audioRecorder.latestRecordingURL == nil, "懒加载未将删除结果同步给首页录音组件")
    home.closeRecordingWorkspace()
    controller.hide()
    finishWindowAnimation(controller.panel)

    defaults.set(ToolDestination.terminal.rawValue, forKey: "island.lastDestination")
    let restoredHome = HomeDashboardModel(defaults: defaults, memoLibrary: home.memoLibrary, recordingsDirectory: recordings)
    let restoredAppModel = AppModel(preferences: preferences)
    let restoredController = PanelController(model: restoredAppModel, preferences: preferences, homeModel: restoredHome,
                                             quotaMonitorFactory: { makePanelQuotaMonitor(in: directory) })
    defer { restoredController.panel.orderOut(nil) }
    restoredController.panel.contentView?.layoutSubtreeIfNeeded()
    try require(restoredController.shellModel.destination == .terminal && !restoredController.shellModel.isTerminalSessionLoaded,
                "恢复终端页偏好时提前实例化了终端会话")
    restoredController.showExpanded(openSettings: true)
    try await Task.sleep(nanoseconds: 150_000_000)
    try require(!restoredController.shellModel.isTerminalSessionLoaded, "仅打开设置时提前实例化了恢复的终端页")
    restoredAppModel.settingsOpen = false
    try await Task.sleep(nanoseconds: 150_000_000)
    let terminalSession = restoredController.shellModel.terminalSession
    let terminalView = restoredController.panel.contentView.flatMap(findTerminalWebView(in:))
    try require(terminalSession != nil && terminalView != nil, "首次显示终端页未挂载终端会话和 WKWebView")
    try require(!restoredController.applicationsModel.isLoading && restoredController.applicationsModel.applications.isEmpty,
                "从终端页恢复时提前扫描了应用目录")
    restoredController.showExpanded(destination: .applications)
    try require(restoredController.applicationsModel.isLoading || !restoredController.applicationsModel.applications.isEmpty,
                "进入应用页后未按需加载应用")
    restoredController.showExpanded(destination: .terminal)
    try require(restoredController.shellModel.terminalSession === terminalSession, "切出再进入终端页丢失了同一个会话")
    try require(restoredController.panel.contentView.flatMap(findTerminalWebView(in:)) === terminalView,
                "切出再进入终端页未复用 WKWebView")
    restoredController.hide()
    finishWindowAnimation(restoredController.panel)

    try await testClipboardIncrementalUpdates(preferences: preferences, directory: directory)
    try await testLibraryShortcuts(directory: directory)
    try await testQuotaPageRefresh(directory: directory)
    try await testModulePreferences(directory: directory)
    try require(UserDefaults.standard.string(forKey: "island.lastDestination") == standardDestinationBefore, "面板自检污染了用户默认偏好 island.lastDestination")
    print("PASS: 刘海几何与多屏定位；悬停开关、防误触、移入内容区、快速重开、中转面板；笔记保存与中文输入；窗口缩放；主窗与小兜双主题及跟随系统；按需加载、监听生命周期、额度页显示时刷新过期快照、剪贴板增量一致性、资料库快捷键与保存转页；模块开关、导航回落、资源释放与首页布局保留")
}

try await runTests()
