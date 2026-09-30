import Foundation
import SwiftUI

enum VibeHubCategory: String, Codable, CaseIterable, Identifiable {
    case navigation = "路由与导航"
    case interface = "界面与布局"
    case interaction = "交互与动效"
    case data = "数据与接口"
    case debugging = "调试与测试"
    case engineering = "部署与工程"
    case uncategorized = "未分类"

    var id: String { rawValue }

    static func suggested(for text: String) -> VibeHubCategory {
        let text = text.lowercased()
        let rules: [(VibeHubCategory, [String])] = [
            (.navigation, ["路由", "导航", "网址", "前进后退", "router", "routing"]),
            (.debugging, ["报错", "修复", "调试", "测试", "bug", "debug", "test"]),
            (.engineering, ["部署", "打包", "构建", "版本控制", "deploy", "git", "ci/cd"]),
            (.data, ["接口", "数据库", "请求", "缓存", "持久化", "api", "database", "fetch"]),
            (.interaction, ["悬停", "点击", "拖拽", "拖动", "动画", "动效", "交互", "tooltip", "hover"]),
            (.interface, ["布局", "间距", "颜色", "字体", "响应式", "圆角", "样式", "排版", "css"])
        ]
        return rules.first { _, words in words.contains { text.contains($0) } }?.0 ?? .uncategorized
    }
}

struct VibeHubItem: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var phrase: String
    var category: VibeHubCategory
    var tags: String
    var scenario: String
    var meaning: String
    var isFavorite: Bool
    let createdAt: Date
    var updatedAt: Date

    static var hashRoutingExample: VibeHubItem {
        let now = Date()
        return VibeHubItem(
            id: UUID(), title: "页面切换与哈希路由",
            phrase: "给各个页面加上哈希路由，点击切换时网址同步变化，并支持刷新和浏览器前进后退。",
            category: .navigation, tags: "哈希路由、页面切换、浏览器历史",
            scenario: "多页面网站或 Web 应用：需要切换页面时同步网址，刷新后保留当前页面，并支持浏览器前进和后退。",
            meaning: "哈希路由（Hash Routing）使用网址中 # 后面的片段表示当前页面，例如 #/home 和 #/settings。切换页面时更新这个片段，刷新时根据它恢复页面，浏览器前进和后退时同步显示对应页面。",
            isFavorite: false, createdAt: now, updatedAt: now
        )
    }
}

@MainActor
final class VibeHubLibraryModel: ObservableObject {
    enum Scope: Equatable {
        case all
        case favorites
        case category(VibeHubCategory)
    }

    enum SaveStatus {
        case saved, saving, failed

        var text: String {
            switch self {
            case .saved: return "已保存 · 仅本机"
            case .saving: return "正在保存…"
            case .failed: return "保存失败，请重试"
            }
        }
    }

    @Published private(set) var items: [VibeHubItem] = []
    @Published var selectedID: UUID?
    @Published var query = "" { didSet { normalizeSelection() } }
    @Published var scope: Scope = .all { didSet { normalizeSelection() } }
    @Published private(set) var saveStatus: SaveStatus = .saved
    @Published private(set) var loadFailed = false

    private let fileURL: URL
    private var saveWorkItem: DispatchWorkItem?
    private var hasUnsavedChanges = false

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ClipFlow/VibeHub/phrases.json")
        if FileManager.default.fileExists(atPath: self.fileURL.path) {
            load()
        } else {
            items = [.hashRoutingExample]
            scheduleSave()
        }
        selectedID = filteredItems.first?.id
    }

    var selectedItem: VibeHubItem? { items.first { $0.id == selectedID } }

    var filteredItems: [VibeHubItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            guard matches(item, scope: scope) else { return false }
            return needle.isEmpty || [item.title, item.phrase, item.category.rawValue, item.tags, item.scenario, item.meaning]
                .contains { $0.localizedCaseInsensitiveContains(needle) }
        }.sorted {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
            return $0.updatedAt > $1.updatedAt
        }
    }

    func count(in scope: Scope) -> Int { items.filter { matches($0, scope: scope) }.count }

    @discardableResult
    func createPhrase() -> UUID? {
        guard !loadFailed else { return nil }
        let category: VibeHubCategory
        if case .category(let selectedCategory) = scope { category = selectedCategory }
        else { category = .uncategorized }
        let now = Date()
        let item = VibeHubItem(id: UUID(), title: "新话术", phrase: "", category: category,
                               tags: "", scenario: "", meaning: "", isFavorite: scope == .favorites,
                               createdAt: now, updatedAt: now)
        items.append(item)
        query = ""
        selectedID = item.id
        scheduleSave()
        return item.id
    }

    func updateSelected<Value: Equatable>(_ keyPath: WritableKeyPath<VibeHubItem, Value>, to value: Value) {
        guard !loadFailed, let index = items.firstIndex(where: { $0.id == selectedID }),
              items[index][keyPath: keyPath] != value else { return }
        items[index][keyPath: keyPath] = value
        items[index].updatedAt = Date()
        scheduleSave()
        // Keep an edited record visible when its category or favorite state changes.
        if !matches(items[index], scope: scope) { scope = .all }
    }

    func classifySelected() {
        guard let item = selectedItem else { return }
        updateSelected(\.category, to: VibeHubCategory.suggested(for: item.title + "\n" + item.phrase))
    }

    func saveAgentPhrase(id: UUID, phrase: String, content: VibeHubAgentContent) throws {
        guard !loadFailed else { throw VibeHubAgentError.unreadableLibrary }
        guard !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VibeHubAgentError.emptyPhrase }
        try content.validate()
        if items.contains(where: { $0.id == id }) {
            flush()
            guard saveStatus == .saved else { throw VibeHubAgentError.saveFailed }
            return
        }
        let now = Date()
        let candidate = items + [VibeHubItem(id: id, title: content.title, phrase: phrase, category: content.category,
                                 tags: content.tags.joined(separator: "、"), scenario: content.scenario,
                                 meaning: content.meaning, isFavorite: false, createdAt: now, updatedAt: now)]
        do { try writeItems(candidate) } catch { throw VibeHubAgentError.saveFailed }
        saveWorkItem?.cancel()
        saveWorkItem = nil
        items = candidate
        hasUnsavedChanges = false
        saveStatus = .saved
    }

    func deleteSelected() {
        guard !loadFailed, let selectedID else { return }
        items.removeAll { $0.id == selectedID }
        normalizeSelection()
        scheduleSave()
    }

    func reload() {
        guard loadFailed else { return }
        load()
        normalizeSelection()
    }

    func flush() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        guard hasUnsavedChanges, !loadFailed else { return }
        do {
            try writeItems(items)
            hasUnsavedChanges = false
            saveStatus = .saved
        } catch { saveStatus = .failed }
    }

    private func writeItems(_ items: [VibeHubItem]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(items).write(to: fileURL, options: .atomic)
    }

    private func matches(_ item: VibeHubItem, scope: Scope) -> Bool {
        switch scope {
        case .all: return true
        case .favorites: return item.isFavorite
        case .category(let category): return item.category == category
        }
    }

    private func normalizeSelection() {
        if !filteredItems.contains(where: { $0.id == selectedID }) { selectedID = filteredItems.first?.id }
    }

    private func scheduleSave() {
        hasUnsavedChanges = true
        saveStatus = .saving
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.flush() } }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func load() {
        do {
            items = try JSONDecoder().decode([VibeHubItem].self, from: Data(contentsOf: fileURL))
            loadFailed = false
            saveStatus = .saved
        } catch {
            loadFailed = true
            saveStatus = .failed
        }
    }
}
