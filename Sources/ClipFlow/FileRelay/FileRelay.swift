import AppKit
import ClipFlowKit
import SwiftUI
import UniformTypeIdentifiers
import QuickLookThumbnailing
import Quartz

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
    @Published var statusMessage: String?
    private var statusWork: DispatchWorkItem?
    @Published var isDropTargeted = false
    @Published var isPinned = false
    @Published var isDraggingOut = false
    @Published var removeAfterDrag: Bool {
        didSet { defaults.set(removeAfterDrag, forKey: "fileRelay.removeAfterDrag") }
    }
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]
    private let defaults: UserDefaults

    private let rootURL: URL
    private let indexStore: JSONFileStore<[FileRelayItem]>
    private var pendingImports: [[URL]] = []

    init(rootURL: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.removeAfterDrag = defaults.bool(forKey: "fileRelay.removeAfterDrag")
        let baseURL = rootURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
            .appendingPathComponent("ClipFlow", isDirectory: true)
            .appendingPathComponent("FileRelay", isDirectory: true)
        self.rootURL = baseURL
        indexStore = JSONFileStore(fileURL: baseURL.appendingPathComponent("index.json"))
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

    func add(urls: [URL]) {
        let accepted = urls.filter { $0.isFileURL }
        guard !accepted.isEmpty else { return }
        if !isImporting && pendingImports.isEmpty { errorMessage = nil }
        pendingImports.append(accepted)
        processNextImport()
    }

    private func processNextImport() {
        guard !isImporting, !pendingImports.isEmpty else { return }
        let accepted = pendingImports.removeFirst()
        isImporting = true
        let rootURL = rootURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.importFiles(accepted, into: rootURL)
            DispatchQueue.main.async {
                guard let self else { return }
                self.items.insert(contentsOf: result.items, at: 0)
                if !result.items.isEmpty { self.persist() }
                if !result.errors.isEmpty {
                    let failure = "部分文件无法导入：" + result.errors.joined(separator: "；")
                    self.errorMessage = [self.errorMessage, failure].compactMap { $0 }.joined(separator: "；")
                }
                self.isImporting = false
                self.processNextImport()
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
            thumbnails.removeValue(forKey: item.id)
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
        let remainingIDs = Set(remaining.map(\.id))
        thumbnails = thumbnails.filter { remainingIDs.contains($0.key) }
        persist()
        if let lastError {
            errorMessage = "部分文件无法清空：\(lastError.localizedDescription)"
        } else {
            errorMessage = nil
        }
    }

    func copy(_ item: FileRelayItem) {
        let url = storedURL(for: item)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "文件副本已经不存在，请移除此记录"
            return
        }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.writeObjects([url as NSURL]) {
            errorMessage = nil
            showStatus("已复制文件")
        } else {
            errorMessage = "无法复制文件"
        }
    }

    private func showStatus(_ message: String) {
        statusWork?.cancel()
        statusMessage = message
        let work = DispatchWorkItem { [weak self] in self?.statusMessage = nil }
        statusWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func thumbnail(for item: FileRelayItem) {
        guard thumbnails[item.id] == nil else { return }
        let request = QLThumbnailGenerator.Request(fileAt: storedURL(for: item), size: CGSize(width: 96, height: 70), scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let image = representation?.nsImage else { return }
            DispatchQueue.main.async {
                guard let self, self.items.contains(where: { $0.id == item.id }) else { return }
                self.thumbnails[item.id] = image
            }
        }
    }

    func reveal(_ item: FileRelayItem) {
        let url = storedURL(for: item)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "文件副本已经不存在，请移除此记录"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func load() {
        do {
            try indexStore.prepareDirectory()
            guard indexStore.exists else { return }
            items = try indexStore.load()
                .filter { FileManager.default.fileExists(atPath: storedURL(for: $0).path) }
                .sorted { $0.addedAt > $1.addedAt }
        } catch {
            errorMessage = "无法读取文件中转站：\(error.localizedDescription)"
        }
    }

    private func persist() {
        do {
            try indexStore.save(items)
        } catch {
            errorMessage = "无法保存文件中转记录：\(error.localizedDescription)"
        }
    }

    nonisolated private static func importFiles(
        _ urls: [URL], into rootURL: URL
    ) -> (items: [FileRelayItem], errors: [String]) {
        var imported: [FileRelayItem] = []
        var errors: [String] = []
        for sourceURL in urls {
            let id = UUID()
            let containerURL = rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
                let destinationURL = containerURL.appendingPathComponent(sourceURL.lastPathComponent)
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                let values = try sourceURL.resourceValues(forKeys: [.isDirectoryKey])
                imported.append(FileRelayItem(id: id, originalName: sourceURL.lastPathComponent,
                    relativePath: id.uuidString + "/" + sourceURL.lastPathComponent,
                    isDirectory: values.isDirectory == true, byteSize: byteSize(at: destinationURL), addedAt: Date()))
            } catch {
                try? FileManager.default.removeItem(at: containerURL)
                errors.append("\(sourceURL.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        return (imported, errors)
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

@MainActor
final class RelayPreview: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = RelayPreview()
    private var url: URL?
    @discardableResult
    func show(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return false }
        panel.dataSource = self
        panel.reloadData()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        return true
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { url as NSURL? }
}

struct RelayDragHandle: NSViewRepresentable {
    let model: FileRelayModel
    let items: [FileRelayItem]
    let label: String
    var onContextMenuChanged: ((Bool) -> Void)?

    func makeNSView(context: Context) -> RelayDragView { RelayDragView() }
    func updateNSView(_ view: RelayDragView, context: Context) {
        view.model = model
        view.items = items
        view.onContextMenuChanged = onContextMenuChanged
        view.setAccessibilityLabel(label)
    }
}

final class RelayDragView: NSView, NSDraggingSource {
    weak var model: FileRelayModel?
    var items: [FileRelayItem] = []
    var onContextMenuChanged: ((Bool) -> Void)?
    private var start: NSPoint?
    private var draggedItems: [FileRelayItem] = []

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let model, let first = items.first {
            start = nil
            RelayPreview.shared.show(model.storedURL(for: first))
            return
        }
        start = event.locationInWindow
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let model, let item = items.first else { return }
        onContextMenuChanged?(true)
        defer { onContextMenuChanged?(false) }

        let menu = NSMenu()
        let previewItem = NSMenuItem(title: "预览", action: #selector(previewFirst), keyEquivalent: "")
        previewItem.target = self
        menu.addItem(previewItem)

        let copyItem = NSMenuItem(title: "复制文件", action: #selector(copyFirst), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        let revealItem = NSMenuItem(title: "在访达中显示", action: #selector(revealFirst), keyEquivalent: "")
        revealItem.target = self
        menu.addItem(revealItem)

        menu.addItem(.separator())

        let removeItem = NSMenuItem(title: "移除「\(item.originalName)」", action: #selector(removeFirst), keyEquivalent: "")
        removeItem.target = self
        menu.addItem(removeItem)

        if model.items.count > 1 {
            let clearItem = NSMenuItem(title: "清空全部", action: #selector(clearAllItems), keyEquivalent: "")
            clearItem.target = self
            menu.addItem(clearItem)
        }

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func previewFirst() {
        guard let model, let item = items.first else { return }
        RelayPreview.shared.show(model.storedURL(for: item))
    }

    @objc private func copyFirst() {
        guard let model, let item = items.first else { return }
        model.copy(item)
    }

    @objc private func revealFirst() {
        guard let model, let item = items.first else { return }
        model.reveal(item)
    }

    @objc private func removeFirst() {
        guard let model, let item = items.first else { return }
        model.remove(item)
    }

    @objc private func clearAllItems() {
        model?.clearAll()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 3,
              let model, !items.isEmpty else { return }
        self.start = nil
        let existingItems = items.filter { FileManager.default.fileExists(atPath: model.storedURL(for: $0).path) }
        guard !existingItems.isEmpty else {
            model.errorMessage = "文件副本已经不存在，请移除此记录"
            return
        }
        if existingItems.count != items.count { model.errorMessage = "部分文件副本已经不存在，无法拖出" }
        let point = convert(event.locationInWindow, from: nil)
        let dragging = existingItems.enumerated().map { index, item -> NSDraggingItem in
            let url = model.storedURL(for: item)
            let drag = NSDraggingItem(pasteboardWriter: url as NSURL)
            let offset = CGFloat(min(index, 4)) * 4
            drag.setDraggingFrame(NSRect(x: point.x - 20 + offset, y: point.y - 20 - offset, width: 40, height: 40),
                                  contents: model.thumbnails[item.id] ?? NSWorkspace.shared.icon(forFile: url.path))
            return drag
        }
        draggedItems = existingItems
        model.isDraggingOut = true
        beginDraggingSession(with: dragging, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard let model else { return }
        model.isDraggingOut = false
        if !operation.isEmpty && model.removeAfterDrag { for item in draggedItems { model.remove(item) } }
        draggedItems = []
    }
}

struct FileRelayAppearanceView: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var model: FileRelayModel
    var onContextMenuChanged: ((Bool) -> Void)?
    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        FileRelayPanelView(model: model, onContextMenuChanged: onContextMenuChanged)
            .environment(\.colorScheme, preferences.appearance.colorScheme ?? systemColorScheme)
    }
}

struct FileRelayPanelView: View {
    @ObservedObject var model: FileRelayModel
    var onContextMenuChanged: ((Bool) -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    private let earRadius: CGFloat = 18
    private let bottomRadius: CGFloat = 22

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        let pocketShape = RelayPocketShape(earRadius: earRadius, bottomRadius: bottomRadius)
        let borderShape = RelayPocketBorderShape(earRadius: earRadius, bottomRadius: bottomRadius)

        ZStack {
            FlowWindowBackground(theme: theme)
            if model.isDropTargeted {
                theme.accentWash
            }

            if model.items.isEmpty {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(model.isDropTargeted ? theme.accent : theme.muted.opacity(0.75))
                    .accessibilityLabel("拖入文件")
            } else {
                GeometryReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(model.items) { item in
                                fileTile(item, theme: theme)
                            }
                        }
                        .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .center)
                    }
                }
                .padding(.horizontal, earRadius + 10)
                .padding(.vertical, 10)
            }

            if model.isImporting {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, earRadius + 10)
                    .padding(.bottom, 10)
            }
        }
        .foregroundStyle(theme.foreground)
        .clipShape(pocketShape)
        .overlay(
            borderShape
                .stroke(
                    model.isDropTargeted ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.highlight),
                    lineWidth: model.isDropTargeted ? 1.5 : 1
                )
                .allowsHitTesting(false)
        )
    }

    private func fileTile(_ item: FileRelayItem, theme: ClipFlowTheme) -> some View {
        let thumbnail = model.thumbnails[item.id]
        let icon = thumbnail ?? NSWorkspace.shared.icon(forFile: model.storedURL(for: item).path)

        return VStack(spacing: 4) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: thumbnail == nil ? 0 : 6, style: .continuous))
            Text(item.originalName)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 66)
        }
        .frame(width: 68, height: 68)
        .contentShape(Rectangle())
        .overlay(
            RelayDragHandle(
                model: model,
                items: [item],
                label: "拖出 \(item.originalName)",
                onContextMenuChanged: onContextMenuChanged
            )
        )
        .onAppear { model.thumbnail(for: item) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.originalName)
        .accessibilityHint("拖出文件或右键查看更多操作")
    }
}

