import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FileRelayItem: Codable, Identifiable, Equatable {
    let id: UUID
    let originalName: String
    let relativePath: String
    let isDirectory: Bool
    let byteSize: Int64
    let addedAt: Date
}

@MainActor
final class FileRelayModel: ObservableObject {
    @Published private(set) var items: [FileRelayItem] = []
    @Published private(set) var isImporting = false
    @Published var errorMessage: String?
    @Published var isDropTargeted = false
    @Published private(set) var noticeMessage: String?

    private var noticeWork: DispatchWorkItem?

    private let rootURL: URL
    private let indexURL: URL

    init(rootURL: URL? = nil) {
        let baseURL = rootURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
            .appendingPathComponent("ClipFlow", isDirectory: true)
            .appendingPathComponent("FileRelay", isDirectory: true)
        self.rootURL = baseURL
        indexURL = baseURL.appendingPathComponent("index.json")
        load()
    }

    var totalByteSize: Int64 {
        items.reduce(0) { $0 + $1.byteSize }
    }

    var storageSummary: String {
        ByteCountFormatter.string(fromByteCount: totalByteSize, countStyle: .file)
    }

    func storedURL(for item: FileRelayItem) -> URL {
        rootURL.appendingPathComponent(item.relativePath)
    }

    /// Whether a URL already lives inside the relay directory, e.g. a row
    /// dragged out of the panel and dropped straight back onto it.
    func isInsideRelay(_ url: URL) -> Bool {
        let rootPath = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    /// Case-insensitive match on the file name; every whitespace-separated
    /// keyword must appear so "报告 pdf" narrows like Finder search.
    nonisolated static func filter(_ items: [FileRelayItem], query: String) -> [FileRelayItem] {
        let keywords = query
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0) }
        guard !keywords.isEmpty else { return items }
        return items.filter { item in
            keywords.allSatisfy { item.originalName.localizedCaseInsensitiveContains($0) }
        }
    }

    func add(urls: [URL]) {
        let fileURLs = urls.filter { $0.isFileURL }
        let accepted = fileURLs.filter { !isInsideRelay($0) }
        if accepted.isEmpty, !fileURLs.isEmpty {
            showNotice("这些文件已经在中转站中")
            return
        }
        guard !accepted.isEmpty, !isImporting else { return }
        isImporting = true
        errorMessage = nil
        let rootURL = rootURL

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.importFiles(accepted, into: rootURL)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isImporting = false
                switch result {
                case .success(let imported):
                    self.items.insert(contentsOf: imported, at: 0)
                    self.persist()
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func remove(_ item: FileRelayItem) {
        let containerURL = rootURL.appendingPathComponent(item.id.uuidString, isDirectory: true)
        do {
            if FileManager.default.fileExists(atPath: containerURL.path) {
                try FileManager.default.removeItem(at: containerURL)
            }
            items.removeAll { $0.id == item.id }
            persist()
        } catch {
            errorMessage = "无法移除「\(item.originalName)」：\(error.localizedDescription)"
        }
    }

    func clearAll() {
        var remaining: [FileRelayItem] = []
        var lastError: Error?
        for item in items {
            let containerURL = rootURL.appendingPathComponent(item.id.uuidString, isDirectory: true)
            do {
                if FileManager.default.fileExists(atPath: containerURL.path) {
                    try FileManager.default.removeItem(at: containerURL)
                }
            } catch {
                remaining.append(item)
                lastError = error
            }
        }
        items = remaining
        persist()
        if let lastError {
            errorMessage = "部分文件无法清空：\(lastError.localizedDescription)"
        } else {
            errorMessage = nil
        }
    }

    func reveal(_ item: FileRelayItem) {
        guard let url = existingURL(for: item) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Opens the relay copy with its default application (folders open in Finder).
    func open(_ item: FileRelayItem) {
        guard let url = existingURL(for: item) else { return }
        if !NSWorkspace.shared.open(url) {
            errorMessage = "无法打开「\(item.originalName)」"
        }
    }

    /// Puts the relay copy on the pasteboard as a file, so ⌘V in Finder,
    /// Mail or chat apps pastes the file itself rather than its path.
    @discardableResult
    func copyFile(_ item: FileRelayItem, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let url = existingURL(for: item) else { return false }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([url as NSURL]) else {
            errorMessage = "无法拷贝「\(item.originalName)」"
            return false
        }
        showNotice("已拷贝「\(item.originalName)」，可在访达或聊天窗口粘贴")
        return true
    }

    @discardableResult
    func copyPath(_ item: FileRelayItem, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let url = existingURL(for: item) else { return false }
        pasteboard.clearContents()
        guard pasteboard.setString(url.path, forType: .string) else {
            errorMessage = "无法拷贝路径"
            return false
        }
        showNotice("已拷贝路径")
        return true
    }

    private func existingURL(for item: FileRelayItem) -> URL? {
        let url = storedURL(for: item)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "文件副本已经不存在，请移除此记录"
            return nil
        }
        errorMessage = nil
        return url
    }

    private func showNotice(_ message: String) {
        noticeWork?.cancel()
        noticeMessage = message
        let work = DispatchWorkItem { [weak self] in
            self?.noticeMessage = nil
            self?.noticeWork = nil
        }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func load() {
        do {
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
            guard FileManager.default.fileExists(atPath: indexURL.path) else { return }
            let data = try Data(contentsOf: indexURL)
            items = try JSONDecoder().decode([FileRelayItem].self, from: data)
                .filter { FileManager.default.fileExists(atPath: storedURL(for: $0).path) }
                .sorted { $0.addedAt > $1.addedAt }
        } catch {
            errorMessage = "无法读取文件中转站：\(error.localizedDescription)"
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(items).write(to: indexURL, options: .atomic)
        } catch {
            errorMessage = "无法保存文件中转记录：\(error.localizedDescription)"
        }
    }

    nonisolated private static func importFiles(
        _ urls: [URL],
        into rootURL: URL
    ) -> Result<[FileRelayItem], Error> {
        var imported: [FileRelayItem] = []
        do {
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
            for sourceURL in urls {
                let id = UUID()
                let containerURL = rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: containerURL,
                    withIntermediateDirectories: false,
                    attributes: nil
                )
                let destinationURL = containerURL.appendingPathComponent(sourceURL.lastPathComponent)
                do {
                    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                    let values = try sourceURL.resourceValues(forKeys: [.isDirectoryKey])
                    imported.append(
                        FileRelayItem(
                            id: id,
                            originalName: sourceURL.lastPathComponent,
                            relativePath: id.uuidString + "/" + sourceURL.lastPathComponent,
                            isDirectory: values.isDirectory == true,
                            byteSize: byteSize(at: destinationURL),
                            addedAt: Date()
                        )
                    )
                } catch {
                    try? FileManager.default.removeItem(at: containerURL)
                    throw error
                }
            }
            return .success(imported)
        } catch {
            for item in imported {
                let containerURL = rootURL.appendingPathComponent(item.id.uuidString, isDirectory: true)
                try? FileManager.default.removeItem(at: containerURL)
            }
            return .failure(error)
        }
    }

    nonisolated private static func byteSize(at url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }
}

struct FileRelayPanelView: View {
    @ObservedObject var model: FileRelayModel
    let onOpenWorkspace: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var clearArmed = false
    @State private var disarmWork: DispatchWorkItem?
    @State private var query = ""
    @State private var panelDropTargeted = false

    /// The search field only appears once the list is long enough to need it.
    private static let searchThreshold = 5

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("文件中转站")
                        .font(.system(size: 14, weight: .semibold))
                    Text("\(model.items.count) 项 · \(model.storageSummary) · 仅本机")
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.muted)
                        .monospacedDigit()
                }
                Spacer()
                Button(action: onOpenWorkspace) {
                    Label("打开工具站", systemImage: "rectangle.expand.vertical")
                }
                .buttonStyle(GlassButtonStyle(kind: .primary))
                .fixedSize()
            }
            .padding(14)

            Divider().overlay(theme.hairline)

            if model.items.count >= Self.searchThreshold {
                searchField(theme: theme)
                Divider().overlay(theme.hairline)
            }

            Group {
                if model.items.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "tray.and.arrow.down")
                            .font(.system(size: 26))
                            .foregroundStyle(theme.muted)
                        Text("把文件或文件夹拖到顶部刘海或这里")
                            .font(.system(size: 12.5, weight: .medium))
                        Text("Jaimo Flow 会保存独立副本，原文件不会移动或删除。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.muted)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 250)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if visibleItems.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 22))
                            .foregroundStyle(theme.muted)
                        Text("没有名称包含「\(query.trimmingCharacters(in: .whitespaces))」的文件")
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.muted)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 260)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(visibleItems) { item in
                                relayRow(item, theme: theme)
                            }
                        }
                        .padding(10)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if panelDropTargeted {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(theme.foreground.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .background(theme.chip.opacity(0.5).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)))
                        .overlay(
                            Label("松开即可放入中转站", systemImage: "tray.and.arrow.down")
                                .font(.system(size: 12, weight: .medium))
                        )
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [UTType.fileURL], isTargeted: $panelDropTargeted, perform: handlePanelDrop)

            if model.isImporting || model.errorMessage != nil || model.noticeMessage != nil {
                Divider().overlay(theme.hairline)
                HStack(spacing: 8) {
                    if model.isImporting { ProgressView().controlSize(.small) }
                    Text(model.isImporting ? "正在复制到本机中转目录…" : model.errorMessage ?? model.noticeMessage ?? "")
                        .font(.system(size: 10.5))
                        .foregroundStyle(model.errorMessage == nil ? theme.muted : theme.danger)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 35)
            }

            if !model.items.isEmpty {
                Divider().overlay(theme.hairline)
                HStack {
                    Text("双击打开 · 右键更多操作 · 拖出不会移除副本")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.muted)
                    Spacer()
                    Button(clearArmed ? "确认清空" : "清空") { handleClear() }
                        .buttonStyle(GlassButtonStyle(kind: clearArmed ? .danger : .normal))
                        .accessibilityHint("点击后需要再次确认")
                }
                .padding(.horizontal, 12)
                .frame(height: 42)
            }
        }
        .foregroundStyle(theme.foreground)
        .background(VisualEffectBackground())
        .background(theme.glass.opacity(0.96))
        .onDisappear(perform: disarmClear)
        .onChange(of: model.items.count) { count in
            if count < Self.searchThreshold { query = "" }
        }
    }

    private var visibleItems: [FileRelayItem] {
        FileRelayModel.filter(model.items, query: query)
    }

    private func searchField(theme: ClipFlowTheme) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(theme.muted)
            TextField("搜索中转文件…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .accessibilityLabel("搜索中转文件")
                .onExitCommand { query = "" }
            if !query.isEmpty {
                Text("\(visibleItems.count)/\(model.items.count)")
                    .font(.system(size: 9.5))
                    .foregroundStyle(theme.muted)
                    .monospacedDigit()
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(theme.chip)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func handlePanelDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !fileProviders.isEmpty else { return false }
        let model = model
        let collector = DroppedURLCollector()
        let group = DispatchGroup()
        for provider in fileProviders {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { collector.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = collector.urls
            guard !urls.isEmpty else { return }
            MainActor.assumeIsolated { model.add(urls: urls) }
        }
        return true
    }

    private func relayRow(_ item: FileRelayItem, theme: ClipFlowTheme) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: model.storedURL(for: item).path))
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.originalName)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Text("\(ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file)) · \(item.addedAt.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { model.copyFile(item) } label: {
                Image(systemName: "doc.on.doc")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(IslandRelayIconButtonStyle())
            .help("拷贝文件，可直接粘贴到访达或聊天窗口")
            .accessibilityLabel("拷贝 \(item.originalName)")
            Button { model.reveal(item) } label: {
                Image(systemName: "folder")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(IslandRelayIconButtonStyle())
            .accessibilityLabel("在访达中显示 \(item.originalName)")
            Button { model.remove(item) } label: {
                Image(systemName: "xmark")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(IslandRelayIconButtonStyle(danger: true))
            .accessibilityLabel("从中转站移除 \(item.originalName)")
        }
        .padding(8)
        .background(theme.chip)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture(count: 2) { model.open(item) }
        .contextMenu {
            Button(item.isDirectory ? "在访达中打开" : "打开") { model.open(item) }
            Button("拷贝文件") { model.copyFile(item) }
            Button("拷贝路径") { model.copyPath(item) }
            Button("在访达中显示") { model.reveal(item) }
            Divider()
            Button("从中转站移除") { model.remove(item) }
        }
        .onDrag {
            NSItemProvider(contentsOf: model.storedURL(for: item)) ?? NSItemProvider()
        }
        .accessibilityHint("双击打开，可拖到访达或其他应用，右键查看更多操作")
        .accessibilityAction(named: "打开") { model.open(item) }
        .accessibilityAction(named: "拷贝文件") { model.copyFile(item) }
    }

    private func handleClear() {
        if clearArmed {
            disarmClear()
            model.clearAll()
            return
        }
        clearArmed = true
        let work = DispatchWorkItem { disarmClear() }
        disarmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func disarmClear() {
        disarmWork?.cancel()
        disarmWork = nil
        clearArmed = false
    }
}

/// Gathers URLs that NSItemProvider delivers on background queues.
private final class DroppedURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        storage.append(url)
        lock.unlock()
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private struct IslandRelayIconButtonStyle: ButtonStyle {
    var danger = false
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        configuration.label
            .foregroundStyle(danger ? theme.danger : theme.muted)
            .background(configuration.isPressed ? (danger ? theme.danger.opacity(0.18) : theme.chipHigh) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
