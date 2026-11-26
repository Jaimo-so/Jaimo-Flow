import AppKit
import ClipFlowKit
import Combine

@MainActor
final class AppModel: ObservableObject {
    enum FocusArea {
        case search
        case tabs
        case other
    }

    @Published private(set) var phase: ClipFlowPhase = .loading
    @Published var settingsOpen = false
    @Published private(set) var toastMessage: String?
    @Published private(set) var libraryDialogOpen = false

    let clipboard: ClipboardLibraryModel
    let prompts: PromptLibraryModel
    let credentials: CredentialLibraryModel
    let preferences: PreferencesStore
    let screenshotExtension = ScreenshotExtension()
    let translationExtension = TranslationExtension()
    let updateManager = UpdateManager()
    var clipboardMonitor: ClipboardMonitor?
    var onRequestClose: (() -> Void)?
    var focusArea: FocusArea = .other

    private var store: SQLiteClipStore?
    private var loadGeneration = UUID()
    private var toastDismissal: DispatchWorkItem?

    init(preferences: PreferencesStore, credentialStore: CredentialStore = CredentialStore(), store: SQLiteClipStore? = nil) {
        self.preferences = preferences
        self.store = store
        clipboard = ClipboardLibraryModel(store: store)
        prompts = PromptLibraryModel(preferences: preferences, store: store)
        credentials = CredentialLibraryModel(store: credentialStore)
        clipboard.app = self
        prompts.app = self
        credentials.app = self
    }

    func setSearchFocused(_ focused: Bool) {
        if focused { focusArea = .search }
        else if focusArea == .search { focusArea = .other }
    }

    func updateLibraryDialogState() {
        let isOpen = prompts.hasOpenDialog || credentials.hasOpenDialog
        if libraryDialogOpen != isOpen { libraryDialogOpen = isOpen }
    }

    func load() {
        let generation = UUID()
        loadGeneration = generation
        phase = .loading
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self, self.loadGeneration == generation else { return }
            do {
                if self.store == nil { self.store = try SQLiteClipStore() }
                self.clipboard.store = self.store
                self.prompts.store = self.store
                try self.clipboard.load()
                try self.prompts.load()
                self.phase = .ready
                self.clipboard.normalizeHistorySelection()
                self.prompts.normalizePromptSelection()
            } catch {
                self.phase = .failed(error.localizedDescription)
                self.announce("无法读取本地数据库")
            }
        }
    }

    func receive(_ captured: CapturedClip) {
        guard phase == .ready else { return }
        do {
            try clipboard.receive(captured)
        } catch {
            phase = .failed(error.localizedDescription)
            announce("无法写入剪贴板历史")
        }
    }

    func setClipboardFilter(_ filter: ClipFilter) {
        clipboard.setFilter(filter)
        if clipboard.isCredentialGroup { credentials.loadCredentials() }
    }

    func cycleClipboardFilter(_ offset: Int) {
        let filters = ClipFilter.allCases
        guard let current = filters.firstIndex(of: clipboard.filter) else { return }
        setClipboardFilter(filters[(current + offset + filters.count) % filters.count])
    }

    func moveClipboardSelection(_ offset: Int) {
        if clipboard.isCredentialGroup { credentials.moveSelection(offset) }
        else { clipboard.moveSelection(offset) }
    }

    func copyClipboardSelection() {
        if clipboard.isCredentialGroup { credentials.copyCredential() }
        else { clipboard.copySelection() }
    }

    func deleteClipboardSelection() {
        if clipboard.isCredentialGroup { credentials.requestDeleteSelection() }
        else { clipboard.deleteSelection() }
    }

    func beginPromptFromClipboard() {
        let item = clipboard.selectedItem
        prompts.beginCreatePrompt(prefilledBody: item?.fullText ?? item?.title ?? "")
    }

    func clearHistory() {
        do {
            let deleted = try clipboard.clearHistory()
            phase = .ready
            settingsOpen = false
            showToast("已清空 \(deleted) 条历史记录")
        } catch {
            showToast("清空失败，请重试")
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
}

func shortLibraryTitle(_ title: String) -> String {
    title.count > 14 ? String(title.prefix(14)) + "…" : title
}
