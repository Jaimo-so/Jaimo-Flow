import AppKit
import CTerminal
import Darwin
import SwiftUI
import WebKit

@MainActor
final class TerminalSession: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    @Published private(set) var isOpen = true
    @Published private(set) var hasSelection = false
    private var master: Int32 = -1
    private var child: pid_t = 0
    private var reader: DispatchSourceRead?
    private(set) lazy var webView: WKWebView = {
        let controller = WKUserContentController()
        controller.add(WeakTerminalHandler(target: self), name: "terminal")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Terminal") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return view
    }()

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any], let type = payload["type"] as? String else { return }
        switch type {
        case "ready":
            if isOpen && master < 0 { start() }
            resize(payload["value"])
        case "resize": resize(payload["value"])
        case "selection":
            hasSelection = payload["value"] as? Bool ?? false
        case "input":
            guard master >= 0, let value = payload["value"] as? String else { return }
            let bytes = Array(value.utf8)
            bytes.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(master, base.advanced(by: offset), buffer.count - offset)
                    if written <= 0 { break }
                    offset += written
                }
            }
        default: break
        }
    }

    private func start() {
        var fd: Int32 = -1
        let pid = jaimo_start_shell(&fd)
        guard pid > 0 else {
            display(Data("无法启动终端会话。\r\n".utf8))
            return
        }
        master = fd
        child = pid
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 16384)
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else {
                self?.stop()
                self?.isOpen = false
                self?.hasSelection = false
                self?.display(Data("\r\n会话已结束。\r\n".utf8))
                return
            }
            self?.display(Data(buffer.prefix(count)))
        }
        source.setCancelHandler { close(fd) }
        reader = source
        source.resume()
    }

    private func resize(_ value: Any?) {
        guard master >= 0, let size = value as? [String: Any],
              let cols = size["cols"] as? Int, let rows = size["rows"] as? Int,
              (2...1000).contains(cols), (1...1000).contains(rows) else { return }
        _ = jaimo_resize_terminal(master, UInt16(cols), UInt16(rows))
    }

    private func display(_ data: Data) {
        webView.evaluateJavaScript("window.terminalWrite('\(data.base64EncodedString())')", completionHandler: nil)
    }

    private func evaluate(_ script: String, completion: ((Any?) -> Void)? = nil) {
        webView.evaluateJavaScript(script) { result, _ in
            guard let completion else { return }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func copySelection() {
        evaluate("window.terminalCopySelection()") { result in
            guard let text = result as? String, !text.isEmpty else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    func pasteClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        evaluate("window.terminalPaste('\(Data(text.utf8).base64EncodedString())')")
    }

    func selectAllText() {
        evaluate("window.terminalSelectAll()")
    }

    func clearScreen() {
        evaluate("window.terminalClear()")
    }

    private func stop() {
        reader?.cancel()
        reader = nil
        master = -1
        if child > 0 {
            let pid = child
            child = 0
            DispatchQueue.global(qos: .utility).async { var status: Int32 = 0; _ = waitpid(pid, &status, 0) }
        }
    }

    func closeSession() {
        guard isOpen else { return }
        isOpen = false
        hasSelection = false
        webView.window?.makeFirstResponder(nil)
        if child > 0 { _ = kill(child, SIGHUP) }
        stop()
    }

    func openSession() {
        guard !isOpen else { return }
        isOpen = true
        hasSelection = false
        webView.reload()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
    }
}

struct TerminalWorkspace: View {
    @ObservedObject var session: TerminalSession
    let active: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var confirmClose = false

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        VStack(spacing: 0) {
            toolbar(theme)
            Rectangle().fill(theme.hairline).frame(height: 0.5)
            ZStack {
                TerminalView(session: session, active: active && session.isOpen)
                    .allowsHitTesting(session.isOpen)
                    .accessibilityHidden(!session.isOpen)
                if !session.isOpen {
                    Color(red: 0.098, green: 0.11, blue: 0.125)
                    VStack(spacing: 12) {
                        Text("终端会话已关闭")
                            .foregroundStyle(.white.opacity(0.75))
                        Button("重新打开终端") { session.openSession() }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onChange(of: session.isOpen) { open in
            if !open { confirmClose = false }
        }
    }

    private func toolbar(_ theme: ClipFlowTheme) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.muted)
            Text(session.isOpen ? "会话进行中" : "会话已关闭")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.muted)
            Spacer(minLength: 8)
            if session.isOpen {
                Button("复制选中") { session.copySelection() }
                    .buttonStyle(GlassButtonStyle(kind: .quiet))
                    .disabled(!session.hasSelection)
                    .help("复制选中的终端文本（⌘C）")
                    .accessibilityLabel("复制选中的终端文本")
                    .fixedSize()
                Button("粘贴") { session.pasteClipboard() }
                    .buttonStyle(GlassButtonStyle(kind: .quiet))
                    .help("将系统剪贴板粘贴到终端（⌘V）")
                    .accessibilityLabel("粘贴到终端")
                    .fixedSize()
                Button("清屏") { session.clearScreen() }
                    .buttonStyle(GlassButtonStyle(kind: .quiet))
                    .help("清空终端屏幕（⌘K），不影响正在运行的命令")
                    .accessibilityLabel("清空终端屏幕")
                    .fixedSize()
                Button(confirmClose ? "确认关闭" : "关闭终端") {
                    if confirmClose {
                        session.closeSession()
                        confirmClose = false
                    } else {
                        confirmClose = true
                    }
                }
                .buttonStyle(GlassButtonStyle(kind: confirmClose ? .danger : .quiet))
                .help(confirmClose ? "再次点击以结束当前会话及其正在运行的命令" : "结束当前终端会话")
                .accessibilityHint("点击后需要再次确认")
                .fixedSize()
                if confirmClose {
                    Button("取消") { confirmClose = false }
                        .buttonStyle(GlassButtonStyle(kind: .quiet))
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }
}

private final class WeakTerminalHandler: NSObject, WKScriptMessageHandler {
    weak var target: TerminalSession?
    init(target: TerminalSession) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

struct TerminalView: NSViewRepresentable {
    let session: TerminalSession
    let active: Bool
    func makeNSView(context: Context) -> WKWebView { session.webView }
    func updateNSView(_ view: WKWebView, context: Context) {
        if active {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }
}
