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

    func add(urls: [URL]) {
        let accepted = urls.filter { $0.isFileURL }
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
        let url = storedURL(for: item)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "文件副本已经不存在，请移除此记录"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
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

            Group {
                if model.items.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "tray.and.arrow.down")
                            .font(.system(size: 26))
                            .foregroundStyle(theme.muted)
                        Text("把文件或文件夹拖到悬浮球")
                            .font(.system(size: 12.5, weight: .medium))
                        Text("Jaimo Flow 会保存独立副本，原文件不会移动或删除。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.muted)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 250)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(model.items) { item in
                                relayRow(item, theme: theme)
                            }
                        }
                        .padding(10)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if model.isImporting || model.errorMessage != nil {
                Divider().overlay(theme.hairline)
                HStack(spacing: 8) {
                    if model.isImporting { ProgressView().controlSize(.small) }
                    Text(model.isImporting ? "正在复制到本机中转目录…" : model.errorMessage ?? "")
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
                    Text("拖出文件不会自动移除中转副本")
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
        .onDrag {
            NSItemProvider(contentsOf: model.storedURL(for: item)) ?? NSItemProvider()
        }
        .accessibilityHint("可拖到访达或其他应用")
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
