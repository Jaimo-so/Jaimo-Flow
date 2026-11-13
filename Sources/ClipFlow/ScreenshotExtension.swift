import AppKit
import Carbon
import UniformTypeIdentifiers
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
        view.baseSize = size
        view.zoom = scale
        view.onCloseAll = { [weak self] in self?.closeAllPins() }
        view.imageScaling = .scaleProportionallyUpOrDown
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        windows.append(panel)
        panel.orderFrontRegardless()
    }

    /// Closes every pinned image at once, used by the pin context menu.
    func closeAllPins() {
        windows.forEach { $0.close() }
        windows.removeAll()
    }
}

/// A floating pinned screenshot. Supports dragging, double-click to close, scroll / pinch to zoom
/// around the pointer, opacity presets and saving as PNG from the context menu.
final class PinnedImageView: NSImageView {
    /// The image's natural size in points; zoom is expressed relative to it.
    var baseSize: NSSize = .zero
    var zoom: CGFloat = 1
    var onCloseAll: (() -> Void)?
    static let minZoom: CGFloat = 0.1
    static let maxZoom: CGFloat = 5
    static let opacityPresets: [CGFloat] = [1, 0.8, 0.6, 0.4]

    private lazy var zoomLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        label.layer?.cornerRadius = 6
        label.isHidden = true
        addSubview(label)
        return label
    }()
    private var hideLabelWork: DispatchWorkItem?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 { window?.close() }
        else { window?.performDrag(with: event) }
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        guard delta != 0 else { return }
        // Scrolling up enlarges, matching common image viewers; ~1% per point of precise scroll.
        let factor = pow(1.01, delta)
        applyZoom(zoom * factor, anchor: event.locationInWindow)
    }

    override func magnify(with event: NSEvent) {
        applyZoom(zoom * (1 + event.magnification), anchor: event.locationInWindow)
    }

    /// Clamps a requested zoom level to the supported range.
    static func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(maxZoom, max(minZoom, value))
    }

    /// Resizes the pin window to `newZoom`, keeping the point under `anchor` (window coordinates) fixed.
    func applyZoom(_ newZoom: CGFloat, anchor: NSPoint? = nil) {
        guard let window, baseSize.width > 0, baseSize.height > 0 else { return }
        let target = Self.clampedZoom(newZoom)
        guard abs(target - zoom) > 0.0001 else { showZoomLabel(); return }
        let old = window.frame
        let newSize = NSSize(width: max(24, baseSize.width * target), height: max(24, baseSize.height * target))
        let point = anchor ?? NSPoint(x: old.width / 2, y: old.height / 2)
        let rx = old.width > 0 ? point.x / old.width : 0.5
        let ry = old.height > 0 ? point.y / old.height : 0.5
        let origin = NSPoint(x: old.minX + point.x - newSize.width * rx,
                             y: old.minY + point.y - newSize.height * ry)
        zoom = target
        window.setFrame(NSRect(origin: origin, size: newSize), display: true)
        showZoomLabel()
    }

    private func showZoomLabel() {
        zoomLabel.stringValue = "\(Int((zoom * 100).rounded()))%"
        zoomLabel.sizeToFit()
        let size = NSSize(width: zoomLabel.frame.width + 14, height: zoomLabel.frame.height + 6)
        zoomLabel.frame = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                 width: size.width, height: size.height)
        zoomLabel.isHidden = false
        hideLabelWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.zoomLabel.isHidden = true }
        hideLabelWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "复制图片", action: #selector(copyImage), keyEquivalent: "")
        menu.addItem(withTitle: "另存为 PNG…", action: #selector(saveImage), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "放大", action: #selector(zoomIn), keyEquivalent: "")
        menu.addItem(withTitle: "缩小", action: #selector(zoomOut), keyEquivalent: "")
        let actual = menu.addItem(withTitle: "实际大小（100%）", action: #selector(actualSize), keyEquivalent: "")
        actual.state = abs(zoom - 1) < 0.005 ? .on : .off
        let opacityItem = NSMenuItem(title: "不透明度", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        let current = window?.alphaValue ?? 1
        for value in Self.opacityPresets {
            let item = NSMenuItem(title: "\(Int(value * 100))%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.representedObject = value
            item.target = self
            item.state = abs(current - value) < 0.01 ? .on : .off
            opacityMenu.addItem(item)
        }
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "关闭贴图", action: #selector(closePin), keyEquivalent: "")
        menu.addItem(withTitle: "关闭所有贴图", action: #selector(closeAll), keyEquivalent: "")
        for item in menu.items where item.action != nil { item.target = self }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func copyImage() {
        guard let image else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    @objc private func saveImage() {
        guard let image, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "贴图 \(formatter.string(from: Date())).png"
        panel.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    @objc private func zoomIn() { applyZoom(zoom * 1.25) }
    @objc private func zoomOut() { applyZoom(zoom / 1.25) }
    @objc private func actualSize() { applyZoom(1) }
    @objc private func setOpacity(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? CGFloat else { return }
        window?.alphaValue = value
    }
    @objc private func closePin() { window?.close() }
    @objc private func closeAll() { onCloseAll?() }
}
