import ClipFlowKit
import Combine
import Foundation

@MainActor
final class CredentialLibraryModel: ObservableObject {
    @Published var credentialEntries: [CredentialEntry] = []
    @Published var credentialError: String?
    @Published var selectedCredentialID: String?
    @Published var credentialEditorOpen = false {
        didSet { app?.updateLibraryDialogState() }
    }
    @Published var credentialDeleteConfirmationOpen = false {
        didSet { app?.updateLibraryDialogState() }
    }
    @Published var editingCredentialID: String?
    @Published var credentialDraftTitle = ""
    @Published var credentialDraftSecret = ""
    private let credentialStore: CredentialStore

    weak var app: AppModel?

    init(store: CredentialStore) {
        credentialStore = store
    }

    var query: String { app?.clipboard.query ?? "" }

    var hasOpenDialog: Bool {
        credentialEditorOpen || credentialDeleteConfirmationOpen
    }

    func resetSearchSelection() {
        selectedCredentialID = filteredCredentials.first?.id
    }

    func moveSelection(_ offset: Int) {
        let visible = filteredCredentials
        guard !visible.isEmpty else { return }
        let current = visible.firstIndex { $0.id == selectedCredentialID } ?? 0
        selectedCredentialID = visible[min(max(0, current + offset), visible.count - 1)].id
    }

    func requestDeleteSelection() {
        credentialDeleteConfirmationOpen = selectedCredential != nil
    }

    var filteredCredentials: [CredentialEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return credentialEntries.filter {
            needle.isEmpty || $0.title.localizedCaseInsensitiveContains(needle)
        }
    }

    var selectedCredential: CredentialEntry? {
        filteredCredentials.first { $0.id == selectedCredentialID } ?? filteredCredentials.first
    }

    func loadCredentials() {
        do {
            credentialEntries = try credentialStore.loadEntries()
            credentialError = nil
            selectedCredentialID = selectedCredential?.id
        } catch {
            credentialEntries = []
            credentialError = error.localizedDescription
        }
    }

    func beginCreateCredential() {
        editingCredentialID = nil
        credentialDraftTitle = ""
        credentialDraftSecret = ""
        credentialEditorOpen = true
    }

    func beginEditCredential() {
        guard let entry = selectedCredential else { return }
        do {
            let secret = try credentialStore.secret(id: entry.id)
            editingCredentialID = entry.id
            credentialDraftTitle = entry.title
            credentialDraftSecret = secret
            credentialEditorOpen = true
        } catch {
            app?.showToast("读取失败：\(error.localizedDescription)")
        }
    }

    func cancelCredentialEditor() {
        credentialEditorOpen = false
        editingCredentialID = nil
        credentialDraftTitle = ""
        credentialDraftSecret = ""
    }

    func saveCredentialDraft() {
        let title = credentialDraftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !credentialDraftSecret.isEmpty else {
            app?.showToast("请填写名称和 API Key / 密码")
            return
        }
        do {
            // Preserve the exact secret, including leading/trailing whitespace.
            let id = try credentialStore.save(
                id: editingCredentialID, title: title, secret: credentialDraftSecret
            )
            app?.clipboard.query = ""
            loadCredentials()
            selectedCredentialID = id
            cancelCredentialEditor()
            app?.showToast("已保存到 API Key 分组")
        } catch {
            app?.showToast("保存失败：\(error.localizedDescription)")
        }
    }

    func copyCredential() {
        guard let entry = selectedCredential, let clipboardMonitor = app?.clipboardMonitor else { return }
        do {
            let secret = try credentialStore.secret(id: entry.id)
            switch clipboardMonitor.write(secret: secret) {
            case .text: app?.finishCopy(message: "已复制 API Key / 密码")
            case .failure: app?.showToast("复制失败，请重试")
            case .image: break
            }
        } catch {
            app?.showToast("读取失败：\(error.localizedDescription)")
        }
    }

    func confirmDeleteCredential() {
        guard let entry = selectedCredential else { return }
        do {
            try credentialStore.delete(id: entry.id)
            credentialDeleteConfirmationOpen = false
            loadCredentials()
            app?.showToast("已删除 API Key / 密码")
        } catch {
            app?.showToast("删除失败：\(error.localizedDescription)")
        }
    }
}
