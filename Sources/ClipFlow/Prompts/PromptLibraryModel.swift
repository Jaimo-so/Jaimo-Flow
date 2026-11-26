import ClipFlowKit
import Combine
import Foundation

@MainActor
final class PromptLibraryModel: ObservableObject {
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

    @Published private(set) var prompts: [PromptItem] = [] {
        didSet {
            promptsRevision &+= 1
            filteredPromptsCache = nil
        }
    }
    @Published var promptQuery = "" {
        didSet { resetPromptSelection() }
    }
    @Published private(set) var promptScope: PromptScope = .all
    @Published var selectedPromptID: Int64?
    @Published var promptEditorOpen = false {
        didSet { app?.updateLibraryDialogState() }
    }
    @Published var promptRunnerOpen = false {
        didSet { app?.updateLibraryDialogState() }
    }
    @Published var promptDeleteConfirmationOpen = false {
        didSet { app?.updateLibraryDialogState() }
    }
    @Published var editingPromptID: Int64?
    @Published var promptDraftTitle = ""
    @Published var promptDraftBody = ""
    @Published var promptDraftGroup = "未分组"
    @Published var promptDraftVariables: [PromptVariable] = []
    @Published var promptVariableValues: [String: String] = [:]

    private let preferences: PreferencesStore
    weak var app: AppModel?
    var store: SQLiteClipStore?
    private var promptsRevision = 0
    private var filteredPromptsCache: (
        revision: Int,
        scope: PromptScope,
        query: String,
        prompts: [PromptItem]
    )?

    init(preferences: PreferencesStore, store: SQLiteClipStore?) {
        self.preferences = preferences
        self.store = store
    }

    var hasOpenDialog: Bool {
        promptEditorOpen || promptRunnerOpen || promptDeleteConfirmationOpen
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

    func count(for scope: PromptScope) -> Int {
        switch scope {
        case .all: return prompts.count
        case .favorite: return prompts.filter(\.isFavorite).count
        case .group(let name): return prompts.filter { $0.groupName == name }.count
        }
    }

    func load() throws {
        prompts = try store?.loadPrompts() ?? []
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
            app?.showToast("提示词排序保存失败")
        }
    }

    func cyclePromptScope(_ offset: Int) {
        let scopes = promptScopes
        guard let current = scopes.firstIndex(of: promptScope) else { return }
        setPromptScope(scopes[(current + offset + scopes.count) % scopes.count])
    }

    func movePromptSelection(_ offset: Int) {
        let visible = filteredPrompts
        guard !visible.isEmpty else { return }
        let current = visible.firstIndex { $0.id == selectedPromptID } ?? 0
        selectedPromptID = visible[min(max(0, current + offset), visible.count - 1)].id
    }

    func beginCreatePrompt(prefilledBody body: String = "") {
        editingPromptID = nil
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

    func savePromptDraft() -> Bool {
        let title = promptDraftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = promptDraftBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = promptDraftGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !body.isEmpty else {
            app?.showToast("标题和提示词正文不能为空")
            return false
        }
        guard let store else { return false }
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
                app?.showToast("提示词已更新")
                selectedPromptID = editingPromptID
            } else {
                let prompt = try store.createPrompt(
                    title: title,
                    body: body,
                    groupName: group.isEmpty ? "未分组" : group,
                    variables: promptDraftVariables
                )
                selectedPromptID = prompt.id
                app?.showToast("提示词已保存")
            }
            prompts = try store.loadPrompts()
            promptScope = .all
            promptEditorOpen = false
            normalizePromptSelection()
            return true
        } catch {
            app?.showToast("提示词保存失败")
            return false
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
            app?.showToast("请填写所有必填变量")
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
            app?.showToast("已删除提示词「\(shortLibraryTitle(prompt.title))」")
        } catch {
            app?.showToast("提示词删除失败")
        }
    }

    func requestDeletePrompt() {
        guard selectedPrompt != nil else { return }
        promptDeleteConfirmationOpen = true
    }

    func togglePromptFavorite() {
        guard let prompt = selectedPrompt, let store else { return }
        do {
            try store.setPromptFavorite(id: prompt.id, isFavorite: !prompt.isFavorite)
            prompts = try store.loadPrompts()
            normalizePromptSelection()
            app?.showToast(prompt.isFavorite ? "已取消收藏" : "已加入收藏")
        } catch {
            app?.showToast("收藏状态更新失败")
        }
    }

    private func copyPrompt(_ prompt: PromptItem, values: [String: String]) {
        guard let clipboardMonitor = app?.clipboardMonitor else { return }
        let rendered = PromptTemplate.render(prompt.body, values: values)
        switch clipboardMonitor.write(text: rendered) {
        case .text(let count):
            do {
                try store?.markPromptUsed(id: prompt.id)
                prompts = try store?.loadPrompts() ?? prompts
            } catch { }
            app?.finishCopy(message: "已复制提示词 · \(count) 个字符")
        case .image:
            break
        case .failure:
            app?.showToast("复制失败，请检查剪贴板权限")
        }
    }

    private func resetPromptSelection() {
        filteredPromptsCache = nil
        selectedPromptID = filteredPrompts.first?.id
    }

    func normalizePromptSelection(preferFirst: Bool = false) {
        let visible = filteredPrompts
        guard !visible.isEmpty else {
            selectedPromptID = nil
            return
        }
        if preferFirst || !visible.contains(where: { $0.id == selectedPromptID }) {
            selectedPromptID = visible.first?.id
        }
    }

    private static func suggestedPromptTitle(from body: String) -> String {
        let firstLine = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? body
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 30 ? String(trimmed.prefix(30)) + "…" : trimmed
    }
}
