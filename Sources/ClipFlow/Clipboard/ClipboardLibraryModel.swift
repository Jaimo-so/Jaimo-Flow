import ClipFlowKit
import Combine
import Foundation

@MainActor
final class ClipboardLibraryModel: ObservableObject {
    static let historyLimit = SQLiteClipStore.defaultHistoryLimit

    @Published private(set) var items: [ClipItem] = [] {
        didSet {
            itemsRevision &+= 1
            filteredCache = nil
        }
    }

    @Published var query = "" {
        didSet {
            resetHistorySelection()
            app?.credentials.resetSearchSelection()
        }
    }
    @Published private(set) var filter: ClipFilter = .all
    @Published var selectedID: Int64?

    weak var app: AppModel?
    var store: SQLiteClipStore?
    private var itemsRevision = 0
    private var filteredCache: (revision: Int, filter: ClipFilter, query: String, items: [ClipItem])?

    init(store: SQLiteClipStore?) {
        self.store = store
    }

    var isCredentialGroup: Bool { filter == .apiKey }

    var filteredItems: [ClipItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let filteredCache,
           filteredCache.revision == itemsRevision,
           filteredCache.filter == filter,
           filteredCache.query == needle {
            return filteredCache.items
        }
        let result = items.filter { item in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .text: matchesFilter = item.category == .text
            case .image: matchesFilter = item.category == .image
            case .link: matchesFilter = item.category == .link
            case .favorite: matchesFilter = item.isFavorite
            case .apiKey: matchesFilter = false
            }
            guard matchesFilter else { return false }
            guard !needle.isEmpty else { return true }
            return item.title.lowercased().contains(needle)
                || item.sourceAppName.lowercased().contains(needle)
                || (item.fullText?.lowercased().contains(needle) ?? false)
        }
        filteredCache = (itemsRevision, filter, needle, result)
        return result
    }

    var selectedItem: ClipItem? {
        guard let selectedID else { return filteredItems.first }
        return filteredItems.first { $0.id == selectedID }
    }

    func count(for filter: ClipFilter) -> Int {
        switch filter {
        case .all: return items.count
        case .text: return items.filter { $0.category == .text }.count
        case .image: return items.filter { $0.category == .image }.count
        case .link: return items.filter { $0.category == .link }.count
        case .favorite: return items.filter(\.isFavorite).count
        case .apiKey: return 0
        }
    }

    func load() throws {
        try store?.enforceHistoryLimit(Self.historyLimit)
        items = try store?.loadAll() ?? []
    }

    func receive(_ captured: CapturedClip) throws {
        guard let store else { return }
        guard let (item, evictedIDs) = try store.insertWithHistoryChanges(captured, limit: Self.historyLimit) else { return }
        var updatedItems = items
        let index = updatedItems.firstIndex {
            $0.copiedAt < item.copiedAt || ($0.copiedAt == item.copiedAt && $0.id < item.id)
        } ?? updatedItems.endIndex
        updatedItems.insert(item, at: index)
        if !evictedIDs.isEmpty {
            updatedItems.removeAll { evictedIDs.contains($0.id) }
        }
        items = updatedItems
        normalizeHistorySelection(preferFirst: true)
    }

    func setFilter(_ newFilter: ClipFilter) {
        filter = newFilter
        filteredCache = nil
        selectedID = filteredItems.first?.id
    }

    func moveSelection(_ offset: Int) {
        let visible = filteredItems
        guard !visible.isEmpty else { return }
        let current = visible.firstIndex { $0.id == selectedID } ?? 0
        selectedID = visible[min(max(0, current + offset), visible.count - 1)].id
    }

    func copySelection() {
        guard app?.phase == .ready,
              let item = selectedItem,
              let clipboardMonitor = app?.clipboardMonitor else { return }
        switch clipboardMonitor.write(item) {
        case .text(let count): app?.finishCopy(message: "已复制到剪贴板 · \(count) 个字符")
        case .image(let size): app?.finishCopy(message: "已复制图片到剪贴板 · \(size)")
        case .failure: app?.showToast("复制失败，请检查剪贴板权限")
        }
    }

    func toggleFavorite() {
        guard app?.phase == .ready, let item = selectedItem, let store else { return }
        do {
            try store.setFavorite(id: item.id, isFavorite: !item.isFavorite, limit: Self.historyLimit)
            items = try store.loadAll()
            normalizeHistorySelection()
            app?.showToast(item.isFavorite ? "已取消收藏" : "已加入收藏")
        } catch {
            app?.showToast("收藏状态更新失败")
        }
    }

    func deleteSelection() {
        guard app?.phase == .ready, let item = selectedItem, let store else { return }
        let current = filteredItems.firstIndex { $0.id == item.id } ?? 0
        do {
            try store.delete(id: item.id)
            items = try store.loadAll()
            let visible = filteredItems
            selectedID = visible.isEmpty ? nil : visible[min(current, visible.count - 1)].id
            app?.showToast("已删除「\(shortLibraryTitle(item.title))」")
        } catch {
            app?.showToast("删除失败")
        }
    }

    func clearHistory() throws -> Int {
        guard let store else { throw CocoaError(.fileWriteUnknown) }
        let deleted = try store.clear()
        items = []
        selectedID = nil
        return deleted
    }

    private func resetHistorySelection() {
        filteredCache = nil
        selectedID = filteredItems.first?.id
    }

    func normalizeHistorySelection(preferFirst: Bool = false) {
        let visible = filteredItems
        guard !visible.isEmpty else {
            selectedID = nil
            return
        }
        if preferFirst || !visible.contains(where: { $0.id == selectedID }) {
            selectedID = visible.first?.id
        }
    }
}
