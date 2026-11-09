import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var preferences: PreferencesStore!
    private var model: AppModel!
    private var monitor: ClipboardMonitor!
    private var panelController: PanelController!
    private var topNotchController: TopNotchController!
    private var hotKeyManager: HotKeyManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        preferences = PreferencesStore()
        model = AppModel(preferences: preferences)
        monitor = ClipboardMonitor()
        panelController = PanelController(model: model, preferences: preferences)
        topNotchController = TopNotchController(panelController: panelController)
        let notchController = topNotchController!
        panelController.onVisibilityChanged = { [weak notchController] visible in
            notchController?.workspaceVisibilityChanged(visible)
        }

        model.clipboardMonitor = monitor
        monitor.isSourceExcluded = { [weak preferences] bundleID in
            preferences?.isExcluded(bundleID: bundleID) ?? false
        }
        monitor.onCapture = { [weak model] captured in
            model?.receive(captured)
        }
        model.updateManager.onUpdateAvailable = { [weak model] version in
            model?.showToast("发现新版本 \(version)，可在设置中一键更新")
        }

        do {
            hotKeyManager = try HotKeyManager { [weak panelController] in
                DispatchQueue.main.async { panelController?.toggleHotKey() }
            }
        } catch {
            model.showToast(error.localizedDescription)
        }

        model.screenshotExtension.restore()
        model.translationExtension.restore()
        model.load()
        monitor.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak model] in
            model?.updateManager.checkIfNeeded()
        }

        // 顶部刘海是常驻入口；隐藏设置独立于旧版悬浮球。
        topNotchController.showIfEnabled()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        panelController?.show()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        (panelController?.prepareForTermination() ?? true) ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        topNotchController?.hide()
        monitor?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
