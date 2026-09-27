import AppKit

@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panelController: PanelController
    private let floatingBallController: FloatingBallController

    init(panelController: PanelController, floatingBallController: FloatingBallController) {
        self.panelController = panelController
        self.floatingBallController = floatingBallController
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "circle.grid.2x2.fill", accessibilityDescription: "Jaimo Flow")
            button.image?.isTemplate = true
            button.toolTip = "Jaimo Flow 个人工具站 · ⌥Space"
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else {
            panelController.toggle()
            return
        }
        if event.type == .rightMouseUp {
            showMenu()
        } else {
            panelController.toggle()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let show = NSMenuItem(title: "显示 Jaimo Flow 工具站", action: #selector(showPanel), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let floatingBallTitle = floatingBallController.isEnabled ? "隐藏悬浮球" : "显示悬浮球"
        let floatingBall = NSMenuItem(
            title: floatingBallTitle,
            action: #selector(toggleFloatingBall),
            keyEquivalent: ""
        )
        floatingBall.target = self
        menu.addItem(floatingBall)
        let update = NSMenuItem(title: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        menu.addItem(update)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Jaimo Flow", action: #selector(quitApplication), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func showPanel() {
        panelController.show()
    }

    @objc private func checkForUpdates() {
        panelController.showUpdateSettings()
    }

    @objc private func toggleFloatingBall() {
        floatingBallController.toggleBallVisibility()
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }
}
