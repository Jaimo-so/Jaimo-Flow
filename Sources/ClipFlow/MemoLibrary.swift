import Foundation
import SwiftUI

struct MemoItem: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var body: String
    let createdAt: Date
    var updatedAt: Date
    var isPinned: Bool
}

@MainActor
final class MemoLibraryModel: ObservableObject {
    enum CreationError: Error {
        case unreadableStore
        case emptyContent
    }

    enum SaveStatus: Equatable {
        case pending
        case saved
        case saving
        case failed

        var text: String {
            switch self {
            case .pending: return "关闭时保存 · 仅本机"
            case .saved: return "已保存 · 仅本机"
            case .saving: return "正在保存…"
            case .failed: return "保存失败，内容已保留，请重试"
            }
        }
    }

    @Published private var records: [MemoItem] = []
    // Draft text stays out of the published list while the user is typing.
    private var drafts: [UUID: MemoItem] = [:]
    @Published var selectedID: UUID?
    @Published private(set) var saveStatus: SaveStatus = .saved

    private let fileURL: URL
    private var hasUnsavedChanges = false
    private var loadFailed = false

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
            .appendingPathComponent("ClipFlow", isDirectory: true)
            .appendingPathComponent("Memos", isDirectory: true)
            .appendingPathComponent("memos.json")
        load()
        selectedID = sortedItems.first?.id
    }

    var sortedItems: [MemoItem] {
        records.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned && !$1.isPinned }
            return $0.updatedAt > $1.updatedAt
        }
    }

    var selectedItem: MemoItem? {
        guard let selectedID else { return nil }
        return item(id: selectedID)
    }

    var items: [MemoItem] {
        records.map { drafts[$0.id] ?? $0 }
    }

    func item(id: UUID) -> MemoItem? {
        drafts[id] ?? records.first { $0.id == id }
    }

    @discardableResult
    func createMemo() -> UUID {
        insertMemo(id: UUID(), title: "新备忘录", body: "")
    }

    /// App-internal preparation for a future local bridge. One stable ID per task.
    /// A retry returns the existing Memo without replacing subsequent user edits.
    /// This is not a transport endpoint or a durable receipt after deletion.
    @discardableResult
    func createMemo(id: UUID, title: String, body: String) throws -> UUID {
        guard !loadFailed else { throw CreationError.unreadableStore }
        if items.contains(where: { $0.id == id }) { return id }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CreationError.emptyContent
        }
        return insertMemo(id: id, title: title, body: body)
    }

    @discardableResult
    private func insertMemo(id: UUID, title: String, body: String) -> UUID {
        let now = Date()
        let item = MemoItem(
            id: id,
            title: title,
            body: body,
            createdAt: now,
            updatedAt: now,
            isPinned: false
        )
        records.append(item)
        selectedID = item.id
        markChanged()
        return item.id
    }

    func updateTitle(_ title: String) {
        guard let selectedID else { return }
        updateTitle(title, for: selectedID)
    }

    func updateTitle(_ title: String, for id: UUID) {
        updateItem(id: id) { $0.title = title }
    }

    func updateBody(_ body: String) {
        guard let selectedID else { return }
        updateBody(body, for: selectedID)
    }

    func updateBody(_ body: String, for id: UUID) {
        updateItem(id: id) { $0.body = body }
    }

    func togglePinned(_ item: MemoItem) {
        guard let index = records.firstIndex(where: { $0.id == item.id }) else { return }
        records[index].isPinned.toggle()
        records[index].updatedAt = Date()
        if var draft = drafts[item.id] {
            draft.isPinned = records[index].isPinned
            drafts[item.id] = draft
        }
        markChanged()
    }

    func deleteSelected() {
        guard let selectedID else { return }
        drafts.removeValue(forKey: selectedID)
        records.removeAll { $0.id == selectedID }
        self.selectedID = sortedItems.first?.id
        markChanged()
    }

    @discardableResult
    func flush() -> Bool {
        persist()
    }

    private func updateItem(id: UUID, _ mutate: (inout MemoItem) -> Void) {
        guard var draft = item(id: id) else { return }
        let original = draft
        mutate(&draft)
        guard draft != original else { return }
        draft.updatedAt = Date()
        drafts[id] = draft
        markChanged()
    }

    private func markChanged() {
        hasUnsavedChanges = true
        if saveStatus == .saved { saveStatus = .pending }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            records = try JSONDecoder().decode([MemoItem].self, from: data)
        } catch {
            loadFailed = true
            saveStatus = .failed
        }
    }

    private func persist() -> Bool {
        guard hasUnsavedChanges else { return true }
        guard !loadFailed else { return false }
        saveStatus = .saving
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let snapshot = items
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
            records = snapshot
            drafts.removeAll()
            hasUnsavedChanges = false
            saveStatus = .saved
            return true
        } catch {
            saveStatus = .failed
            return false
        }
    }
}

