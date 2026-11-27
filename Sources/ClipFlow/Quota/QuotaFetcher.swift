import ClipFlowKit
import Darwin
import Foundation

typealias QuotaHTTPTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

protocol QuotaFetching: Sendable {
    func fetchQuota(for account: QuotaAccountConfig) async throws -> QuotaAccountSnapshot
}

struct CLIQuotaFetcher: QuotaFetching {
    static let defaultCredentialService = "com.clipflow.mac.quota"

    private let timeoutSeconds: TimeInterval
    private let credentials: CredentialStore
    private let transport: QuotaHTTPTransport
    private let now: @Sendable () -> Date

    init(
        timeoutSeconds: TimeInterval = 20,
        credentials: CredentialStore = CredentialStore(service: CLIQuotaFetcher.defaultCredentialService),
        transport: @escaping QuotaHTTPTransport = { try await CLIQuotaFetcher.defaultTransport($0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.credentials = credentials
        self.transport = transport
        self.now = now
    }

    func fetchQuota(for account: QuotaAccountConfig) async throws -> QuotaAccountSnapshot {
        switch account.provider {
        case .codex:
            return try await fetchCodex(for: account)
        case .antigravity:
            return try await fetchAntigravity(for: account)
        case .gemini:
            return try await fetchGemini(for: account)
        case .deepseek:
            return try await fetchDeepSeek(for: account)
        }
    }

    static func defaultTransport(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.invalidOutput("服务端未返回有效 HTTP 响应")
        }
        return (data, http)
    }

    // MARK: - Codex (`codex app-server --listen stdio://`)

    private func fetchCodex(for account: QuotaAccountConfig) async throws -> QuotaAccountSnapshot {
        guard let executable = Self.resolveExecutable(
            named: account.provider.defaultBinaryName,
            overridePath: account.customBinaryPath
        ) else {
            throw QuotaError.binaryNotFound(.codex)
        }

        return try await runCancellableBlocking { cancellation in
            let process = Process()
            process.executableURL = executable
            process.arguments = ["app-server", "--listen", "stdio://"]
            var env = Self.augmentedEnvironment()
            if let path = account.customHomePath {
                env["CODEX_HOME"] = Self.expandTilde(path)
            }
            process.environment = env

            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr

            try cancellation.check()
            try Self.launch(process, name: "codex")
            let input = stdin.fileHandleForWriting
            defer {
                try? input.close()
                Self.stop(process)
            }
            // A child that exits between launch and a request must not signal the app.
            _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
            func send(_ line: String) throws {
                try input.write(contentsOf: Data((line + "\n").utf8))
            }

            let output = CLIOutput(stdout)
            let diagnostics = CLIOutput(stderr)
            try send(#"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"jaimo-flow","title":"Jaimo Flow","version":"1.0.0"}}}"#)
            var rateLimits: Data?
            var accountData: Data?
            let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
            while ProcessInfo.processInfo.systemUptime < deadline {
                try cancellation.check()
                output.drain()
                diagnostics.drain()
                while let line = output.popLine() {
                    guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let id = json["id"] as? Int else { continue }
                    if (id == 1 || id == 2), let error = json["error"] as? [String: Any] {
                        let message = error["message"] as? String ?? "服务未返回额度结果"
                        throw QuotaError.commandFailed("Codex 查询失败：\(message)")
                    }
                    switch id {
                    case 1:
                        try send(#"{"method":"initialized"}"#)
                        try send(#"{"id":2,"method":"account/rateLimits/read"}"#)
                        try send(#"{"id":3,"method":"account/read","params":{"refreshToken":false}}"#)
                    case 2: rateLimits = line
                    case 3: accountData = line
                    default: break
                    }
                }
                if rateLimits != nil, accountData != nil { break }
                if !process.isRunning && output.isAtEnd { break }
                Thread.sleep(forTimeInterval: 0.03)
            }

            try cancellation.check()
            if let rateLimits {
                return try CodexQuotaParser.parse(
                    accountID: account.id, rateLimitsJSON: rateLimits, accountJSON: accountData
                )
            }
            if ProcessInfo.processInfo.systemUptime >= deadline { throw QuotaError.timedOut(.codex) }
            throw diagnostics.failure(provider: .codex, fallback: "请先在终端运行 codex login")
        }
    }

    // MARK: - Antigravity (`agy --print-timeout 18s --output-format json -p "/usage"`)

    private func fetchAntigravity(for account: QuotaAccountConfig) async throws -> QuotaAccountSnapshot {
        guard let executable = Self.resolveExecutable(
            named: account.provider.defaultBinaryName,
            overridePath: account.customBinaryPath
        ) else {
            throw QuotaError.binaryNotFound(.antigravity)
        }

        return try await runCancellableBlocking { cancellation in
            let process = Process()
            process.executableURL = executable
            process.arguments = [
                "--print-timeout", "\(max(1, Int(timeoutSeconds) - 2))s",
                "--output-format", "json",
                "-p", "/usage"
            ]
            var env = Self.augmentedEnvironment()
            if let path = account.customHomePath {
                env["HOME"] = Self.expandTilde(path)
            }
            process.environment = env

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = FileHandle.nullDevice

            try cancellation.check()
            try Self.launch(process, name: "agy")
            defer { Self.stop(process) }

            let output = CLIOutput(stdout)
            let diagnostics = CLIOutput(stderr)
            let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
            while process.isRunning {
                try cancellation.check()
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw QuotaError.timedOut(.antigravity)
                }
                output.drain()
                diagnostics.drain()
                Thread.sleep(forTimeInterval: 0.03)
            }
            try cancellation.check()
            output.drain()
            diagnostics.drain()

            if !output.data.isEmpty {
                do {
                    let snapshot = try AntigravityQuotaParser.parse(accountID: account.id, jsonData: output.data)
                    if process.terminationStatus == 0 { return snapshot }
                } catch {
                    if process.terminationStatus == 0 || diagnostics.data.isEmpty { throw error }
                }
            }
            throw diagnostics.failure(provider: .antigravity, fallback: "请先在终端运行 agy 登录")
        }
    }

    // MARK: - DeepSeek (`GET /user/balance`)

    private func fetchDeepSeek(for account: QuotaAccountConfig) async throws -> QuotaAccountSnapshot {
        guard let credentialID = account.credentialID, !credentialID.isEmpty else {
            throw QuotaError.commandFailed("未配置 DeepSeek API Key，请点击「编辑」填写 API Key。")
        }
        let apiKey: String
        do {
            apiKey = try credentials.secret(id: credentialID).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw QuotaError.commandFailed("无法从钥匙串读取 DeepSeek API Key，请点击「编辑」重新填写。")
        }
        guard !apiKey.isEmpty else {
            throw QuotaError.commandFailed("DeepSeek API Key 为空，请点击「编辑」重新填写。")
        }

        let endpoint = try DeepSeekQuotaParser.endpoint(baseURL: account.customBaseURL)
        var request = URLRequest(url: endpoint, timeoutInterval: timeoutSeconds)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await performHTTPRequest(request, provider: .deepseek)
        switch response.statusCode {
        case 200...299:
            return try DeepSeekQuotaParser.parse(accountID: account.id, jsonData: data, fetchedAt: now())
        case 401, 402, 403:
            throw QuotaError.commandFailed("DeepSeek API Key 无效或无权限（HTTP \(response.statusCode)），请在编辑账号中检查密钥。")
        case 429:
            throw QuotaError.commandFailed("DeepSeek 查询过于频繁（HTTP 429），请稍后重试。")
        default:
            let detail = DeepSeekQuotaParser.parseErrorMessage(from: data) ?? "HTTP \(response.statusCode)"
            throw QuotaError.commandFailed("DeepSeek 查询失败：\(detail)")
        }
    }

    // MARK: - Gemini CLI OAuth (`cloudcode-pa.googleapis.com`)

    private static let geminiLoadCodeAssistURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    private static let geminiRetrieveQuotaURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
    private static let googleOAuthTokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    private struct GeminiOAuthCredentials {
        var rawObject: [String: Any]
        var accessToken: String?
        var refreshToken: String?
        var idToken: String?
        var expiryDate: Date?
        var clientID: String?
        var clientSecret: String?
    }

    private enum GeminiCredentialStorage {
        case keychain(id: String, title: String)
        case file(URL)
    }

    private func fetchGemini(for account: QuotaAccountConfig) async throws -> QuotaAccountSnapshot {
        var creds: GeminiOAuthCredentials
        let storage: GeminiCredentialStorage
        if let credentialID = account.credentialID, !credentialID.isEmpty {
            let storedJSON: String
            do {
                storedJSON = try credentials.secret(id: credentialID)
            } catch {
                throw QuotaError.commandFailed("无法从钥匙串读取 Gemini Google 登录凭证，请点击「编辑」重新登录。")
            }
            creds = try Self.parseGeminiCredentialsData(Data(storedJSON.utf8))
            storage = .keychain(id: credentialID, title: "\(account.provider.title) · \(account.label)")
        } else {
            let paths = Self.resolveGeminiCredentialPaths(customHomePath: account.customHomePath)
            creds = try Self.loadGeminiCredentials(at: paths.credentialsURL, settingsURL: paths.settingsURL)
            storage = .file(paths.credentialsURL)
        }

        var refreshed = false
        let currentDate = now()
        let needsRefresh = creds.accessToken == nil
            || (creds.expiryDate.map { $0 <= currentDate.addingTimeInterval(60) } ?? false)
        if needsRefresh {
            creds = try await refreshGeminiCredentials(creds, storage: storage, account: account)
            refreshed = true
        }

        guard let initialToken = creds.accessToken else {
            throw QuotaError.commandFailed("Gemini OAuth 凭证缺少 access_token，请重新使用 Google 登录。")
        }

        var token = initialToken
        var codeAssist = await loadGeminiCodeAssist(accessToken: token)
        if codeAssist.unauthorized, !refreshed, creds.refreshToken != nil {
            creds = try await refreshGeminiCredentials(creds, storage: storage, account: account)
            refreshed = true
            guard let nextToken = creds.accessToken else {
                throw QuotaError.commandFailed("Gemini OAuth 刷新后未返回 access_token，请重新使用 Google 登录。")
            }
            token = nextToken
            codeAssist = await loadGeminiCodeAssist(accessToken: token)
        }

        var projectID = codeAssist.info.projectID ?? Self.environmentGeminiProjectID()
        var (quotaData, quotaResponse) = try await requestGeminiQuota(accessToken: token, projectID: projectID)
        if quotaResponse.statusCode == 401, !refreshed, creds.refreshToken != nil {
            creds = try await refreshGeminiCredentials(creds, storage: storage, account: account)
            refreshed = true
            guard let nextToken = creds.accessToken else {
                throw QuotaError.commandFailed("Gemini OAuth 刷新后未返回 access_token，请重新使用 Google 登录。")
            }
            token = nextToken
            if codeAssist.info.projectID == nil {
                codeAssist = await loadGeminiCodeAssist(accessToken: token)
                projectID = codeAssist.info.projectID ?? Self.environmentGeminiProjectID()
            }
            (quotaData, quotaResponse) = try await requestGeminiQuota(accessToken: token, projectID: projectID)
        }

        switch quotaResponse.statusCode {
        case 200...299:
            let email = GeminiQuotaParser.extractEmail(fromIDToken: creds.idToken)
            return try GeminiQuotaParser.parse(
                accountID: account.id,
                quotaJSON: quotaData,
                email: email,
                planLabel: codeAssist.info.planLabel,
                fetchedAt: now()
            )
        case 401:
            throw QuotaError.commandFailed("Gemini OAuth 登录已过期，请在编辑账号中重新使用 Google 登录。")
        case 403:
            throw QuotaError.commandFailed("Gemini 账号无权访问额度接口（HTTP 403），请确认该 Google 账号已开通 Gemini / Code Assist 服务。")
        case 429:
            throw QuotaError.commandFailed("Gemini 查询过于频繁（HTTP 429），请稍后重试。")
        default:
            let detail = Self.extractGoogleErrorMessage(from: quotaData) ?? "HTTP \(quotaResponse.statusCode)"
            throw QuotaError.commandFailed("Gemini CLI 查询失败：\(detail)")
        }
    }

    private func loadGeminiCodeAssist(accessToken: String) async -> (info: GeminiQuotaParser.LoadCodeAssistInfo, unauthorized: Bool) {
        var request = URLRequest(url: Self.geminiLoadCodeAssistURL, timeoutInterval: timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(#"{"metadata":{"ideType":"IDE_UNSPECIFIED","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}"#.utf8)

        guard let (data, response) = try? await performHTTPRequest(request, provider: .gemini) else {
            return (GeminiQuotaParser.LoadCodeAssistInfo(projectID: nil, planLabel: nil), false)
        }
        if response.statusCode == 401 {
            return (GeminiQuotaParser.LoadCodeAssistInfo(projectID: nil, planLabel: nil), true)
        }
        guard (200...299).contains(response.statusCode) else {
            return (GeminiQuotaParser.LoadCodeAssistInfo(projectID: nil, planLabel: nil), false)
        }
        return (GeminiQuotaParser.parseLoadCodeAssist(jsonData: data), false)
    }

    private func requestGeminiQuota(accessToken: String, projectID: String?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: Self.geminiRetrieveQuotaURL, timeoutInterval: timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let bodyObject: [String: String] = projectID.map { ["project": $0] } ?? [:]
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyObject)
        return try await performHTTPRequest(request, provider: .gemini)
    }

    private func refreshGeminiCredentials(
        _ creds: GeminiOAuthCredentials,
        storage: GeminiCredentialStorage,
        account: QuotaAccountConfig
    ) async throws -> GeminiOAuthCredentials {
        guard let refreshToken = creds.refreshToken, !refreshToken.isEmpty else {
            throw QuotaError.commandFailed("Gemini OAuth 凭证已过期且缺少 refresh_token，请重新使用 Google 登录。")
        }
        guard let oauthClient = Self.resolveGeminiOAuthClient(from: creds, customBinaryPath: account.customBinaryPath) else {
            throw QuotaError.commandFailed("Gemini OAuth 凭证已过期且未找到 OAuth 客户端配置，请安装本机 gemini CLI 或配置 GEMINI_OAUTH_CLIENT_ID / GEMINI_OAUTH_CLIENT_SECRET 环境变量。")
        }

        var request = URLRequest(url: Self.googleOAuthTokenURL, timeoutInterval: timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let formBody = [
            ("client_id", oauthClient.clientID),
            ("client_secret", oauthClient.clientSecret),
            ("refresh_token", refreshToken),
            ("grant_type", "refresh_token")
        ]
        .map { "\(Self.formURLEncode($0.0))=\(Self.formURLEncode($0.1))" }
        .joined(separator: "&")
        request.httpBody = Data(formBody.utf8)

        let (data, response) = try await performHTTPRequest(request, provider: .gemini)
        guard (200...299).contains(response.statusCode) else {
            let detail = Self.extractGoogleErrorMessage(from: data) ?? "HTTP \(response.statusCode)"
            throw QuotaError.commandFailed("刷新 Gemini OAuth 令牌失败（\(detail)），请重新使用 Google 登录。")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccessToken = (json["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !newAccessToken.isEmpty else {
            throw QuotaError.invalidOutput("Gemini OAuth 刷新响应缺少 access_token")
        }

        var updated = creds
        updated.accessToken = newAccessToken
        updated.rawObject["access_token"] = newAccessToken
        if let newIDToken = (json["id_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !newIDToken.isEmpty {
            updated.idToken = newIDToken
            updated.rawObject["id_token"] = newIDToken
        }
        if let tokenType = json["token_type"] as? String, !tokenType.isEmpty {
            updated.rawObject["token_type"] = tokenType
        }
        if let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue, expiresIn > 0 {
            let expiry = now().addingTimeInterval(expiresIn)
            updated.expiryDate = expiry
            updated.rawObject["expiry_date"] = Int64(expiry.timeIntervalSince1970 * 1000.0)
        }
        switch storage {
        case .file(let fileURL):
            Self.persistGeminiCredentials(updated.rawObject, to: fileURL)
        case .keychain(let id, let title):
            if let encoded = try? JSONSerialization.data(withJSONObject: updated.rawObject, options: [.sortedKeys, .withoutEscapingSlashes]) {
                _ = try? credentials.save(id: id, title: title, secret: String(decoding: encoded, as: UTF8.self))
            }
        }
        return updated
    }

    private func performHTTPRequest(
        _ request: URLRequest,
        provider: QuotaProvider
    ) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        do {
            return try await transport(request)
        } catch is CancellationError {
            throw QuotaError.cancelled
        } catch let error as QuotaError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled { throw QuotaError.cancelled }
            if error.code == .timedOut { throw QuotaError.timedOut(provider) }
            throw QuotaError.commandFailed("\(provider.title) 网络请求失败：\(error.localizedDescription)")
        } catch {
            throw QuotaError.commandFailed("\(provider.title) 请求失败：\(error.localizedDescription)")
        }
    }

    static func resolveGeminiCredentialPaths(customHomePath: String?) -> (credentialsURL: URL, settingsURL: URL?) {
        let fileManager = FileManager.default
        if let raw = customHomePath?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let expanded = expandTilde(raw)
            let url = URL(fileURLWithPath: expanded)
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: expanded, isDirectory: &isDirectory)
            if (exists && !isDirectory.boolValue) || url.pathExtension.lowercased() == "json" {
                let settings = url.deletingLastPathComponent().appendingPathComponent("settings.json")
                return (url, settings)
            }
            let direct = url.appendingPathComponent("oauth_creds.json")
            if fileManager.fileExists(atPath: direct.path) {
                return (direct, url.appendingPathComponent("settings.json"))
            }
            let nestedDir = url.appendingPathComponent(".gemini")
            let nested = nestedDir.appendingPathComponent("oauth_creds.json")
            if fileManager.fileExists(atPath: nested.path) {
                return (nested, nestedDir.appendingPathComponent("settings.json"))
            }
            return (direct, url.appendingPathComponent("settings.json"))
        }

        let defaultDir = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".gemini")
        return (
            defaultDir.appendingPathComponent("oauth_creds.json"),
            defaultDir.appendingPathComponent("settings.json")
        )
    }

    private static func loadGeminiCredentials(at credentialsURL: URL, settingsURL: URL?) throws -> GeminiOAuthCredentials {
        guard FileManager.default.fileExists(atPath: credentialsURL.path) else {
            if let settingsURL, let authType = readGeminiAuthType(at: settingsURL),
               authType == "gemini-api-key" || authType == "vertex-ai" {
                throw QuotaError.commandFailed("当前 Gemini CLI 使用的是 \(authType)，请先在终端运行 gemini 并切换到 Google OAuth 登录。")
            }
            throw QuotaError.commandFailed("未找到 Gemini OAuth 凭证（\(credentialsURL.path)），请先在终端运行 gemini 并使用 Google 账号登录，或在编辑账号中指定凭证目录。")
        }

        let data: Data
        do {
            data = try Data(contentsOf: credentialsURL)
        } catch {
            throw QuotaError.commandFailed("无法读取 Gemini OAuth 凭证：\(error.localizedDescription)")
        }
        return try parseGeminiCredentialsData(data)
    }

    private static func parseGeminiCredentialsData(_ data: Data) throws -> GeminiOAuthCredentials {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.invalidOutput("Gemini OAuth 凭证文件不是有效的 JSON")
        }

        let accessToken = (object["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let refreshToken = (object["refresh_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let idToken = (object["id_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientID = (object["client_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = (object["client_secret"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let expiryDate: Date?
        if let rawExpiry = (object["expiry_date"] as? NSNumber)?.doubleValue, rawExpiry.isFinite, rawExpiry > 0 {
            let seconds = rawExpiry > 10_000_000_000 ? rawExpiry / 1000.0 : rawExpiry
            expiryDate = Date(timeIntervalSince1970: seconds)
        } else {
            expiryDate = nil
        }

        let normalizedAccess = accessToken?.isEmpty == false ? accessToken : nil
        let normalizedRefresh = refreshToken?.isEmpty == false ? refreshToken : nil
        guard normalizedAccess != nil || normalizedRefresh != nil else {
            throw QuotaError.invalidOutput("Gemini OAuth 凭证缺少 access_token 和 refresh_token")
        }

        return GeminiOAuthCredentials(
            rawObject: object,
            accessToken: normalizedAccess,
            refreshToken: normalizedRefresh,
            idToken: idToken?.isEmpty == false ? idToken : nil,
            expiryDate: expiryDate,
            clientID: clientID?.isEmpty == false ? clientID : nil,
            clientSecret: clientSecret?.isEmpty == false ? clientSecret : nil
        )
    }

    private static func readGeminiAuthType(at settingsURL: URL) -> String? {
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let security = json["security"] as? [String: Any],
           let auth = security["auth"] as? [String: Any],
           let selected = auth["selectedType"] as? String {
            return selected
        }
        return json["selectedAuthType"] as? String
    }

    private static func persistGeminiCredentials(_ object: [String: Any], to fileURL: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return
        }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static func environmentGeminiProjectID() -> String? {
        let env = ProcessInfo.processInfo.environment
        for key in ["GOOGLE_CLOUD_PROJECT", "GOOGLE_CLOUD_PROJECT_ID"] {
            if let value = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static func resolveGeminiOAuthClient(
        clientIDOverride: String? = nil,
        clientSecretOverride: String? = nil,
        customBinaryPath: String?
    ) -> (clientID: String, clientSecret: String)? {
        if let id = clientIDOverride, !id.isEmpty, let secret = clientSecretOverride, !secret.isEmpty {
            return (id, secret)
        }
        let env = ProcessInfo.processInfo.environment
        for (idKey, secretKey) in [
            ("GEMINI_OAUTH_CLIENT_ID", "GEMINI_OAUTH_CLIENT_SECRET"),
            ("OAUTH_CLIENT_ID", "OAUTH_CLIENT_SECRET")
        ] {
            if let id = env[idKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
               let secret = env[secretKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty {
                return (id, secret)
            }
        }
        if let executable = resolveExecutable(named: "gemini", overridePath: customBinaryPath),
           let extracted = extractGeminiOAuthClient(nearExecutable: executable) {
            return extracted
        }
        return nil
    }

    private static func resolveGeminiOAuthClient(
        from creds: GeminiOAuthCredentials,
        customBinaryPath: String?
    ) -> (clientID: String, clientSecret: String)? {
        resolveGeminiOAuthClient(
            clientIDOverride: creds.clientID,
            clientSecretOverride: creds.clientSecret,
            customBinaryPath: customBinaryPath
        )
    }

    private static func extractGeminiOAuthClient(nearExecutable executable: URL) -> (clientID: String, clientSecret: String)? {
        let resolved = executable.resolvingSymlinksInPath()
        let relativePaths = [
            "node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
            "lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
            "lib/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
            "libexec/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
            "libexec/lib/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
            "@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
            "dist/src/code_assist/oauth2.js",
            "oauth2.js"
        ]
        var searchRoots: [URL] = []
        var cursor = resolved.deletingLastPathComponent()
        for _ in 0..<5 {
            if !searchRoots.contains(cursor) { searchRoots.append(cursor) }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
        }

        let fileManager = FileManager.default
        for root in searchRoots {
            for relative in relativePaths {
                let candidate = root.appendingPathComponent(relative)
                guard fileManager.isReadableFile(atPath: candidate.path),
                      let text = try? String(contentsOf: candidate, encoding: .utf8),
                      let extracted = parseOAuthClientConstants(from: text) else {
                    continue
                }
                return extracted
            }
        }
        return nil
    }

    private static func parseOAuthClientConstants(from source: String) -> (clientID: String, clientSecret: String)? {
        guard let clientID = firstRegexCapture(#"OAUTH_CLIENT_ID\s*[:=]\s*['"`]([^'"`\s]+)['"`]"#, in: source),
              let clientSecret = firstRegexCapture(#"OAUTH_CLIENT_SECRET\s*[:=]\s*['"`]([^'"`\s]+)['"`]"#, in: source) else {
            return nil
        }
        return (clientID, clientSecret)
    }

    private static func firstRegexCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    static func formURLEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func extractGoogleErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let description = json["error_description"] as? String,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return description.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let error = json["error"] as? String,
           !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return error.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func runCancellableBlocking<T: Sendable>(
        _ work: @escaping @Sendable (CLICancellation) throws -> T
    ) async throws -> T {
        let cancellation = CLICancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try work(cancellation) })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func launch(_ process: Process, name: String) throws {
        do {
            try process.run()
        } catch {
            throw QuotaError.commandFailed("无法启动 \(name)：\(error.localizedDescription)")
        }
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    static func resolveExecutable(named name: String, overridePath: String?) -> URL? {
        let fileManager = FileManager.default
        if let overridePath = overridePath?.trimmingCharacters(in: .whitespacesAndNewlines), !overridePath.isEmpty {
            let expanded = expandTilde(overridePath)
            if fileManager.isExecutableFile(atPath: expanded) {
                return URL(fileURLWithPath: expanded)
            }
            return nil
        }

        let home = fileManager.homeDirectoryForCurrentUser.path
        var candidateDirectories = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.volta/bin",
            "\(home)/.bun/bin",
            "\(home)/.cargo/bin",
            "/usr/bin",
            "/bin"
        ]
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for component in pathEnv.split(separator: ":").map(String.init) where !component.isEmpty {
                if !candidateDirectories.contains(component) {
                    candidateDirectories.append(component)
                }
            }
        }

        for dir in candidateDirectories {
            let path = (dir as NSString).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    static func augmentedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extraPaths = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.volta/bin",
            "\(home)/.bun/bin",
            "\(home)/.cargo/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        var merged: [String] = []
        for path in extraPaths + existing where !path.isEmpty {
            if !merged.contains(path) { merged.append(path) }
        }
        env["PATH"] = merged.joined(separator: ":")
        env["NO_COLOR"] = "1"
        return env
    }

    static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

private final class CLICancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw QuotaError.cancelled }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private final class CLIOutput {
    private let handle: FileHandle
    private(set) var data = Data()
    private(set) var isAtEnd = false

    init(_ pipe: Pipe) {
        handle = pipe.fileHandleForReading
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 { return }
        isAtEnd = true
    }

    // Bound each drain so a noisy child cannot delay cancellation or starve its other pipe.
    func drain() {
        guard !isAtEnd else { return }
        let fd = handle.fileDescriptor
        var chunk = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<64 {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                data.append(contentsOf: chunk[..<count])
            } else if count == 0 {
                isAtEnd = true
                return
            } else if errno != EINTR {
                if errno != EAGAIN && errno != EWOULDBLOCK { isAtEnd = true }
                return
            }
        }
    }

    func popLine() -> Data? {
        guard let newline = data.firstIndex(of: 0x0A) else { return nil }
        let line = Data(data[..<newline])
        data.removeSubrange(...newline)
        return line
    }

    func failure(provider: QuotaProvider, fallback: String) -> QuotaError {
        let message = String(decoding: data.suffix(600), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .commandFailed("\(provider.title) 查询失败：\(message.isEmpty ? fallback : message)")
    }
}
