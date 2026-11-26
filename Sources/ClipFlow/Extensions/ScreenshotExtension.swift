import AppKit
import Carbon
import SwiftUI

/// The first bundled extension. Installation and running state are stored independently.
@MainActor
final class ScreenshotExtension: ObservableObject {
    private let defaults: UserDefaults
    private let installedKey = "extensions.screenshot.installed"
    private let enabledKey = "extensions.screenshot.enabled"
    @Published private(set) var installed: Bool
    @Published private(set) var running = false
    @Published private(set) var error: String?
    struct Shortcut: Equatable {
        let keyCode: UInt32
        let modifiers: UInt32
        let keyLabel: String

        var label: String {
            var result = ""
            if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
            if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
            if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
            if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
            return result + keyLabel
        }
    }
    enum ShortcutAction { case capture, pin }
    @Published private(set) var captureShortcut: Shortcut
    @Published private(set) var pinShortcut: Shortcut
    private var captureHotKey: HotKeyManager?
    private var pinHotKey: HotKeyManager?
    private var windows: [NSWindow] = []
    private var captureSession: CaptureSession?
    private var recording = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        installed = defaults.bool(forKey: installedKey)
        captureShortcut = Self.loadShortcut(defaults, key: "extensions.screenshot.captureShortcut", fallback: Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey | optionKey), keyLabel: "A"))
        pinShortcut = Self.loadShortcut(defaults, key: "extensions.screenshot.pinShortcut", fallback: Shortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey), keyLabel: "P"))
    }

    func restore() {
        if installed && defaults.bool(forKey: enabledKey) { start() }
    }

    func install() {
        installed = true
        defaults.set(true, forKey: installedKey)
        start()
    }

    func start() {
        guard installed, !running else { return }
        do {
            let capture = try HotKeyManager(keyCode: captureShortcut.keyCode, modifiers: captureShortcut.modifiers, signature: 0x4A534E50, id: 1) { [weak self] in
                DispatchQueue.main.async { self?.capture(pin: false) }
            }
            let pin = try HotKeyManager(keyCode: pinShortcut.keyCode, modifiers: pinShortcut.modifiers, signature: 0x4A534E50, id: 2) { [weak self] in
                DispatchQueue.main.async { self?.pinClipboard() }
            }
            captureHotKey = capture
            pinHotKey = pin
            running = true
            error = nil
            defaults.set(true, forKey: enabledKey)
        } catch {
            captureHotKey = nil
            pinHotKey = nil
            defaults.set(false, forKey: enabledKey)
            self.error = "无法启动截图扩展：快捷键可能已被占用。\(error.localizedDescription)"
        }
    }

    private static func loadShortcut(_ defaults: UserDefaults, key: String, fallback: Shortcut) -> Shortcut {
        guard let value = defaults.dictionary(forKey: key),
              let code = value["keyCode"] as? Int, let modifiers = value["modifiers"] as? Int,
              let label = value["keyLabel"] as? String else { return fallback }
        return Shortcut(keyCode: UInt32(code), modifiers: UInt32(modifiers), keyLabel: label)
    }

    func setShortcut(_ shortcut: Shortcut, for action: ShortcutAction) {
        let other = action == .capture ? pinShortcut : captureShortcut
        guard shortcut.keyCode != other.keyCode || shortcut.modifiers != other.modifiers else {
            error = "截图和贴图不能使用相同的快捷键。"
            return
        }
        let old = action == .capture ? captureShortcut : pinShortcut
        if shortcut.keyCode == old.keyCode && shortcut.modifiers == old.modifiers { error = nil; return }
        do {
            let manager = try HotKeyManager(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers,
                                            signature: 0x4A534E50, id: action == .capture ? 1 : 2) { [weak self] in
                DispatchQueue.main.async {
                    if action == .capture { self?.capture() } else { self?.pinClipboard() }
                }
            }
            if action == .capture {
                captureShortcut = shortcut
                if running { captureHotKey = manager }
            } else {
                pinShortcut = shortcut
                if running { pinHotKey = manager }
            }
            defaults.set(["keyCode": Int(shortcut.keyCode), "modifiers": Int(shortcut.modifiers), "keyLabel": shortcut.keyLabel],
                         forKey: action == .capture ? "extensions.screenshot.captureShortcut" : "extensions.screenshot.pinShortcut")
            error = nil
        } catch {
            self.error = "快捷键设置失败，可能已被占用。原快捷键保持不变。"
        }
    }

    func beginShortcutRecording() {
        recording = true
        captureHotKey = nil
        pinHotKey = nil
    }

    func endShortcutRecording() {
        guard recording else { return }
        recording = false
        guard running else { return }
        running = false
        start()
    }

    func stop() {
        captureHotKey = nil
        pinHotKey = nil
        captureSession?.cancel()
        captureSession = nil
        running = false
        defaults.set(false, forKey: enabledKey)
        windows.forEach { $0.close() }
        windows.removeAll()
    }

    func uninstall() {
        stop()
        installed = false
        defaults.set(false, forKey: installedKey)
        error = nil
    }

    func capture(pin: Bool = false) {
        guard running, captureSession == nil else { return }
        error = nil
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            error = "请在系统设置的“隐私与安全性 → 屏幕与系统音频录制”中允许 Jaimo Flow，然后重新启动应用。"
            let alert = NSAlert()
            alert.messageText = "需要屏幕录制权限"
            alert.informativeText = error ?? ""
            alert.addButton(withTitle: "知道了")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        let session = CaptureSession { [weak self] image, shouldPin in
            guard let self else { return }
            self.captureSession = nil
            guard self.running, let image else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
            if pin || shouldPin { self.showPin(image) }
        }
        captureSession = session
        if !session.start() {
            captureSession = nil
            error = "无法读取屏幕画面，请检查屏幕录制权限。"
        }
    }

    func pinClipboard() {
        guard running else { return }
        guard let image = NSImage(pasteboard: .general) else {
            error = "剪贴板中没有图片，请先截图或复制图片。"
            return
        }
        error = nil
        showPin(image)
    }

    private func showPin(_ image: NSImage) {
        windows.removeAll { !$0.isVisible }
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = min(1, visible.width * 0.8 / size.width, visible.height * 0.8 / size.height)
        let frame = NSRect(x: visible.midX - size.width * scale / 2, y: visible.midY - size.height * scale / 2, width: size.width * scale, height: size.height * scale)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        let view = PinnedImageView(frame: NSRect(origin: .zero, size: frame.size))
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        windows.append(panel)
        panel.orderFrontRegardless()
    }
}

private final class PinnedImageView: NSImageView {
    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 { window?.close() }
        else { window?.performDrag(with: event) }
    }
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "复制图片", action: #selector(copyImage), keyEquivalent: "")
        menu.addItem(withTitle: "关闭贴图", action: #selector(closePin), keyEquivalent: "")
        for item in menu.items { item.target = self }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func copyImage() {
        guard let image else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
    @objc private func closePin() { window?.close() }
}