struct RelayPocketShape: Shape {
    var earRadius: CGFloat = 18
    var bottomRadius: CGFloat = 22

    func path(in rect: CGRect) -> Path {
        let ear = min(earRadius, rect.width * 0.16, rect.height * 0.45)
        let r = min(bottomRadius, max(0, (rect.width - ear * 2) / 2), max(0, rect.height - ear))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.minX + ear, y: rect.minY + ear),
            control1: CGPoint(x: rect.minX + ear * 0.65, y: rect.minY),
            control2: CGPoint(x: rect.minX + ear, y: rect.minY + ear * 0.35)
        )
        path.addLine(to: CGPoint(x: rect.minX + ear, y: rect.maxY - r))
        path.addCurve(
            to: CGPoint(x: rect.minX + ear + r, y: rect.maxY),
            control1: CGPoint(x: rect.minX + ear, y: rect.maxY - r * 0.42),
            control2: CGPoint(x: rect.minX + ear + r * 0.42, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - ear - r, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.maxX - ear, y: rect.maxY - r),
            control1: CGPoint(x: rect.maxX - ear - r * 0.42, y: rect.maxY),
            control2: CGPoint(x: rect.maxX - ear, y: rect.maxY - r * 0.42)
        )
        path.addLine(to: CGPoint(x: rect.maxX - ear, y: rect.minY + ear))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control1: CGPoint(x: rect.maxX - ear, y: rect.minY + ear * 0.35),
            control2: CGPoint(x: rect.maxX - ear * 0.65, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

struct RelayPocketBorderShape: Shape {
    var earRadius: CGFloat = 18
    var bottomRadius: CGFloat = 22

    func path(in rect: CGRect) -> Path {
        let inset = rect.insetBy(dx: 0.5, dy: 0)
        let maxY = inset.maxY - 0.5
        let ear = min(earRadius, inset.width * 0.16, inset.height * 0.45)
        let r = min(bottomRadius, max(0, (inset.width - ear * 2) / 2), max(0, maxY - inset.minY - ear))
        var path = Path()
        path.move(to: CGPoint(x: inset.minX, y: inset.minY + 0.5))
        path.addCurve(
            to: CGPoint(x: inset.minX + ear, y: inset.minY + ear),
            control1: CGPoint(x: inset.minX + ear * 0.65, y: inset.minY + 0.5),
            control2: CGPoint(x: inset.minX + ear, y: inset.minY + ear * 0.35)
        )
        path.addLine(to: CGPoint(x: inset.minX + ear, y: maxY - r))
        path.addCurve(
            to: CGPoint(x: inset.minX + ear + r, y: maxY),
            control1: CGPoint(x: inset.minX + ear, y: maxY - r * 0.42),
            control2: CGPoint(x: inset.minX + ear + r * 0.42, y: maxY)
        )
        path.addLine(to: CGPoint(x: inset.maxX - ear - r, y: maxY))
        path.addCurve(
            to: CGPoint(x: inset.maxX - ear, y: maxY - r),
            control1: CGPoint(x: inset.maxX - ear - r * 0.42, y: maxY),
            control2: CGPoint(x: inset.maxX - ear, y: maxY - r * 0.42)
        )
        path.addLine(to: CGPoint(x: inset.maxX - ear, y: inset.minY + ear))
        path.addCurve(
            to: CGPoint(x: inset.maxX, y: inset.minY + 0.5),
            control1: CGPoint(x: inset.maxX - ear, y: inset.minY + ear * 0.35),
            control2: CGPoint(x: inset.maxX - ear * 0.65, y: inset.minY + 0.5)
        )
        return path
    }
}
