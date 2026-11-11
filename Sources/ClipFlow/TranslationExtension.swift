import AppKit
import Carbon
import SwiftUI
import Vision
import Translation

@MainActor
final class TranslationExtension: ObservableObject {
    private let defaults: UserDefaults
    private let installedKey = "extensions.translation.installed"
    private let enabledKey = "extensions.translation.enabled"
    private let historyKey = "extensions.translation.history"
    private let targetKey = "extensions.translation.target"
    @Published private(set) var installed: Bool
    @Published private(set) var running = false
    @Published var error: String?
    @Published var source = ""
    @Published var result = ""
    @Published var target: String { didSet { defaults.set(target, forKey: targetKey) } }
    @Published var requestID = 0
    @Published var history: [TranslationRecord]
    private var hotKey: HotKeyManager?
    private var session: CaptureSession?
    private var window: NSWindow?
    private var recognitionTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        installed = defaults.bool(forKey: installedKey)
        target = defaults.string(forKey: targetKey) ?? "zh-Hans"
        history = (try? JSONDecoder().decode([TranslationRecord].self, from: defaults.data(forKey: historyKey) ?? Data())) ?? []
    }
    func restore() { if installed && defaults.bool(forKey: enabledKey) { start() } }
    func install() { installed = true; defaults.set(true, forKey: installedKey); start() }
    func start() {
        guard installed, !running else { return }
        guard #available(macOS 15.0, *) else { error = "翻译扩展需要 macOS 15 或更高版本。"; return }
        do {
            hotKey = try HotKeyManager(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey), signature: 0x4A54524E, id: 1) { [weak self] in
                DispatchQueue.main.async { self?.capture() }
            }
            running = true; error = nil; defaults.set(true, forKey: enabledKey)
        } catch { self.error = "无法启动翻译扩展，⌃⌥S 可能已被占用。\(error.localizedDescription)"; defaults.set(false, forKey: enabledKey) }
    }
    func stop() {
        running = false; hotKey = nil; session?.cancel(); session = nil
        recognitionTask?.cancel(); recognitionTask = nil
        window?.close(); window = nil; defaults.set(false, forKey: enabledKey)
    }
    func uninstall() { stop(); installed = false; defaults.set(false, forKey: installedKey); error = nil }
    func show() {
        guard running else { return }
        if #available(macOS 15.0, *) {
            if window == nil {
                let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                panel.title = "截图识别与翻译"; panel.minSize = NSSize(width: 480, height: 440)
                panel.isReleasedWhenClosed = false; panel.level = .floating
                panel.contentView = NSHostingView(rootView: TranslationExtensionView(model: self))
                panel.center(); window = panel
            }
            NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
        }
    }
    func capture() {
        guard running, session == nil else { return }
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            error = "请在系统设置的“隐私与安全性 → 屏幕与系统音频录制”中允许 Jaimo Flow，然后重新启动应用。"
            show(); return
        }
        window?.orderOut(nil)
        let capture = CaptureSession { [weak self] image, _ in
            guard let self else { return }; self.session = nil
            guard self.running, let image else { return }
            self.recognize(image)
        }
        session = capture
        if !capture.start() { session = nil; error = "无法读取屏幕画面，请检查屏幕录制权限。"; show() }
    }
    func chooseImage() {
        let picker = NSOpenPanel(); picker.allowedContentTypes = [.image]; picker.allowsMultipleSelection = false
        if picker.runModal() == .OK, let url = picker.url, let image = NSImage(contentsOf: url) { recognize(image) }
    }
    func pasteInput() {
        if let image = NSImage(pasteboard: .general) { recognize(image) }
        else if let text = NSPasteboard.general.string(forType: .string) { source = text; translate() }
        else { error = "剪贴板中没有文字或图片。" }
    }
    func recognize(_ image: NSImage) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { error = "无法读取图片。"; show(); return }
        recognitionTask?.cancel(); error = nil; source = "正在识别文字…"; result = ""; show()
        recognitionTask = Task { [weak self] in
            do {
                let text = try await Task.detached(priority: .userInitiated) { () -> String in
                    let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true; request.recognitionLanguages = ["zh-Hans", "en-US"]
                    try VNImageRequestHandler(cgImage: cgImage).perform([request])
                    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                }.value
                guard !Task.isCancelled, let self, self.running else { return }
                self.source = text
                if text.isEmpty { self.error = "没有识别到文字，请调整选区或尝试更清晰的图片。" }
                else { self.translate() }
            } catch { guard !Task.isCancelled else { return }; self?.source = ""; self?.error = "文字识别失败：\(error.localizedDescription)" }
        }
    }
    func translate() {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "请输入需要翻译的文字。"; return }
        error = nil; result = ""; requestID += 1; show()
    }
    func saveResult(source: String, result: String, target: String) {
        history.insert(TranslationRecord(source: source, result: result, target: target, date: Date()), at: 0)
        if history.count > 100 { history.removeLast(history.count - 100) }
        persistHistory()
    }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    func deleteRecord(_ id: TranslationRecord.ID) { history.removeAll { $0.id == id }; persistHistory() }
    func clearHistory() { history.removeAll(); defaults.removeObject(forKey: historyKey) }
    private func persistHistory() {
        if history.isEmpty { defaults.removeObject(forKey: historyKey) }
        else if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: historyKey) }
    }
}

