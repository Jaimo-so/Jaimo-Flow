import AppKit
import CTerminal
import Darwin
import SwiftUI
import WebKit

@MainActor
final class TerminalSession: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    @Published private(set) var isOpen = false
    @Published private(set) var hasOpenedSession = false
    private(set) var isChoosingFolder = false
    private var workingDirectory: URL?
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
        guard let workingDirectory else { return }
        let pid = workingDirectory.path.withCString { jaimo_start_shell(&fd, $0) }
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
        webView.window?.makeFirstResponder(nil)
        if child > 0 { _ = kill(child, SIGHUP) }
        stop()
    }

    func chooseFolderAndOpen() {
        guard !isOpen, !isChoosingFolder else { return }
        isChoosingFolder = true
        defer { isChoosingFolder = false }
        let panel = NSOpenPanel()
        panel.title = "选择终端打开的文件夹"
        panel.prompt = "打开终端"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        workingDirectory = folder
        openSession()
    }

    private func openSession() {
        guard !isOpen, workingDirectory != nil else { return }
        hasOpenedSession = true
        isOpen = true
        webView.reload()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
    }
}

struct TerminalWorkspace: View {
    @ObservedObject var session: TerminalSession
    let active: Bool
    @State private var confirmingClose = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TerminalView(session: session, active: active && session.isOpen && !confirmingClose)
                .allowsHitTesting(session.isOpen)
                .accessibilityHidden(!session.isOpen)
            if session.isOpen {
                Button("关闭终端") { confirmingClose = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
                    .help("结束当前终端会话")
                    .padding(12)
            } else {
                Color(red: 0.098, green: 0.11, blue: 0.125)
                VStack(spacing: 12) {
                    Text(session.hasOpenedSession ? "终端会话已关闭" : "选择一个文件夹，在其中打开终端")
                        .foregroundStyle(.white.opacity(0.75))
                    Button(session.hasOpenedSession ? "重新打开终端" : "选择文件夹") {
                        session.chooseFolderAndOpen()
                    }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert("关闭终端？", isPresented: $confirmingClose) {
            Button("取消", role: .cancel) { }
            Button("关闭终端", role: .destructive) { session.closeSession() }
        } message: {
            Text("关闭终端会结束当前会话，正在运行的命令可能会被中断。")
        }
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
