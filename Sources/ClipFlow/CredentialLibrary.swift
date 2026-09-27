import ClipFlowKit
import Foundation

extension AppModel {
    var isCredentialGroup: Bool { libraryMode == .history && filter == .apiKey }

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
            showToast("读取失败：\(error.localizedDescription)")
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
            showToast("请填写名称和 API Key / 密码")
            return
        }
        do {
            // Preserve the exact secret, including leading/trailing whitespace.
            let id = try credentialStore.save(
                id: editingCredentialID, title: title, secret: credentialDraftSecret
            )
            query = ""
            loadCredentials()
            selectedCredentialID = id
            cancelCredentialEditor()
            showToast("已保存到 API Key 分组")
        } catch {
            showToast("保存失败：\(error.localizedDescription)")
        }
    }

    func copyCredential() {
        guard let entry = selectedCredential, let clipboardMonitor else { return }
        do {
            let secret = try credentialStore.secret(id: entry.id)
            switch clipboardMonitor.write(secret: secret) {
            case .text: finishCopy(message: "已复制 API Key / 密码")
            case .failure: showToast("复制失败，请重试")
            case .image: break
            }
        } catch {
            showToast("读取失败：\(error.localizedDescription)")
        }
    }

    func confirmDeleteCredential() {
        guard let entry = selectedCredential else { return }
        do {
            try credentialStore.delete(id: entry.id)
            credentialDeleteConfirmationOpen = false
            loadCredentials()
            showToast("已删除 API Key / 密码")
        } catch {
            showToast("删除失败：\(error.localizedDescription)")
        }
    }
}
