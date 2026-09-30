import Foundation
import ClipFlowKit
@testable import ClipFlow

enum TestError: Error { case failed(String) }
func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw TestError.failed(message) }
}

final class MockAPI: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

actor StubAgent: VibeHubAgentServing {
    let content: VibeHubAgentContent
    var calls = 0
    var shouldFail = false
    init(content: VibeHubAgentContent) { self.content = content }
    func organize(phrase: String, configuration: VibeHubAgentConfiguration, apiKey: String) async throws -> VibeHubAgentContent {
        calls += 1
        try await Task.sleep(nanoseconds: 80_000_000)
        if shouldFail { throw VibeHubAgentError.http(401) }
        return content
    }
    func fail(_ value: Bool) { shouldFail = value }
}

@MainActor
func waitForAgent(_ agent: VibeHubAgentModel) async throws {
    let deadline = Date().addingTimeInterval(3)
    while agent.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    try require(!agent.isRunning, "Agent 状态未结束")
}

@main
struct AgentSelfTests {
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VibeHubAgentSelfTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "com.clipflow.vibehub.agent.selftest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let credentials = CredentialStore(service: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            for entry in (try? credentials.loadEntries()) ?? [] { try? credentials.delete(id: entry.id) }
            try? FileManager.default.removeItem(at: directory)
        }
        let raw = "  给各个页面加上哈希路由，点击切换时网址同步变化，并支持刷新和浏览器前进后退。\n\n保留所有定义、意义与\"原文\"。  "
        let meaning = String(repeating: "哈希路由使用 # 后的片段表示页面。\n定义、意义和前进后退行为要完整保留。\n", count: 120)
        let content = VibeHubAgentContent(title: "页面切换与哈希路由", category: .navigation,
                                        tags: ["哈希路由", "页面切换"], scenario: "多页面 Web 应用，需刷新恢复和前进后退。", meaning: meaning)
        let configuration = VibeHubAgentConfiguration(baseURL: "https://api.example.test/v1/", model: "test-model", jsonMode: true)
        let fakeKey = "selftest-fake-key"
        try require(try configuration.endpoint().absoluteString == "https://api.example.test/v1/chat/completions", "Base URL 拼接错误")
        try require(try VibeHubAgentConfiguration(baseURL: "https://api.example.test/v1/chat/completions", model: "m").endpoint().absoluteString == "https://api.example.test/v1/chat/completions", "完整接口被重复拼接")
        for address in ["http://api.example.test/v1", "https://user:password@api.example.test/v1", "https://api.example.test/v1?key=secret"] {
            do {
                _ = try VibeHubAgentConfiguration(baseURL: address, model: "m").endpoint()
                throw TestError.failed("无效接口被接受")
            } catch VibeHubAgentError.invalidAddress { }
        }
        _ = try VibeHubAgentConfiguration(baseURL: "http://localhost:1234/v1", model: "local").endpoint()
        let request = try VibeHubAPIClient.request(phrase: raw, configuration: configuration, apiKey: fakeKey)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let messages = body["messages"] as! [[String: String]]
        let encodedPhrase = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as! [String: String]
        try require(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Authorization") == "Bearer \(fakeKey)", "调用方法或鉴权错误")
        try require(encodedPhrase["phrase"] == raw && !String(decoding: request.httpBody!, as: UTF8.self).contains(fakeKey), "请求压缩原文或把 Key 放入模型消息")
        try require((body["response_format"] as? [String: String])?["type"] == "json_object", "JSON 模式未生效")
        let plainConfig = VibeHubAgentConfiguration(baseURL: configuration.baseURL, model: configuration.model, jsonMode: false)
        let plain = try VibeHubAPIClient.request(phrase: raw, configuration: plainConfig, apiKey: fakeKey)
        try require((try JSONSerialization.jsonObject(with: plain.httpBody!) as! [String: Any])["response_format"] == nil, "关闭 JSON 模式仍携带该参数")
        let resultJSON = String(decoding: try JSONEncoder().encode(content), as: UTF8.self)
        func response(_ text: String, reason: String = "stop") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": text], "finish_reason": reason]]])
        }
        try require(try VibeHubAPIClient.decode(response(resultJSON)) == content, "返回内容被截断或解码错误")
        try require(try VibeHubAPIClient.decode(response("```json\n\(resultJSON)\n```")) == content, "普通模式的 JSON 代码块无法解码")
        for text in ["不是 JSON", "{}", resultJSON.replacingOccurrences(of: "路由与导航", with: "错误分类"), resultJSON.replacingOccurrences(of: "页面切换与哈希路由", with: "")] {
            do { _ = try VibeHubAPIClient.decode(response(text)); throw TestError.failed("错误内容被保存") }
            catch VibeHubAgentError.invalidResult { }
        }
        do { _ = try VibeHubAPIClient.decode(response(resultJSON, reason: "length")); throw TestError.failed("截断结果被接受") }
        catch VibeHubAgentError.incompleteResult { }

        // Exercise the real URLSession client without contacting a provider or using a real key.
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockAPI.self]
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        let api = VibeHubAPIClient(session: session)
        let apiResponse = try response(resultJSON)
        MockAPI.handler = { request in
            try require(request.url == configuration.endpoint(), "请求发往错误接口")
            return (200, apiResponse)
        }
        let generated = try await api.organize(phrase: raw, configuration: configuration, apiKey: fakeKey)
        try require(generated == content, "实际客户端未返回完整字段")
        MockAPI.handler = { _ in (401, Data("{\"error\":\"echoed fake credential\"}".utf8)) }
        do { _ = try await api.organize(phrase: raw, configuration: configuration, apiKey: fakeKey); throw TestError.failed("鉴权失败被报告为成功") }
        catch VibeHubAgentError.http(401) { }

        let url = directory.appendingPathComponent("phrases.json")
        let library = VibeHubLibraryModel(fileURL: url)
        library.flush()
        let stub = StubAgent(content: content)
        defaults.set(raw, forKey: "vibehub.agent.draft")
        defaults.set(try JSONEncoder().encode(VibeHubAgentDraft(id: UUID(), phrase: raw, content: content)), forKey: "vibehub.agent.reviewDraft")
        let agent = VibeHubAgentModel(library: library, defaults: defaults, credentials: credentials, client: stub)
        try require(agent.input.isEmpty && agent.reviewDraft == nil && defaults.object(forKey: "vibehub.agent.draft") == nil && defaults.object(forKey: "vibehub.agent.reviewDraft") == nil, "历史草稿未清理或仍被恢复")
        agent.openComposer()
        agent.input = raw
        agent.openSettings()
        agent.draftBaseURL = configuration.baseURL
        agent.draftModel = configuration.model
        agent.draftAPIKey = fakeKey
        try require(agent.saveSettings() && agent.panel == .composer && agent.isConfigured, "设置保存或返回输入页失败")
        try require(agent.draftAPIKey.isEmpty, "保存后未清除 Key 输入框")
        let savedPreferences = defaults.persistentDomain(forName: suite)!.values.map { value in
            if let data = value as? Data { return String(decoding: data, as: UTF8.self) }
            return String(describing: value)
        }.joined()
        try require(!savedPreferences.contains(fakeKey), "API Key 被写入偏好文件")
        let reloaded = VibeHubAgentModel(library: library, defaults: defaults, credentials: credentials, client: stub)
        try require(reloaded.isConfigured && reloaded.input.isEmpty && reloaded.reviewDraft == nil && reloaded.configuration == agent.configuration, "模型设置未保留或未完成输入被持久化")
        agent.openSettings()
        agent.draftAPIKey = ""
        try require(agent.saveSettings() && (try credentials.loadEntries()).count == 1, "留空 Key 没有沿用，或重复创建钥匙串条目")
        let originalCount = library.items.count
        let originalFile = try Data(contentsOf: url)
        agent.organizeForPreview()
        agent.organizeForPreview()
        try await waitForAgent(agent)
        let callCount = await stub.calls
        try require(callCount == 1 && library.items.count == originalCount, "重复点击重复调用或预览前自动保存")
        try require(agent.panel == .preview && agent.reviewDraft?.phrase == raw && agent.reviewDraft?.meaning == meaning && agent.savedItemID == nil, "补全未进入完整预览")
        library.flush()
        try require(try Data(contentsOf: url) == originalFile, "刷新或隐藏窗口时预览被自动保存到话术库")
        agent.reviewDraft?.title = "修改后的话术标题"
        agent.reviewDraft?.category = .interface
        agent.reviewDraft?.tags = "手动标签，页面切换"
        agent.reviewDraft?.phrase = raw + "\n用户补充的原文"
        agent.reviewDraft?.scenario = content.scenario + "\n用户补充的场景"
        agent.reviewDraft?.meaning = meaning + "\n用户补充的完整定义和意义"
        let editedDraft = agent.reviewDraft!
        agent.openSettings()
        agent.dismissPanel()
        try require(agent.panel == .preview && agent.reviewDraft == editedDraft, "关闭设置未返回正在编辑的预览")
        try require(defaults.object(forKey: "vibehub.agent.draft") == nil && defaults.object(forKey: "vibehub.agent.reviewDraft") == nil, "输入或预览修改被保存为草稿")
        agent.dismissPanel()
        try require(agent.panel == .closed && agent.input.isEmpty && agent.reviewDraft == nil && agent.errorMessage == nil && library.items.count == originalCount && (try Data(contentsOf: url)) == originalFile, "关闭预览未清空或新增了记录")
        let restoredReview = VibeHubAgentModel(library: library, defaults: defaults, credentials: credentials, client: stub)
        restoredReview.openComposer()
        try require(restoredReview.panel == .composer && restoredReview.reviewDraft == nil && restoredReview.input.isEmpty, "重开应用恢复了已关闭的草稿")
        agent.openComposer()
        try require(agent.panel == .composer && agent.input.isEmpty && agent.reviewDraft == nil, "重开仍保留上次内容")
        agent.input = raw
        agent.organizeForPreview()
        try await waitForAgent(agent)
        agent.reviewDraft?.title = ""
        agent.saveReviewedPhrase()
        try require(agent.panel == .preview && agent.errorMessage != nil && library.items.count == originalCount, "不完整预览仍被保存")
        agent.reviewDraft = editedDraft
        agent.saveReviewedPhrase()
        agent.saveReviewedPhrase()
        try require(library.items.count == originalCount + 1, "手动保存重复创建记录")
        try require(agent.savedItemID == library.selectedID && agent.panel == .closed && agent.input.isEmpty, "成功后未打开新记录或清理输入")
        let saved = library.selectedItem!
        try require(saved.title == editedDraft.title && saved.category == .interface && saved.phrase == editedDraft.phrase && saved.meaning == editedDraft.meaning && saved.scenario == editedDraft.scenario && saved.tags == "手动标签、页面切换", "手动保存未采用预览修改，或丢失原文与定义")
        try require(VibeHubLibraryModel(fileURL: url).items.contains(saved), "成功返回前没有实际保存")

        agent.input = raw
        agent.openComposer()
        agent.organizeForPreview()
        try await Task.sleep(nanoseconds: 20_000_000)
        agent.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)
        try require(!agent.isRunning && agent.input.isEmpty && agent.reviewDraft == nil && library.items.count == originalCount + 1, "取消后仍保留内容或保存了结果")
        await stub.fail(true)
        agent.input = raw
        agent.organizeForPreview()
        try await waitForAgent(agent)
        try require(agent.errorMessage != nil && agent.input == raw && library.items.count == originalCount + 1, "失败丢失原文或保存半成品")
        agent.dismissPanel()
        try require(agent.input.isEmpty && agent.reviewDraft == nil && agent.errorMessage == nil, "关闭失败面板仍保留输入或错误")
        await stub.fail(false)

        agent.openComposer()
        agent.input = raw
        agent.organizeForPreview()
        try await Task.sleep(nanoseconds: 20_000_000)
        agent.discardSession()
        try await Task.sleep(nanoseconds: 100_000_000)
        try require(agent.panel == .closed && !agent.isRunning && agent.input.isEmpty && agent.reviewDraft == nil && library.items.count == originalCount + 1, "隐藏窗口后异步结果重新打开或保留预览")

        let blocked = directory.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let failedURL = blocked.appendingPathComponent("phrases.json")
        let failedLibrary = VibeHubLibraryModel(fileURL: failedURL)
        let retryAgent = VibeHubAgentModel(library: failedLibrary, defaults: defaults, credentials: credentials, client: stub)
        retryAgent.input = raw
        retryAgent.organizeForPreview()
        try await waitForAgent(retryAgent)
        try require(retryAgent.panel == .preview && failedLibrary.items.count == 1, "补全结果在确认前进入话术库")
        retryAgent.saveReviewedPhrase()
        try require(retryAgent.reviewDraft != nil && retryAgent.input == raw && retryAgent.errorMessage != nil && failedLibrary.items.count == 1, "写入失败没有保留可编辑预览，或创建了半成品")
        retryAgent.reviewDraft?.meaning = meaning + "\n保存失败后修改的定义"
        let beforeRetry = await stub.calls
        try FileManager.default.removeItem(at: blocked)
        retryAgent.saveReviewedPhrase()
        let afterRetry = await stub.calls
        try require(beforeRetry == afterRetry && failedLibrary.items.count == 2 && retryAgent.savedItemID != nil, "保存重试重新请求模型或重复追加话术")
        try require(VibeHubLibraryModel(fileURL: failedURL).items.contains { $0.phrase == raw && $0.meaning == meaning + "\n保存失败后修改的定义" }, "保存重试未采用最新修改或未完整落盘")

        print("PASS: API 与钥匙串配置、完整可编辑预览、预览不入库、关闭清空且不保存草稿、手动保存最新字段、重复点击、取消与隐藏清空、失败重试")
    }
}
