import AppKit
import ClipFlowKit
import Combine

enum QuotaProviderFilter: String, CaseIterable, Identifiable {
    case all
    case codex
    case antigravity
    case gemini
    case deepseek

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "全部"
        case .codex: return QuotaProvider.codex.title
        case .antigravity: return QuotaProvider.antigravity.title
        case .gemini: return QuotaProvider.gemini.title
        case .deepseek: return QuotaProvider.deepseek.title
        }
    }

    func includes(_ provider: QuotaProvider) -> Bool {
        self == .all || rawValue == provider.rawValue
    }
}

enum GeminiAuthMode: String, CaseIterable, Identifiable {
    case webOAuth
    case localCLI

    var id: Self { self }

    var title: String {
        switch self {
        case .webOAuth: return "Google 网页登录"
        case .localCLI: return "本机 CLI 凭证"
        }
    }
}

@MainActor
final class QuotaMonitorModel: ObservableObject {
    private static let snapshotMaxAge: TimeInterval = 5 * 60

    @Published private var state: QuotaPersistedState
    @Published var filter: QuotaProviderFilter = .all
    @Published private(set) var refreshingAccountIDs: Set<String> = []
    @Published private(set) var errorsByAccountID: [String: String] = [:]
    @Published private(set) var storageError: String?
    @Published private(set) var editorOpen = false
    @Published private(set) var editingAccountID: String?
    @Published private(set) var isChoosingDirectory = false
    @Published var draftProvider: QuotaProvider = .codex
    @Published var draftLabel = ""
    @Published var draftPlanOverride = ""
    @Published var draftCustomHomePath = ""
    @Published var draftCustomBinaryPath = ""
    @Published var draftCustomBaseURL = ""
    @Published var draftAPIKey = ""
    @Published private(set) var draftHasSavedAPIKey = false
    @Published var draftGeminiAuthMode: GeminiAuthMode = .webOAuth
    @Published private(set) var isAuthenticatingGemini = false
    @Published private(set) var draftPendingGeminiAuth: GeminiWebAuthResult?
    @Published private(set) var draftHasSavedGeminiOAuth = false
    @Published private(set) var editorError: String?

    var onExternalAuthCompleted: (() -> Void)?

    private let store: JSONFileStore<QuotaPersistedState>
    private let fetcher: any QuotaFetching
    private let credentials: CredentialStore
    private let geminiAuthenticator: any GeminiWebAuthenticating
    private let now: () -> Date
    private let stateReadFailed: Bool
    private var refreshTasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var geminiAuthTask: (id: UUID, task: Task<Void, Never>)?
    private var directoryPicker: NSOpenPanel?
    private(set) var requestedAccountIDs: Set<String> = []

    var accounts: [QuotaAccountConfig] { state.accounts }
    var snapshots: [String: QuotaAccountSnapshot] { state.snapshots }
    var history: [String: [QuotaSample]] { state.history }
    var isRefreshing: Bool { !refreshingAccountIDs.isEmpty }
    var visibleAccounts: [QuotaAccountConfig] { accounts.filter { filter.includes($0.provider) } }
    var canRestoreBuiltInAccounts: Bool { !missingBuiltInAccounts.isEmpty }

    private var missingBuiltInAccounts: [QuotaAccountConfig] {
        QuotaAccountConfig.defaultAccounts.filter { builtIn in !accounts.contains(where: { $0.id == builtIn.id }) }
    }

    init(
        fileURL: URL? = nil,
        fetcher: (any QuotaFetching)? = nil,
        credentials: CredentialStore = CredentialStore(service: CLIQuotaFetcher.defaultCredentialService),
        geminiAuthenticator: any GeminiWebAuthenticating = GeminiWebOAuthAuthenticator(),
        now: @escaping () -> Date = Date.init
    ) {
        let url = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ClipFlow/Quota/state.json")
        store = JSONFileStore(fileURL: url)
        self.credentials = credentials
        self.fetcher = fetcher ?? CLIQuotaFetcher(credentials: credentials)
        self.geminiAuthenticator = geminiAuthenticator
        self.now = now
        do {
            state = try store.exists ? store.load() : .empty
            stateReadFailed = false
        } catch {
            state = .empty
            stateReadFailed = true
            storageError = "无法读取本地额度数据：\(error.localizedDescription)"
        }
    }