struct MemoLibraryOverlay: View {
    @ObservedObject var model: MemoLibraryModel
    let onClose: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var deleteArmed = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .onTapGesture(perform: close)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("备忘录")
                            .font(.system(size: 14, weight: .semibold))
                        if model.saveStatus == .failed {
                            Text(model.saveStatus.text)
                                .font(.system(size: 10.5))
                                .foregroundStyle(theme.danger)
                        }
                    }
                    if model.saveStatus == .failed {
                        Button("重试保存") { model.flush() }
                            .buttonStyle(GlassButtonStyle(kind: .normal))
                    }
                    Spacer()
                    Button {
                        model.createMemo()
                        DispatchQueue.main.async { titleFocused = true }
                    } label: {
                        Label("新建", systemImage: "plus")
                    }
                    .buttonStyle(GlassButtonStyle(kind: .primary))
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(IslandMemoIconButtonStyle())
                    .accessibilityLabel("关闭备忘录")
                }
                .padding(.horizontal, 14)
                .frame(height: 58)

                Divider().overlay(theme.hairline)

                HStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(model.sortedItems) { item in
                                memoRow(item, theme: theme)
                            }
                        }
                        .padding(9)
                    }
                    .frame(width: 210)

                    Divider().overlay(theme.hairline)

                    if let selected = model.selectedItem {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("备忘录标题", text: titleBinding(for: selected.id))
                                .textFieldStyle(.plain)
                                .font(.system(size: 17, weight: .semibold))
                                .focused($titleFocused)
                                .accessibilityLabel("备忘录标题")

                            NoteTextEditor(text: bodyBinding(for: selected.id), fontSize: 12.5, foreground: theme.foreground, identifier: "jaimo.memo.editor")
                                .accessibilityLabel("备忘录正文")

                            HStack {
                                Text(selected.updatedAt.formatted(.dateTime.year().month().day().hour().minute()))
                                    .font(.system(size: 10))
                                    .foregroundStyle(theme.muted)
                                Spacer()
                                Button {
                                    model.togglePinned(selected)
                                } label: {
                                    Label(selected.isPinned ? "取消置顶" : "置顶", systemImage: selected.isPinned ? "pin.slash" : "pin")
                                }
                                .buttonStyle(GlassButtonStyle(kind: .normal))
                                Button(deleteArmed ? "确认删除" : "删除") {
                                    if deleteArmed {
                                        model.deleteSelected()
                                        deleteArmed = false
                                    } else {
                                        deleteArmed = true
                                    }
                                }
                                .buttonStyle(GlassButtonStyle(kind: deleteArmed ? .danger : .normal))
                                .accessibilityHint("点击后需要再次确认")
                            }
                        }
                        .padding(16)
                        .id(selected.id)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "note.text")
                                .font(.system(size: 28))
                                .foregroundStyle(theme.muted)
                            Text("还没有备忘录")
                                .font(.system(size: 13, weight: .medium))
                            Button("新建第一条备忘录") {
                                model.createMemo()
                                DispatchQueue.main.async { titleFocused = true }
                            }
                            .buttonStyle(GlassButtonStyle(kind: .primary))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(width: 720, height: 480)
            .background(VisualEffectBackground())
            .background(theme.glass.opacity(0.98))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(theme.hairline, lineWidth: 0.7))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.56), radius: 34, y: 20)
            .onTapGesture { }
        }
        .onAppear {
            if model.items.isEmpty { model.createMemo() }
            DispatchQueue.main.async { titleFocused = true }
        }
        .onDisappear { model.flush() }
    }

    private func titleBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { model.item(id: id)?.title ?? "" },
            set: { model.updateTitle($0, for: id) }
        )
    }

    private func bodyBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { model.item(id: id)?.body ?? "" },
            set: { model.updateBody($0, for: id) }
        )
    }

    private func memoRow(_ item: MemoItem, theme: ClipFlowTheme) -> some View {
        Button {
            deleteArmed = false
            model.selectedID = item.id
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: item.isPinned ? "pin.fill" : "note.text")
                    .font(.system(size: 10.5))
                    .foregroundStyle(item.isPinned ? theme.star : theme.muted)
                    .frame(width: 16, height: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title.isEmpty ? "无标题备忘录" : item.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                    Text(item.body.isEmpty ? "暂无正文" : item.body.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 9.5))
                        .foregroundStyle(theme.muted)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(model.selectedID == item.id ? theme.selection : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.selectedID == item.id ? .isSelected : [])
    }

    private func close() {
        guard model.flush() else { return }
        onClose()
    }
}

private struct IslandMemoIconButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        configuration.label
            .foregroundStyle(theme.muted)
            .background(configuration.isPressed ? theme.chipHigh : theme.chip)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
