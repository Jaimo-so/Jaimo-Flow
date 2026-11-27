import AppKit
import CryptoKit
import Darwin
import Foundation

struct GeminiWebAuthResult: Equatable, Sendable {
    let email: String?
    let credentialsJSON: String
}

protocol GeminiWebAuthenticating: Sendable {
    func authenticate(customBinaryPath: String?) async throws -> GeminiWebAuthResult
}

struct GeminiWebOAuthAuthenticator: GeminiWebAuthenticating {
    private static let authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    private static let scopes = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
        "openid"
    ]

    private let timeoutSeconds: TimeInterval
    private let transport: QuotaHTTPTransport
    private let openBrowser: @Sendable (URL) -> Bool
    private let now: @Sendable () -> Date

    init(
        timeoutSeconds: TimeInterval = 180,
        transport: @escaping QuotaHTTPTransport = { try await CLIQuotaFetcher.defaultTransport($0) },
        openBrowser: @escaping @Sendable (URL) -> Bool = { url in
            if Thread.isMainThread {
                return NSWorkspace.shared.open(url)
            }
            return DispatchQueue.main.sync { NSWorkspace.shared.open(url) }
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.transport = transport
        self.openBrowser = openBrowser
        self.now = now
    }

    func authenticate(customBinaryPath: String?) async throws -> GeminiWebAuthResult {
        try Task.checkCancellation()
        guard let oauthClient = CLIQuotaFetcher.resolveGeminiOAuthClient(customBinaryPath: customBinaryPath) else {
            throw QuotaError.commandFailed("未找到 Google OAuth 客户端配置。请安装本机 gemini CLI（或指定 CLI 路径），或设置 GEMINI_OAUTH_CLIENT_ID 与 GEMINI_OAUTH_CLIENT_SECRET 环境变量。")
        }

        let server = try LoopbackOAuthServer()
        defer { server.close() }

        let redirectURI = "http://127.0.0.1:\(server.port)/oauth2callback"
        let state = Self.randomBase64URL(byteCount: 24)
        let codeVerifier = Self.randomBase64URL(byteCount: 32)
        let codeChallenge = Self.pkceChallenge(for: codeVerifier)

        let authURL = try Self.buildAuthorizationURL(
            clientID: oauthClient.clientID,
            redirectURI: redirectURI,
            state: state,
            codeChallenge: codeChallenge
        )

        guard openBrowser(authURL) else {
            throw QuotaError.commandFailed("无法打开系统浏览器进行 Google 登录。")
        }

        let code = try await server.waitForAuthorizationCode(expectedState: state, timeoutSeconds: timeoutSeconds)
        return try await exchangeCode(
            code,
            codeVerifier: codeVerifier,
            redirectURI: redirectURI,
            clientID: oauthClient.clientID,
            clientSecret: oauthClient.clientSecret
        )
    }

    static func buildAuthorizationURL(
        clientID: String,
        redirectURI: String,
        state: String,
        codeChallenge: String
    ) throws -> URL {
        guard var components = URLComponents(string: authorizationEndpoint) else {
            throw QuotaError.commandFailed("Google 登录地址构造失败。")
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent select_account"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        guard let url = components.url else {
            throw QuotaError.commandFailed("Google 登录地址构造失败。")
        }
        return url
    }

    private func exchangeCode(
        _ code: String,
        codeVerifier: String,
        redirectURI: String,
        clientID: String,
        clientSecret: String
    ) async throws -> GeminiWebAuthResult {
        try Task.checkCancellation()
        var request = URLRequest(url: Self.tokenEndpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let formBody = [
            ("client_id", clientID),
            ("client_secret", clientSecret),
            ("code", code),
            ("code_verifier", codeVerifier),
            ("redirect_uri", redirectURI),
            ("grant_type", "authorization_code")
        ]
        .map { "\(CLIQuotaFetcher.formURLEncode($0.0))=\(CLIQuotaFetcher.formURLEncode($0.1))" }
        .joined(separator: "&")
        request.httpBody = Data(formBody.utf8)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request)
        } catch is CancellationError {
            throw QuotaError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw QuotaError.cancelled
        } catch let error as QuotaError {
            throw error
        } catch {
            throw QuotaError.commandFailed("Google 授权令牌交换失败：\(error.localizedDescription)")
        }

        guard (200...299).contains(response.statusCode) else {
            let detail = Self.extractError(from: data) ?? "HTTP \(response.statusCode)"
            throw QuotaError.commandFailed("Google 登录失败：\(detail)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = (json["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else {
            throw QuotaError.invalidOutput("Google 登录未返回有效的 access_token")
        }

        var payload: [String: Any] = [
            "access_token": accessToken,
            "token_type": (json["token_type"] as? String) ?? "Bearer",
            "client_id": clientID,
            "client_secret": clientSecret
        ]
        if let refreshToken = (json["refresh_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !refreshToken.isEmpty {
            payload["refresh_token"] = refreshToken
        }
        let idToken = (json["id_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let idToken, !idToken.isEmpty {
            payload["id_token"] = idToken
        }
        if let scope = json["scope"] as? String, !scope.isEmpty {
            payload["scope"] = scope
        }
        if let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue, expiresIn > 0 {
            payload["expiry_date"] = Int64(now().addingTimeInterval(expiresIn).timeIntervalSince1970 * 1000.0)
        }

        let encoded = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        let credentialsJSON = String(decoding: encoded, as: UTF8.self)
        let email = GeminiQuotaParser.extractEmail(fromIDToken: idToken)
        return GeminiWebAuthResult(email: email, credentialsJSON: credentialsJSON)
    }

    static func pkceChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    private static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URLEncode(Data(bytes))
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func extractError(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let description = json["error_description"] as? String, !description.isEmpty { return description }
        if let error = json["error"] as? String, !error.isEmpty { return error }
        return nil
    }
}

private final class LoopbackOAuthServer: @unchecked Sendable {
    private let lock = NSLock()
    private var serverFD: Int32
    private var cancelled = false
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw QuotaError.commandFailed("无法创建本机 Google 登录回调服务。")
        }

        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw QuotaError.commandFailed("无法监听本机回调端口。")
        }

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(fd, sockPtr, &addrLen)
            }
        }
        guard nameResult == 0, listen(fd, 8) == 0 else {
            Darwin.close(fd)
            throw QuotaError.commandFailed("无法启动本机登录回调监听。")
        }

        serverFD = fd
        port = UInt16(bigEndian: boundAddr.sin_port)
    }

    deinit {
        close()
    }

    func close() {
        lock.lock()
        cancelled = true
        let fd = serverFD
        serverFD = -1
        lock.unlock()
        if fd >= 0 {
            Darwin.close(fd)
        }
    }

    func waitForAuthorizationCode(expectedState: String, timeoutSeconds: TimeInterval) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self else {
                        continuation.resume(throwing: QuotaError.cancelled)
                        return
                    }
                    continuation.resume(with: Result {
                        try self.acceptLoop(expectedState: expectedState, timeoutSeconds: timeoutSeconds)
                    })
                }
            }
        } onCancel: {
            self.close()
        }
    }

    private func acceptLoop(expectedState: String, timeoutSeconds: TimeInterval) throws -> String {
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            let (fd, isCancelled) = currentFD()
            if isCancelled || fd < 0 { throw QuotaError.cancelled }

            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&pollFD, 1, 100)
            if ready <= 0 { continue }

            let clientFD = Darwin.accept(fd, nil, nil)
            if clientFD < 0 { continue }
            defer { Darwin.close(clientFD) }

            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            _ = setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(clientFD, &buffer, buffer.count)
            guard count > 0 else { continue }
            let requestText = String(decoding: buffer[..<count], as: UTF8.self)
            guard let targetPath = Self.extractRequestTarget(from: requestText) else {
                Self.sendHTML(clientFD, status: "400 Bad Request", title: "无效请求", body: "无法识别回调参数，请返回 Jaimo Flow 重试。")
                continue
            }

            guard let components = URLComponents(string: "http://127.0.0.1\(targetPath)") else {
                Self.sendHTML(clientFD, status: "400 Bad Request", title: "无效请求", body: "无法解析回调地址，请返回 Jaimo Flow 重试。")
                continue
            }

            guard components.path == "/oauth2callback" else {
                Self.sendHTML(clientFD, status: "404 Not Found", title: "Not Found", body: "")
                continue
            }

            let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            if let error = items["error"], !error.isEmpty {
                let message = error == "access_denied" ? "你取消了 Google 账号授权。" : "Google 返回错误：\(error)"
                Self.sendHTML(clientFD, status: "200 OK", title: "授权未完成", body: "\(message) 你可以关闭此页面并返回 Jaimo Flow。")
                throw QuotaError.commandFailed(message)
            }

            guard items["state"] == expectedState else {
                Self.sendHTML(clientFD, status: "400 Bad Request", title: "校验失败", body: "登录状态校验不匹配，请返回 Jaimo Flow 重新发起登录。")
                throw QuotaError.commandFailed("Google 登录状态校验失败，请重试。")
            }

            guard let code = items["code"], !code.isEmpty else {
                Self.sendHTML(clientFD, status: "400 Bad Request", title: "缺少授权码", body: "未收到授权码，请返回 Jaimo Flow 重试。")
                throw QuotaError.commandFailed("Google 未返回授权码，请重试。")
            }

            Self.sendHTML(clientFD, status: "200 OK", title: "登录成功", body: "已完成 Google 账号授权，可以关闭此标签页并返回 Jaimo Flow。")
            return code
        }
        throw QuotaError.commandFailed("等待 Google 网页登录超时，请重试。")
    }

    private func currentFD() -> (Int32, Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (serverFD, cancelled)
    }

    private static func extractRequestTarget(from request: String) -> String? {
        guard let firstLine = request.split(whereSeparator: \.isNewline).first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return String(parts[1])
    }

    private static func sendHTML(_ fd: Int32, status: String, title: String, body: String) {
        let html = """
        <!doctype html>
        <html lang="zh-CN"><head><meta charset="utf-8"><title>\(title) · Jaimo Flow</title>
        <style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0;background:#f5f7fb;color:#1d1d1f}.card{background:#fff;padding:28px 32px;border-radius:18px;box-shadow:0 12px 36px rgba(0,0,0,.08);max-width:420px;text-align:center}h1{font-size:20px;margin:0 0 10px}p{font-size:14px;color:#555;line-height:1.6;margin:0}</style>
        </head><body><div class="card"><h1>\(title)</h1><p>\(body)</p></div></body></html>
        """
        let bodyData = Data(html.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(bodyData)
        response.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = Darwin.write(fd, base, response.count)
        }
    }
}
