import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var preferences: PreferencesStore!
    private var model: AppModel!
    private var monitor: ClipboardMonitor!
    private var panelController: PanelController!
    private var floatingBallController: FloatingBallController!
    private var statusController: StatusItemController!
    private var hotKeyManager: HotKeyManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        preferences = PreferencesStore()
        model = AppModel(preferences: preferences)
        monitor = ClipboardMonitor()
        panelController = PanelController(model: model, preferences: preferences)
        floatingBallController = FloatingBallController(panelController: panelController)
        let ballController = floatingBallController!
        panelController.onVisibilityChanged = { [weak ballController] visible in
            if visible {
                ballController?.prepareForWorkspacePresentation()
            } else {
                ballController?.restoreAfterWorkspaceHides()
            }
        }
        statusController = StatusItemController(
            panelController: panelController,
            floatingBallController: floatingBallController
        )

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

        model.load()
        monitor.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak model] in
            model?.updateManager.checkIfNeeded()
        }

        // 悬浮球是新的常驻入口；用户手动隐藏后不会在重启时强制恢复。
        floatingBallController.showIfEnabled()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        panelController?.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelController?.prepareForTermination()
        floatingBallController?.hideBall()
        monitor?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
