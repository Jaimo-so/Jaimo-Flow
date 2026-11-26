import AppKit
import ClipFlowKit
@testable import ClipFlow

enum TestError: Error { case failed(String) }
func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw TestError.failed(message) }
}

try MainActor.assumeIsolated {
    _ = NSApplication.shared
    let service = "com.clipflow.credentials.selftest.\(UUID().uuidString)"
    let store = CredentialStore(service: service)
    let defaults = UserDefaults(suiteName: service)!
    let preferences = PreferencesStore(defaults: defaults)
    preferences.closeAfterCopy = false
    let model = AppModel(preferences: preferences, credentialStore: store)
    let pasteboard = NSPasteboard(name: .init(service))
    let monitor = ClipboardMonitor(pasteboard: pasteboard)
    model.clipboardMonitor = monitor
    var captures: [CapturedClip] = []
    monitor.onCapture = { captures.append($0) }
    defer {
        monitor.stop()
        pasteboard.releaseGlobally()
        defaults.removePersistentDomain(forName: service)
        for entry in (try? store.loadEntries()) ?? [] { try? store.delete(id: entry.id) }
    }

    model.setClipboardFilter(.apiKey)
    try require(model.clipboard.isCredentialGroup && model.credentials.credentialEntries.count == 0, "空分组加载失败")
    model.credentials.beginCreateCredential()
    model.credentials.saveCredentialDraft()
    try require(model.credentials.credentialEditorOpen && store.loadEntries().isEmpty, "空表单被保存")
    model.credentials.credentialDraftTitle = "  Development  "
    let secret = "  fake-key-中文-🔑\t "
    model.credentials.credentialDraftSecret = secret
    model.credentials.saveCredentialDraft()
    let id = try store.loadEntries().first!.id
    try require(!model.credentials.credentialEditorOpen && model.credentials.credentialDraftSecret.isEmpty, "保存后未清理编辑内容")
    try require(model.credentials.selectedCredential?.title == "Development", "名称没有保存")
    try require(try CredentialStore(service: service).secret(id: id) == secret, "重新读取时密钥发生变化")
    try require(model.clipboard.filteredItems.isEmpty && model.clipboard.count(for: .all) == 0, "密钥混入普通历史")

    model.clipboard.query = "development"
    try require(model.credentials.filteredCredentials.count == 1, "名称搜索失败")
    model.clipboard.query = "fake-key"
    try require(model.credentials.filteredCredentials.isEmpty, "搜索暴露了密钥内容")
    model.clipboard.query = ""
    model.credentials.beginEditCredential()
    try require(model.credentials.credentialDraftSecret == secret, "编辑没有读取原始内容")
    model.credentials.credentialDraftTitle = "Production"
    model.credentials.credentialDraftSecret = " new-password "
    model.credentials.saveCredentialDraft()
    try require(try store.loadEntries().count == 1 && store.secret(id: id) == " new-password ", "编辑创建了重复条目或损坏内容")

    monitor.start()
    model.copyClipboardSelection()
    try require(pasteboard.string(forType: .string) == " new-password ", "复制内容错误")
    try require(pasteboard.types?.contains(.init("org.nspasteboard.ConcealedType")) == true, "缺少敏感剪贴板标记")
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    try require(captures.isEmpty, "密钥被再次收录到普通历史")
    // Verify concealed content from another writer is also ignored.
    let concealed = NSPasteboardItem()
    concealed.setString("external-test-secret", forType: .string)
    concealed.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
    pasteboard.clearContents()
    pasteboard.writeObjects([concealed])
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    try require(captures.isEmpty, "外部敏感剪贴板内容被收录")
    pasteboard.clearContents()
    pasteboard.setString("ordinary text", forType: .string)
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    try require(captures.count == 1, "普通历史监听受到影响")

    model.credentials.beginEditCredential()
    model.credentials.cancelCredentialEditor()
    try require(model.credentials.credentialDraftSecret.isEmpty, "取消后没有清理密钥")
    model.deleteClipboardSelection()
    try require(model.credentials.credentialDeleteConfirmationOpen && store.loadEntries().count == 1, "删除没有等待确认")
    model.credentials.confirmDeleteCredential()
    try require(try store.loadEntries().isEmpty && model.credentials.credentialEntries.isEmpty, "确认删除失败")

    // A failed update must preserve the draft for retry, never report success.
    model.credentials.beginCreateCredential()
    model.credentials.editingCredentialID = UUID().uuidString
    model.credentials.credentialDraftTitle = "Missing"
    model.credentials.credentialDraftSecret = "dummy"
    model.credentials.saveCredentialDraft()
    try require(model.credentials.credentialEditorOpen && model.credentials.credentialDraftSecret == "dummy", "失败时丢失草稿")
    model.credentials.cancelCredentialEditor()
    print("PASS: API Key 创建、持久化、编辑、名称搜索、精确复制、敏感内容隔离、确认删除与失败保留草稿")
}
