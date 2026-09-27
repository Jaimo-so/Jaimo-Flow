import AppKit
import ClipFlowKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    static let historyLimit = SQLiteClipStore.defaultHistoryLimit

    enum FocusArea {
        case search
        case tabs
        case other
    }

    enum LibraryMode: String, CaseIterable, Identifiable {
        case history
        case prompts

        var id: String { rawValue }
        var title: String { self == .history ? "历史" : "提示词" }
    }

    enum PromptScope: Hashable, Identifiable {
        case all
        case favorite
        case group(String)

        var id: String {
            switch self {
            case .all: return "all"
            case .favorite: return "favorite"
            case .group(let name): return "group:\(name)"
            }
        }

        var title: String {
            switch self {
            case .all: return "全部"
            case .favorite: return "收藏"
            case .group(let name): return name
            }
        }
    }

    @Published private(set) var items: [ClipItem] = [] {
        didSet {
            itemsRevision &+= 1
            filteredCache = nil
        }
    }
    @Published private(set) var prompts: [PromptItem] = [] {
        didSet {
            promptsRevision &+= 1
            filteredPromptsCache = nil
        }
    }
    @Published var credentialEntries: [CredentialEntry] = []
    @Published var credentialError: String?
    @Published var selectedCredentialID: String?
    @Published var credentialEditorOpen = false
    @Published var credentialDeleteConfirmationOpen = false
    @Published var editingCredentialID: String?
    @Published var credentialDraftTitle = ""
    @Published var credentialDraftSecret = ""
    let credentialStore: CredentialStore

    @Published var phase: ClipFlowPhase = .loading
    @Published var libraryMode: LibraryMode = .history
    @Published var query = "" {
        didSet { resetHistorySelection() }
    }
    @Published var promptQuery = "" {
        didSet { resetPromptSelection() }
    }
    @Published var filter: ClipFilter = .all
    @Published var promptScope: PromptScope = .all
    @Published var selectedID: Int64?
    @Published var selectedPromptID: Int64?
    @Published var settingsOpen = false
    @Published var promptEditorOpen = false
    @Published var promptRunnerOpen = false
    @Published var promptDeleteConfirmationOpen = false
    @Published var editingPromptID: Int64?
    @Published var promptDraftTitle = ""
    @Published var promptDraftBody = ""
    @Published var promptDraftGroup = "未分组"
    @Published var promptDraftVariables: [PromptVariable] = []
    @Published var promptVariableValues: [String: String] = [:]
    @Published var toastMessage: String?
    @Published var focusArea: FocusArea = .other

    let preferences: PreferencesStore
    let updateManager: UpdateManager
    var clipboardMonitor: ClipboardMonitor?
    var onRequestClose: (() -> Void)?

    private var store: SQLiteClipStore?
    private var loadGeneration = UUID()
    private var toastDismissal: DispatchWorkItem?
    private var itemsRevision = 0
    private var filteredCache: (revision: Int, filter: ClipFilter, query: String, items: [ClipItem])?
    private var promptsRevision = 0
    private var filteredPromptsCache: (
        revision: Int,
        scope: PromptScope,
        query: String,
        prompts: [PromptItem]
    )?

    init(preferences: PreferencesStore, credentialStore: CredentialStore = CredentialStore()) {
        self.credentialStore = credentialStore
        self.preferences = preferences
        updateManager = UpdateManager()
    }

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

    var filteredPrompts: [PromptItem] {
        let needle = promptQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let filteredPromptsCache,
           filteredPromptsCache.revision == promptsRevision,
           filteredPromptsCache.scope == promptScope,
           filteredPromptsCache.query == needle {
            return filteredPromptsCache.prompts
        }

        let result = prompts.filter { prompt in
            let matchesScope: Bool
            switch promptScope {
            case .all: matchesScope = true
            case .favorite: matchesScope = prompt.isFavorite
            case .group(let name): matchesScope = prompt.groupName == name
            }
            guard matchesScope else { return false }
            guard !needle.isEmpty else { return true }
            return prompt.title.lowercased().contains(needle)
                || prompt.body.lowercased().contains(needle)
                || prompt.groupName.lowercased().contains(needle)
        }
        filteredPromptsCache = (promptsRevision, promptScope, needle, result)
        return result
    }

    var promptGroups: [String] {
        let available = Set(prompts.map(\.groupName))
        let ordered = preferences.promptGroupOrder.filter(available.contains)
        let orderedSet = Set(ordered)
        let remaining = available.filter { !orderedSet.contains($0) }.sorted { lhs, rhs in
            if lhs == "未分组" { return true }
            if rhs == "未分组" { return false }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        return ordered + remaining
    }

    var promptScopes: [PromptScope] {
        [.all, .favorite] + promptGroups.map(PromptScope.group)
    }

    var selectedItem: ClipItem? {
        guard let selectedID else { return filteredItems.first }
        return filteredItems.first { $0.id == selectedID }
    }

    var selectedPrompt: PromptItem? {
        guard let selectedPromptID else { return filteredPrompts.first }
        return filteredPrompts.first { $0.id == selectedPromptID }
    }

    var runnerPrompt: PromptItem? {
        guard let selectedPromptID else { return nil }
        return prompts.first { $0.id == selectedPromptID }
    }

    var hasMissingRequiredPromptVariables: Bool {
        guard let prompt = runnerPrompt else { return true }
        return prompt.variables.contains { variable in
            variable.isRequired
                && (promptVariableValues[variable.name] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func count(for filter: ClipFilter) -> Int {
        switch filter {
        case .all: return items.count
        case .text: return items.filter { $0.category == .text }.count
        case .image: return items.filter { $0.category == .image }.count
        case .link: return items.filter { $0.category == .link }.count
        case .favorite: return items.filter(\.isFavorite).count
        case .apiKey: return credentialEntries.count
        }
    }

    func count(for scope: PromptScope) -> Int {
        switch scope {
        case .all: return prompts.count
        case .favorite: return prompts.filter(\.isFavorite).count
        case .group(let name): return prompts.filter { $0.groupName == name }.count
        }
    }

    func load() {
        let generation = UUID()
        loadGeneration = generation
        phase = .loading
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self, self.loadGeneration == generation else { return }
            do {
                if self.store == nil { self.store = try SQLiteClipStore() }
                try self.store?.enforceHistoryLimit(Self.historyLimit)
                self.items = try self.store?.loadAll() ?? []
                self.prompts = try self.store?.loadPrompts() ?? []
                self.phase = .ready
                self.normalizeHistorySelection()
                self.normalizePromptSelection()
            } catch {
                self.phase = .failed(error.localizedDescription)
                self.announce("无法读取本地数据库")
            }
        }
    }

    func receive(_ captured: CapturedClip) {
        guard case .ready = phase, let store else { return }
        do {
            guard try store.insert(captured) != nil else { return }
            items = try store.loadAll()
            normalizeHistorySelection(preferFirst: true)
        } catch {
            phase = .failed(error.localizedDescription)
            announce("无法写入剪贴板历史")
        }
    }

    func setMode(_ mode: LibraryMode) {
        guard libraryMode != mode else { return }
        libraryMode = mode
        focusArea = .other
        if mode == .history { normalizeHistorySelection() }
        else { normalizePromptSelection() }
    }

    func setFilter(_ newFilter: ClipFilter) {
        filter = newFilter
        if newFilter == .apiKey { loadCredentials() }
        filteredCache = nil
        selectedID = filteredItems.first?.id
    }

    func setPromptScope(_ scope: PromptScope) {
        promptScope = scope
        filteredPromptsCache = nil
        selectedPromptID = filteredPrompts.first?.id
    }

    func movePromptGroup(_ group: String, relativeTo target: String, after: Bool) {
        guard group != target else { return }
        var groups = promptGroups
        guard let sourceIndex = groups.firstIndex(of: group) else { return }
        let moved = groups.remove(at: sourceIndex)
        guard let targetIndex = groups.firstIndex(of: target) else { return }
        groups.insert(moved, at: targetIndex + (after ? 1 : 0))
        preferences.setPromptGroupOrder(groups)
        objectWillChange.send()
    }

    func movePromptGroup(_ group: String, by offset: Int) {
        var groups = promptGroups
        guard let sourceIndex = groups.firstIndex(of: group) else { return }
        let destination = min(max(sourceIndex + offset, 0), groups.count - 1)
        guard destination != sourceIndex else { return }
        let moved = groups.remove(at: sourceIndex)
        groups.insert(moved, at: destination)
        preferences.setPromptGroupOrder(groups)
        objectWillChange.send()
    }

    func movePrompt(_ promptID: Int64, relativeTo targetID: Int64, after: Bool) {
        guard promptID != targetID,
              let store,
              let sourceIndex = prompts.firstIndex(where: { $0.id == promptID }) else { return }

        var reordered = prompts
        let moved = reordered.remove(at: sourceIndex)
        guard let targetIndex = reordered.firstIndex(where: { $0.id == targetID }) else { return }
        reordered.insert(moved, at: targetIndex + (after ? 1 : 0))

        do {
            try store.setPromptOrder(reordered.map(\.id))
            prompts = reordered
            selectedPromptID = promptID
        } catch {
            prompts = (try? store.loadPrompts()) ?? prompts
            showToast("提示词排序保存失败")
        }
    }

    func cycleFilter(_ offset: Int) {
        if libraryMode == .history {
            let filters = ClipFilter.allCases
            guard let current = filters.firstIndex(of: filter) else { return }
            setFilter(filters[(current + offset + filters.count) % filters.count])
        } else {
            let scopes = promptScopes
            guard !scopes.isEmpty, let current = scopes.firstIndex(of: promptScope) else { return }
            setPromptScope(scopes[(current + offset + scopes.count) % scopes.count])
        }
    }

    func moveSelection(_ offset: Int) {
        if isCredentialGroup {
            let visible = filteredCredentials
            guard !visible.isEmpty else { return }
            let current = visible.firstIndex { $0.id == selectedCredentialID } ?? 0
            selectedCredentialID = visible[min(max(0, current + offset), visible.count - 1)].id
            return
        }
        if libraryMode == .history {
            let visible = filteredItems
            guard !visible.isEmpty else { return }
            let current = visible.firstIndex { $0.id == selectedID } ?? 0
            selectedID = visible[min(max(0, current + offset), visible.count - 1)].id
        } else {
            let visible = filteredPrompts
            guard !visible.isEmpty else { return }
            let current = visible.firstIndex { $0.id == selectedPromptID } ?? 0
            selectedPromptID = visible[min(max(0, current + offset), visible.count - 1)].id
        }
    }

    func copySelected() {
        if isCredentialGroup { copyCredential(); return }
        if libraryMode == .prompts {
            useSelectedPrompt()
            return
        }
        guard case .ready = phase,
              let item = selectedItem,
              let clipboardMonitor else { return }
        switch clipboardMonitor.write(item) {
        case .text(let count): finishCopy(message: "已复制到剪贴板 · \(count) 个字符")
        case .image(let size): finishCopy(message: "已复制图片到剪贴板 · \(size)")
        case .failure: showToast("复制失败，请检查剪贴板权限")
        }
    }

    func toggleFavorite() {
        if isCredentialGroup { return }
        if libraryMode == .prompts {
            togglePromptFavorite()
            return
        }
        guard case .ready = phase, let item = selectedItem, let store else { return }
        do {
            try store.setFavorite(id: item.id, isFavorite: !item.isFavorite)
            items = try store.loadAll()
            normalizeHistorySelection()
            showToast(item.isFavorite ? "已取消收藏" : "已加入收藏")
        } catch {
            showToast("收藏状态更新失败")
        }
    }

    func deleteSelected() {
        if isCredentialGroup {
            credentialDeleteConfirmationOpen = selectedCredential != nil
            return
        }
        if libraryMode == .prompts {
            guard selectedPrompt != nil else { return }
            promptDeleteConfirmationOpen = true
            return
        }
        guard case .ready = phase, let item = selectedItem, let store else { return }
        let current = filteredItems.firstIndex { $0.id == item.id } ?? 0
        do {
            try store.delete(id: item.id)
            items = try store.loadAll()
            let visible = filteredItems
            selectedID = visible.isEmpty ? nil : visible[min(current, visible.count - 1)].id
            showToast("已删除「\(shortTitle(item.title))」")
        } catch {
            showToast("删除失败")
        }
    }

    func beginCreatePrompt(prefillFromSelection: Bool = false) {
        editingPromptID = nil
        let source = prefillFromSelection ? selectedItem : nil
        let body = source?.fullText ?? source?.title ?? ""
        promptDraftTitle = body.isEmpty ? "" : Self.suggestedPromptTitle(from: body)
        promptDraftBody = body
        promptDraftGroup = promptGroups.first ?? "未分组"
        promptDraftVariables = PromptTemplate.variables(in: body)
        promptEditorOpen = true
    }

    func beginEditSelectedPrompt() {
        guard let prompt = selectedPrompt else { return }
        editingPromptID = prompt.id
        promptDraftTitle = prompt.title
        promptDraftBody = prompt.body
        promptDraftGroup = prompt.groupName
        promptDraftVariables = prompt.variables
        promptEditorOpen = true
    }

    func syncDraftVariables() {
        promptDraftVariables = PromptTemplate.variables(
            in: promptDraftBody,
            preserving: promptDraftVariables
        )
    }

    func savePromptDraft() {
        let title = promptDraftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = promptDraftBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = promptDraftGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !body.isEmpty else {
            showToast("标题和提示词正文不能为空")
            return
        }
        guard let store else { return }
        syncDraftVariables()
        do {
            if let editingPromptID {
                try store.updatePrompt(
                    id: editingPromptID,
                    title: title,
                    body: body,
                    groupName: group.isEmpty ? "未分组" : group,
                    variables: promptDraftVariables
                )
                showToast("提示词已更新")
                selectedPromptID = editingPromptID
            } else {
                let prompt = try store.createPrompt(
                    title: title,
                    body: body,
                    groupName: group.isEmpty ? "未分组" : group,
                    variables: promptDraftVariables
                )
                selectedPromptID = prompt.id
                showToast("提示词已保存")
            }
            prompts = try store.loadPrompts()
            libraryMode = .prompts
            promptScope = .all
            promptEditorOpen = false
            normalizePromptSelection()
        } catch {
            showToast("提示词保存失败")
        }
    }

    func useSelectedPrompt() {
        guard let prompt = selectedPrompt else { return }
        if prompt.variables.isEmpty {
            copyPrompt(prompt, values: [:])
        } else {
            promptVariableValues = Dictionary(
                uniqueKeysWithValues: prompt.variables.map { ($0.name, $0.defaultValue) }
            )
            promptRunnerOpen = true
        }
    }

    func copyRenderedPrompt() {
        guard let prompt = runnerPrompt, !hasMissingRequiredPromptVariables else {
            showToast("请填写所有必填变量")
            return
        }
        copyPrompt(prompt, values: promptVariableValues)
        promptRunnerOpen = false
    }

    func confirmDeletePrompt() {
        guard let prompt = selectedPrompt, let store else { return }
        let current = filteredPrompts.firstIndex { $0.id == prompt.id } ?? 0
        do {
            try store.deletePrompt(id: prompt.id)
            prompts = try store.loadPrompts()
            let visible = filteredPrompts
            selectedPromptID = visible.isEmpty ? nil : visible[min(current, visible.count - 1)].id
            promptDeleteConfirmationOpen = false
            showToast("已删除提示词「\(shortTitle(prompt.title))」")
        } catch {
            showToast("提示词删除失败")
        }
    }

    @discardableResult
    func clearHistory() -> Int {
        guard let store else {
            showToast("清空失败，请重试")
            return 0
        }
        do {
            let deleted = try store.clear()
            items = []
            selectedID = nil
            phase = .ready
            settingsOpen = false
            showToast("已清空 \(deleted) 条历史记录")
            return deleted
        } catch {
            showToast("清空失败，请重试")
            return 0
        }
    }

    func showToast(_ message: String) {
        toastDismissal?.cancel()
        toastMessage = message
        announce(message)
        let work = DispatchWorkItem { [weak self] in self?.toastMessage = nil }
        toastDismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func prepareForPresentation() {
        if libraryMode == .history { selectedID = filteredItems.first?.id }
        else { selectedPromptID = filteredPrompts.first?.id }
    }

    private func togglePromptFavorite() {
        guard let prompt = selectedPrompt, let store else { return }
        do {
            try store.setPromptFavorite(id: prompt.id, isFavorite: !prompt.isFavorite)
            prompts = try store.loadPrompts()
            normalizePromptSelection()
            showToast(prompt.isFavorite ? "已取消收藏" : "已加入收藏")
        } catch {
            showToast("收藏状态更新失败")
        }
    }

    private func copyPrompt(_ prompt: PromptItem, values: [String: String]) {
        guard let clipboardMonitor else { return }
        let rendered = PromptTemplate.render(prompt.body, values: values)
        switch clipboardMonitor.write(text: rendered) {
        case .text(let count):
            do {
                try store?.markPromptUsed(id: prompt.id)
                prompts = try store?.loadPrompts() ?? prompts
            } catch { }
            finishCopy(message: "已复制提示词 · \(count) 个字符")
        case .image:
            break
        case .failure:
            showToast("复制失败，请检查剪贴板权限")
        }
    }

    func finishCopy(message: String) {
        showToast(message)
        if preferences.closeAfterCopy {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.onRequestClose?()
            }
        }
    }

    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }

    private func resetHistorySelection() {
        selectedCredentialID = filteredCredentials.first?.id
        filteredCache = nil
        selectedID = filteredItems.first?.id
    }

    private func resetPromptSelection() {
        filteredPromptsCache = nil
        selectedPromptID = filteredPrompts.first?.id
    }

    private func normalizeHistorySelection(preferFirst: Bool = false) {
        let visible = filteredItems
        guard !visible.isEmpty else {
            selectedID = nil
            return
        }
        if preferFirst || !visible.contains(where: { $0.id == selectedID }) {
            selectedID = visible.first?.id
        }
    }

    private func normalizePromptSelection(preferFirst: Bool = false) {
        let visible = filteredPrompts
        guard !visible.isEmpty else {
            selectedPromptID = nil
            return
        }
        if preferFirst || !visible.contains(where: { $0.id == selectedPromptID }) {
            selectedPromptID = visible.first?.id
        }
    }

    private func shortTitle(_ title: String) -> String {
        title.count > 14 ? String(title.prefix(14)) + "…" : title
    }

    private static func suggestedPromptTitle(from body: String) -> String {
        let firstLine = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? body
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 30 ? String(trimmed.prefix(30)) + "…" : trimmed
    }
}