    func refreshStaleAccounts(previouslyRequestedAccountIDs: Set<String> = []) {
        requestedAccountIDs.formUnion(previouslyRequestedAccountIDs)
        let date = now()
        for account in accounts where refreshTasks[account.id] == nil {
            if let snapshot = snapshots[account.id] {
                guard date.timeIntervalSince(snapshot.fetchedAt) > Self.snapshotMaxAge else { continue }
            } else {
                guard !requestedAccountIDs.contains(account.id) else { continue }
            }
            refresh(accountID: account.id)
        }
    }

    func refreshAll() {
        for account in accounts { refresh(accountID: account.id) }
    }

    func refresh(accountID: String) {
        guard let account = accounts.first(where: { $0.id == accountID }) else { return }
        requestedAccountIDs.insert(accountID)
        refreshTasks[accountID]?.task.cancel()
        let requestID = UUID()
        refreshingAccountIDs.insert(accountID)
        let fetcher = self.fetcher
        let task = Task { [weak self] in
            let result: Result<QuotaAccountSnapshot, Error>
            do {
                try Task.checkCancellation()
                result = .success(try await fetcher.fetchQuota(for: account))
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled else { return }
            self?.finishRefresh(accountID: accountID, requestID: requestID, result: result)
        }
        refreshTasks[accountID] = (requestID, task)
    }

    private func finishRefresh(accountID: String, requestID: UUID, result: Result<QuotaAccountSnapshot, Error>) {
        guard refreshTasks[accountID]?.id == requestID else { return }
        refreshTasks[accountID] = nil
        refreshingAccountIDs.remove(accountID)
        switch result {
        case .success(let snapshot):
            errorsByAccountID[accountID] = nil
            var updated = state
            updated.snapshots[accountID] = snapshot
            for bucket in snapshot.buckets {
                let key = QuotaPersistedState.historyKey(accountID: accountID, bucketID: bucket.id)
                var samples = updated.history[key, default: []]
                let sample = QuotaSample(timestamp: snapshot.fetchedAt, usedPercent: bucket.usedPercent)
                if let last = samples.last,
                   abs(sample.timestamp.timeIntervalSince(last.timestamp)) < 60,
                   abs(sample.usedPercent - last.usedPercent) < 0.05 { continue }
                samples.append(sample)
                updated.history[key] = Array(samples.suffix(96))
            }
            // Keep freshly fetched data on screen if the disk write fails.
            state = updated
            persist(updated)
        case .failure(let error):
            if !(error is CancellationError), (error as? QuotaError) != .cancelled {
                errorsByAccountID[accountID] = error.localizedDescription
            }
        }
    }

    func beginAddAccount() {
        cancelEditor()
        switch filter {
        case .antigravity: draftProvider = .antigravity
        case .gemini: draftProvider = .gemini
        case .deepseek: draftProvider = .deepseek
        case .all, .codex: draftProvider = .codex
        }
        editorOpen = true
    }

    func beginEditAccount(_ account: QuotaAccountConfig) {
        guard let account = accounts.first(where: { $0.id == account.id }) else { return }
        cancelEditor()
        editingAccountID = account.id
        draftProvider = account.provider
        draftLabel = account.label
        draftPlanOverride = account.planOverride ?? ""
        draftCustomHomePath = account.customHomePath ?? ""
        draftCustomBinaryPath = account.customBinaryPath ?? ""
        draftCustomBaseURL = account.customBaseURL ?? ""
        draftAPIKey = ""
        draftHasSavedAPIKey = account.provider.usesAPIKey && account.credentialID != nil
        draftHasSavedGeminiOAuth = account.provider == .gemini && account.credentialID != nil
        draftGeminiAuthMode = (account.provider == .gemini && account.credentialID == nil) ? .localCLI : .webOAuth
        editorOpen = true
    }

    func startGeminiWebLogin() {
        guard editorOpen, draftProvider == .gemini, !isAuthenticatingGemini else { return }
        cancelGeminiWebLogin()
        editorError = nil
        isAuthenticatingGemini = true
        let requestID = UUID()
        let authenticator = geminiAuthenticator
        let binaryPath = nonempty(draftCustomBinaryPath)
        let task = Task { [weak self] in
            let result: Result<GeminiWebAuthResult, Error>
            do {
                try Task.checkCancellation()
                result = .success(try await authenticator.authenticate(customBinaryPath: binaryPath))
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled else { return }
            self?.finishGeminiWebLogin(requestID: requestID, result: result)
        }
        geminiAuthTask = (requestID, task)
    }

    func cancelGeminiWebLogin() {
        geminiAuthTask?.task.cancel()
        geminiAuthTask = nil
        isAuthenticatingGemini = false
    }

    private func finishGeminiWebLogin(requestID: UUID, result: Result<GeminiWebAuthResult, Error>) {
        guard geminiAuthTask?.id == requestID else { return }
        geminiAuthTask = nil
        isAuthenticatingGemini = false
        guard editorOpen, draftProvider == .gemini else { return }
        switch result {
        case .success(let authResult):
            draftPendingGeminiAuth = authResult
            editorError = nil
            if nonempty(draftLabel) == nil {
                draftLabel = authResult.email ?? "Google 账号"
            }
        case .failure(let error):
            if !(error is CancellationError), (error as? QuotaError) != .cancelled {
                editorError = error.localizedDescription
            }
        }
        onExternalAuthCompleted?()
    }

    @discardableResult
    func saveAccountDraft() -> String? {
        guard editorOpen, !isChoosingDirectory, !isAuthenticatingGemini else { return nil }
        guard let label = nonempty(draftLabel) else {
            editorError = "请输入显示名称。"
            return nil
        }
        var updated = state
        var changedSource = false
        var newlyCreatedCredentialID: String?
        var obsoleteCredentialID: String?
        let savedAccountID: String
        let planOverride = nonempty(draftPlanOverride)

        if draftProvider.usesAPIKey {
            let baseURL = nonempty(draftCustomBaseURL)
            if let baseURL {
                do {
                    _ = try DeepSeekQuotaParser.endpoint(baseURL: baseURL)
                } catch {
                    editorError = error.localizedDescription
                    return nil
                }
            }
            let secret = draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if secret.rangeOfCharacter(from: .newlines) != nil {
                editorError = "API Key 不能包含换行符。"
                return nil
            }

            if let id = editingAccountID, let index = updated.accounts.firstIndex(where: { $0.id == id }) {
                let previous = updated.accounts[index]
                var credentialID = previous.credentialID
                if secret.isEmpty {
                    guard credentialID != nil else {
                        editorError = "请输入 \(draftProvider.title) API Key。"
                        return nil
                    }
                } else {
                    do {
                        let saved = try saveCredential(existingID: credentialID, title: "\(draftProvider.title) · \(label)", secret: secret)
                        if credentialID == nil || saved != credentialID { newlyCreatedCredentialID = saved }
                        credentialID = saved
                        changedSource = true
                    } catch {
                        editorError = "保存 API Key 失败：\(error.localizedDescription)"
                        return nil
                    }
                }
                changedSource = changedSource || previous.customBaseURL != baseURL
                updated.accounts[index].label = label
                updated.accounts[index].planOverride = planOverride
                updated.accounts[index].customHomePath = nil
                updated.accounts[index].customBinaryPath = nil
                updated.accounts[index].customBaseURL = baseURL
                updated.accounts[index].credentialID = credentialID
                if changedSource { removeCachedData(for: id, from: &updated) }
                savedAccountID = id
            } else {
                guard !secret.isEmpty else {
                    editorError = "请输入 \(draftProvider.title) API Key。"
                    return nil
                }
                let savedCredentialID: String
                do {
                    savedCredentialID = try credentials.save(id: nil, title: "\(draftProvider.title) · \(label)", secret: secret)
                    newlyCreatedCredentialID = savedCredentialID
                } catch {
                    editorError = "保存 API Key 失败：\(error.localizedDescription)"
                    return nil
                }
                let newID = UUID().uuidString
                updated.accounts.append(QuotaAccountConfig(
                    id: newID,
                    provider: draftProvider,
                    label: label,
                    planOverride: planOverride,
                    customBaseURL: baseURL,
                    credentialID: savedCredentialID,
                    isBuiltIn: false
                ))
                savedAccountID = newID
            }
        } else if draftProvider == .gemini && draftGeminiAuthMode == .webOAuth {
            if let id = editingAccountID, let index = updated.accounts.firstIndex(where: { $0.id == id }) {
                let previous = updated.accounts[index]
                var credentialID = previous.credentialID
                if let pending = draftPendingGeminiAuth {
                    do {
                        let saved = try saveCredential(existingID: credentialID, title: "\(draftProvider.title) · \(label)", secret: pending.credentialsJSON)
                        if credentialID == nil || saved != credentialID { newlyCreatedCredentialID = saved }
                        credentialID = saved
                        changedSource = true
                    } catch {
                        editorError = "保存 Google 授权凭证失败：\(error.localizedDescription)"
                        return nil
                    }
                } else {
                    guard credentialID != nil else {
                        editorError = "请先点击「打开浏览器登录 Google」完成授权。"
                        return nil
                    }
                }
                changedSource = changedSource || previous.customHomePath != nil || previous.customBinaryPath != nil
                updated.accounts[index].label = label
                updated.accounts[index].planOverride = planOverride
                updated.accounts[index].customHomePath = nil
                updated.accounts[index].customBinaryPath = nil
                updated.accounts[index].customBaseURL = nil
                updated.accounts[index].credentialID = credentialID
                if changedSource { removeCachedData(for: id, from: &updated) }
                savedAccountID = id
            } else {
                guard let pending = draftPendingGeminiAuth else {
                    editorError = "请先点击「打开浏览器登录 Google」完成授权。"
                    return nil
                }
                let savedCredentialID: String
                do {
                    savedCredentialID = try credentials.save(id: nil, title: "\(draftProvider.title) · \(label)", secret: pending.credentialsJSON)
                    newlyCreatedCredentialID = savedCredentialID
                } catch {
                    editorError = "保存 Google 授权凭证失败：\(error.localizedDescription)"
                    return nil
                }
                let newID = UUID().uuidString
                updated.accounts.append(QuotaAccountConfig(
                    id: newID,
                    provider: .gemini,
                    label: label,
                    planOverride: planOverride,
                    credentialID: savedCredentialID,
                    isBuiltIn: false
                ))
                savedAccountID = newID
            }
        } else {
            let homePath = nonempty(draftCustomHomePath)
            let binaryPath = nonempty(draftCustomBinaryPath)
            if let id = editingAccountID, let index = updated.accounts.firstIndex(where: { $0.id == id }) {
                let previous = updated.accounts[index]
                if let previousCredID = previous.credentialID {
                    obsoleteCredentialID = previousCredID
                    changedSource = true
                }
                changedSource = changedSource || previous.customHomePath != homePath || previous.customBinaryPath != binaryPath
                updated.accounts[index].label = label
                updated.accounts[index].planOverride = planOverride
                updated.accounts[index].customHomePath = homePath
                updated.accounts[index].customBinaryPath = binaryPath
                updated.accounts[index].customBaseURL = nil
                updated.accounts[index].credentialID = nil
                if changedSource { removeCachedData(for: id, from: &updated) }
                savedAccountID = id
            } else {
                let newID = UUID().uuidString
                updated.accounts.append(QuotaAccountConfig(
                    id: newID,
                    provider: draftProvider,
                    label: label,
                    planOverride: planOverride,
                    customHomePath: homePath,
                    customBinaryPath: binaryPath,
                    isBuiltIn: false
                ))
                savedAccountID = newID
            }
        }

        guard persist(updated) else {
            if let newlyCreatedCredentialID { try? credentials.delete(id: newlyCreatedCredentialID) }
            editorError = storageError
            return nil
        }
        if let obsoleteCredentialID { try? credentials.delete(id: obsoleteCredentialID) }
        if let id = editingAccountID, changedSource { cancelRefreshAndClearError(id) }
        if !filter.includes(draftProvider) { filter = .all }
        state = updated
        cancelEditor()
        return savedAccountID
    }

    func deleteAccount(id: String) {
        let removedCredentialID = accounts.first(where: { $0.id == id })?.credentialID
        var updated = state
        updated.accounts.removeAll { $0.id == id }
        guard updated.accounts != accounts else { return }
        removeCachedData(for: id, from: &updated)
        guard persist(updated) else { return }
        if let removedCredentialID { try? credentials.delete(id: removedCredentialID) }
        cancelRefreshAndClearError(id)
        state = updated
        if editingAccountID == id { cancelEditor() }
    }

    func restoreBuiltInAccounts() {
        let missing = missingBuiltInAccounts
        guard !missing.isEmpty else { return }
        var updated = state
        updated.accounts.append(contentsOf: missing)
        guard persist(updated) else { return }
        filter = .all
        state = updated
    }

    func cancelEditor() {
        cancelGeminiWebLogin()
        editorOpen = false
        directoryPicker?.cancel(nil)
        directoryPicker = nil
        isChoosingDirectory = false
        editingAccountID = nil
        draftProvider = .codex
        draftLabel = ""
        draftPlanOverride = ""
        draftCustomHomePath = ""
        draftCustomBinaryPath = ""
        draftCustomBaseURL = ""
        draftAPIKey = ""
        draftHasSavedAPIKey = false
        draftGeminiAuthMode = .webOAuth
        draftPendingGeminiAuth = nil
        draftHasSavedGeminiOAuth = false
        editorError = nil
    }

    private func saveCredential(existingID: String?, title: String, secret: String) throws -> String {
        if let existingID {
            if let updated = try? credentials.save(id: existingID, title: title, secret: secret) {
                return updated
            }
        }
        return try credentials.save(id: nil, title: title, secret: secret)
    }

    func chooseDirectoryForDraft() {
        guard editorOpen, !isChoosingDirectory else { return }
        let picker = NSOpenPanel()
        picker.title = draftProvider == .gemini ? "选择 Gemini 凭证目录或文件" : "选择账号配置目录"
        picker.prompt = "选择"
        picker.canChooseFiles = draftProvider == .gemini
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.showsHiddenFiles = true
        if let path = nonempty(draftCustomHomePath) {
            let expanded = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), !isDir.boolValue {
                picker.directoryURL = url.deletingLastPathComponent()
            } else {
                picker.directoryURL = URL(fileURLWithPath: expanded, isDirectory: true)
            }
        }
        directoryPicker = picker
        isChoosingDirectory = true
        let result = picker.runModal()
        guard directoryPicker === picker else { return }
        directoryPicker = nil
        isChoosingDirectory = false
        if result == .OK, let url = picker.url { draftCustomHomePath = url.path }
    }

    func cancelAll() {
        for request in refreshTasks.values { request.task.cancel() }
        refreshTasks.removeAll()
        refreshingAccountIDs.removeAll()
        errorsByAccountID.removeAll()
        cancelEditor()
    }

    func shutdown() {
        cancelAll()
    }

    private func removeCachedData(for id: String, from state: inout QuotaPersistedState) {
        state.snapshots[id] = nil
        state.history = state.history.filter { !$0.key.hasPrefix("\(id)::") }
    }

    private func cancelRefreshAndClearError(_ id: String) {
        refreshTasks.removeValue(forKey: id)?.task.cancel()
        requestedAccountIDs.remove(id)
        refreshingAccountIDs.remove(id)
        errorsByAccountID[id] = nil
    }

    @discardableResult
    private func persist(_ value: QuotaPersistedState) -> Bool {
        guard !stateReadFailed else { return false }
        do {
            try store.save(value)
            storageError = nil
            return true
        } catch {
            storageError = "无法保存本地额度数据：\(error.localizedDescription)"
            return false
        }
    }

    private func nonempty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