struct TranslationRecord: Codable, Identifiable {
    var id = UUID(); let source: String; let result: String; let target: String; let date: Date

    /// 按关键字过滤：忽略大小写与全半角差异，原文或译文任一包含即可；空关键字返回全部。
    static func filter(_ records: [TranslationRecord], query: String) -> [TranslationRecord] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return records }
        let options: String.CompareOptions = [.caseInsensitive, .widthInsensitive, .diacriticInsensitive]
        return records.filter { $0.source.range(of: keyword, options: options) != nil || $0.result.range(of: keyword, options: options) != nil }
    }
}

@available(macOS 15.0, *)
private struct TranslationExtensionView: View {
    @ObservedObject var model: TranslationExtension
    @State private var configuration: TranslationSession.Configuration?
    @State private var pendingSource = ""
    @State private var pendingTarget = ""
    @State private var pendingID = 0
    @State private var showHistory = false
    @State private var historyQuery = ""
    @State private var confirmClear = false
    private let languages = [("简体中文", "zh-Hans"), ("英语", "en"), ("日语", "ja"), ("韩语", "ko"), ("法语", "fr"), ("德语", "de"), ("西班牙语", "es")]
    private func languageName(_ code: String) -> String { languages.first { $0.1 == code }?.0 ?? code }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("截图识别") { model.capture() }
                Button("打开图片") { model.chooseImage() }
                Button("读取剪贴板") { model.pasteInput() }
                Spacer()
                Button(showHistory ? "返回" : "历史") { showHistory.toggle() }
            }
            if showHistory {
                HStack {
                    Text("翻译历史").font(.headline)
                    Text("\(model.history.count) 条").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("清空历史") { confirmClear = true }.disabled(model.history.isEmpty)
                }
                TextField("搜索原文或译文", text: $historyQuery).textFieldStyle(.roundedBorder)
                let records = TranslationRecord.filter(model.history, query: historyQuery)
                if records.isEmpty {
                    Text(model.history.isEmpty ? "还没有翻译记录。" : "没有匹配“\(historyQuery.trimmingCharacters(in: .whitespacesAndNewlines))”的记录。")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(records) { item in
                        Button { model.source = item.source; model.result = item.result; model.target = item.target; showHistory = false } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.source).lineLimit(2)
                                Text(item.result).foregroundStyle(.secondary).lineLimit(2)
                                Text("\(languageName(item.target)) · \(item.date.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.tertiary)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("点击载入这条记录，右键可复制或删除")
                        .contextMenu {
                            Button("复制原文") { model.copy(item.source) }
                            Button("复制译文") { model.copy(item.result) }
                            Divider()
                            Button("删除这条记录", role: .destructive) { model.deleteRecord(item.id) }
                        }
                    }
                }
            } else {
                HStack { Text("原文").font(.headline); Spacer(); Button("复制原文") { model.copy(model.source) } }
                TextEditor(text: $model.source).font(.system(size: 14)).frame(minHeight: 110).border(Color.secondary.opacity(0.2))
                HStack {
                    Text("翻译为")
                    Picker("目标语言", selection: $model.target) { ForEach(languages, id: \.1) { Text($0.0).tag($0.1) } }.labelsHidden().frame(width: 130)
                    Button("翻译") { model.translate() }.keyboardShortcut(.return, modifiers: .command)
                    Spacer(); Button("复制译文") { model.copy(model.result) }.disabled(model.result.isEmpty)
                }
                Text("译文").font(.headline)
                ScrollView { Text(model.result.isEmpty ? "译文将在这里显示" : model.result).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(model.result.isEmpty ? .secondary : .primary) }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if let error = model.error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            Text("截图快捷键 ⌃⌥S · 首次翻译时，系统可能提示下载语言资源。") .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .confirmationDialog("清空全部 \(model.history.count) 条翻译历史？", isPresented: $confirmClear) {
            Button("清空历史", role: .destructive) { model.clearHistory(); historyQuery = "" }
            Button("取消", role: .cancel) {}
        } message: { Text("清空后无法恢复。") }
        .onChange(of: model.requestID) { _ in
            pendingID = model.requestID; pendingSource = model.source; pendingTarget = model.target
            configuration = TranslationSession.Configuration(source: nil, target: Locale.Language(identifier: pendingTarget))
            configuration?.invalidate()
        }
        .translationTask(configuration) { session in
            let source = pendingSource, target = pendingTarget, id = pendingID
            do {
                let response = try await session.translate(source)
                guard id == model.requestID, model.running else { return }
                model.result = response.targetText; model.saveResult(source: source, result: response.targetText, target: target)
            } catch {
                guard id == model.requestID, model.running else { return }
                model.error = "翻译失败：\(error.localizedDescription)。请检查语言资源是否已下载。"
            }
        }
    }
}
