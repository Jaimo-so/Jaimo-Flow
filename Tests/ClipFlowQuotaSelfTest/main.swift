import ClipFlowKit
import Foundation
@testable import ClipFlow

struct QuotaTestFailure: Error {
    let message: String
}

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw QuotaTestFailure(message: message) }
}

func requireQuotaError(_ message: String, _ action: () throws -> Void) throws {
    do {
        try action()
        throw QuotaTestFailure(message: message)
    } catch is QuotaError {
        return
    }
}

let codexFixture = #"{"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":32.25,"windowDurationMins":300,"resetsAt":1781654400},"secondary":{"usedPercent":71,"windowDurationMins":10080},"planType":"plus","credits":{"hasCredits":true,"balance":"12"}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":32.25}},"spark":{"limitName":"Spark","primary":{"usedPercent":90,"windowDurationMins":300}}},"rateLimitResetCredits":{"availableCount":2}}}"#
let agyFixture = #"{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"weekly","window":"weekly","remaining_fraction":0.23,"reset_time":1781654400},{"id":"short","window":"5h","remaining_fraction":1,"reset_time":"1970-01-01T00:00:00Z"}]},{"name":"Claude and GPT","buckets":[{"id":"short","window":"5h","remaining_fraction":0.88,"reset_time":"2026-06-17T00:00:00.013Z"},{"id":"weekly","window":"7d","remaining_fraction":0.5,"reset_time":0}]}]}}}"#

func testAccountPresentation() throws {
    try require(QuotaProvider.codex.title == "Codex CLI"
                && QuotaProvider.antigravity.title == "Antigravity CLI"
                && QuotaProvider.gemini.title == "Gemini CLI"
                && QuotaProvider.deepseek.title == "DeepSeek",
                "供应商标题不正确")
    try require(QuotaProviderFilter.allCases.map(\.title) == ["全部", "Codex CLI", "Antigravity CLI", "Gemini CLI", "DeepSeek"],
                "供应商筛选标题错误")

    let defaults = QuotaAccountConfig.defaultAccounts
    try require(defaults.map(\.label) == ["本机 Codex", "本机 Antigravity"], "默认账号的配置名称被更改")
    let email = "person@example.test"
    for account in defaults {
        try require(account.cardLabel(accountEmail: nil) == nil && account.cardLabel(accountEmail: email) == nil,
                    "卡片显示了内置账号的默认名称")
    }

    var account = defaults[0]
    account.label = "工作账号"
    try require(account.cardLabel(accountEmail: email) == "工作账号", "卡片隐藏了内置账号的自定义名称")
    account.isBuiltIn = false
    account.label = defaults[0].label
    try require(account.cardLabel(accountEmail: nil) == "本机 Codex", "卡片隐藏了手动添加的账号名称")
    account.label = email
    try require(account.cardLabel(accountEmail: email) == nil, "卡片同时显示了与邮箱重复的账号名称")
}

func testParsers() throws {
    let codex = try CodexQuotaParser.parse(
        accountID: "codex", rateLimitsJSON: Data(codexFixture.utf8),
        accountJSON: Data(#"{"result":{"account":{"email":"person@example.test","planType":"free","workspaceName":"工作区"}}}"#.utf8)
    )
    try require(codex.buckets.map(\.id) == ["primary", "secondary", "spark.primary"], "Codex 主额度重复或附加计量桶缺失")
    try require(codex.buckets.map(\.title) == ["5 小时", "周", "Spark · 5 小时"], "Codex 周期名称错误")
    try require(codex.buckets[0].usedPercent == 32.25 && codex.buckets[0].resetsAt == Date(timeIntervalSince1970: 1781654400),
                "Codex 用量或重置时间错误")
    try require(abs(codex.buckets[0].remainingPercent - 67.75) < 0.001
                && codex.buckets[0].formattedRemainingPercent == "67.8%"
                && codex.buckets[1].formattedRemainingPercent == "29%",
                "Codex 剩余额度数值或格式化错误")
    let overLimit = QuotaBucket(id: "over", title: "测试", usedPercent: 120, resetsAt: nil, windowMinutes: nil, detail: nil)
    try require(overLimit.remainingPercent == 0 && overLimit.remainingFraction == 0 && overLimit.formattedRemainingPercent == "0%",
                "超额窗口的剩余额度未归零")
    try require(codex.planLabel == "Plus" && codex.accountEmail == "person@example.test"
                && codex.creditBalance == "12" && codex.resetCreditsCount == 2, "Codex 套餐、邮箱、余额或重置券错误")

    let minimal = try CodexQuotaParser.parse(accountID: "noMetadata", rateLimitsJSON: Data(
        #"{"result":{"rateLimits":{"primary":{"usedPercent":0}},"rateLimitResetCredits":null}}"#.utf8
    ))
    try require(minimal.buckets.first?.usedPercent == 0 && minimal.buckets.first?.resetsAt == nil
                && minimal.planLabel == nil && minimal.accountEmail == nil && minimal.resetCreditsCount == nil,
                "Codex 缺省字段解析错误")
    let mapped = try CodexQuotaParser.parse(
        accountID: "mapped", rateLimitsJSON: Data(
            #"{"result":{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":12},"credits":{"hasCredits":false,"balance":"0"}}},"rateLimitResetCredits":{"availableCount":0}}}"#.utf8
        ),
        accountJSON: Data(#"{"result":{"account":{"planType":"pro"}}}"#.utf8)
    )
    try require(mapped.buckets.map(\.id) == ["primary"] && mapped.planLabel == "Pro"
                && mapped.creditBalance == "0" && mapped.resetCreditsCount == 0, "Codex 按 ID 回落、账号套餐或零值解析错误")
    for malformed in ["garbage", #"{"error":{"message":"unauthorized"}}"#, #"{"result":{}}"#,
                      #"{"result":{"rateLimits":{"primary":{"usedPercent":"unknown"}}}}"#] {
        try requireQuotaError("Codex 接受了无效格式") {
            _ = try CodexQuotaParser.parse(accountID: "bad", rateLimitsJSON: Data(malformed.utf8))
        }
    }

    let object = try JSONSerialization.jsonObject(with: Data(agyFixture.utf8))
    let pretty = try JSONSerialization.data(withJSONObject: object, options: .prettyPrinted)
    let agy = try AntigravityQuotaParser.parse(accountID: "agy", jsonData: Data("启动日志\n".utf8) + pretty)
    let logged = try AntigravityQuotaParser.parse(accountID: "agy", jsonData: Data(
        "启动日志\n   \(agyFixture)\n结束日志".utf8
    ))
    try require(logged.buckets == agy.buckets, "Antigravity 没有识别诊断日志中的缩进 JSON")
    try require(agy.buckets.map(\.title) == ["Gemini · 5 小时", "Gemini · 周", "Claude & GPT · 5 小时", "Claude & GPT · 周"],
                "Antigravity 分组名称或额度窗口排序错误")
    try require(Set(agy.buckets.map(\.id)).count == 4, "Antigravity 跨分组额度 ID 冲突")
    try require(agy.buckets[0].usedPercent == 0 && abs(agy.buckets[1].usedPercent - 77) < 0.001
                && abs(agy.buckets[2].usedPercent - 12) < 0.001, "Antigravity 剩余额度转换错误")
    try require(agy.buckets[0].formattedRemainingPercent == "100%"
                && agy.buckets[1].formattedRemainingPercent == "23%"
                && agy.buckets[2].formattedRemainingPercent == "88%",
                "Antigravity 剩余额度百分比显示错误")
    try require(agy.buckets[0].resetsAt == nil && agy.buckets[3].resetsAt == nil
                && agy.buckets[1].resetsAt == Date(timeIntervalSince1970: 1781654400)
                && agy.buckets[2].resetsAt != nil, "Antigravity epoch 或 ISO 时间解析错误")
    try requireQuotaError("Antigravity 接受 CLI 错误状态") {
        _ = try AntigravityQuotaParser.parse(accountID: "bad", jsonData: Data(#"{"status":"ERROR","error":"请登录"}"#.utf8))
    }

    // DeepSeek endpoint & parser
    try require(try DeepSeekQuotaParser.endpoint(baseURL: nil).absoluteString == "https://api.deepseek.com/user/balance",
                "DeepSeek 默认接口地址错误")
    try require(try DeepSeekQuotaParser.endpoint(baseURL: "https://api.deepseek.com/v1").absoluteString == "https://api.deepseek.com/user/balance",
                "DeepSeek /v1 地址规范化错误")
    try require(try DeepSeekQuotaParser.endpoint(baseURL: "https://proxy.example.com/ds/user/balance").absoluteString == "https://proxy.example.com/ds/user/balance",
                "DeepSeek 完整余额路径被重复拼接")
    try require(try DeepSeekQuotaParser.endpoint(baseURL: "http://127.0.0.1:8080").absoluteString == "http://127.0.0.1:8080/user/balance",
                "DeepSeek 本机 HTTP 地址未被允许")
    try requireQuotaError("DeepSeek 接受了非 HTTPS 远程地址") {
        _ = try DeepSeekQuotaParser.endpoint(baseURL: "http://api.deepseek.com")
    }

    let deepseekFixture = #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"},{"currency":"USD","total_balance":"5.50","granted_balance":"0.00","topped_up_balance":"5.50"}]}"#
    let deepseek = try DeepSeekQuotaParser.parse(accountID: "ds", jsonData: Data(deepseekFixture.utf8))
    try require(deepseek.provider == .deepseek && deepseek.planLabel == "余额可用"
                && deepseek.creditBalance == "¥110.00 · $5.50"
                && deepseek.balances?.count == 2
                && deepseek.balances?[0].detailText == "充值 ¥100.00 · 赠金 ¥10.00",
                "DeepSeek 多币种余额解析错误")
    let unavailableDS = try DeepSeekQuotaParser.parse(
        accountID: "ds2",
        jsonData: Data(#"{"is_available":false,"balance_infos":[{"currency":"CNY","total_balance":"0.00"}]}"#.utf8)
    )
    try require(unavailableDS.planLabel == "余额不足" && unavailableDS.creditBalance == "¥0.00", "DeepSeek 不可用状态解析错误")
    for malformed in ["bad", #"{}"#, #"{"is_available":true,"balance_infos":[]}"#] {
        try requireQuotaError("DeepSeek 接受了无效格式") {
            _ = try DeepSeekQuotaParser.parse(accountID: "bad", jsonData: Data(malformed.utf8))
        }
    }

    // Gemini loadCodeAssist, JWT email, and quota parser
    let codeAssistString = GeminiQuotaParser.parseLoadCodeAssist(jsonData: Data(
        #"{"cloudaicompanionProject":"my-project-1","paidTier":{"id":"g1-pro-tier","name":"Google AI Pro"}}"#.utf8
    ))
    try require(codeAssistString.projectID == "my-project-1" && codeAssistString.planLabel == "AI Pro",
                "Gemini loadCodeAssist 字符串项目或套餐解析错误")
    let codeAssistObject = GeminiQuotaParser.parseLoadCodeAssist(jsonData: Data(
        #"{"cloudaicompanionProject":{"id":"obj-project-2"},"currentTier":{"id":"free-tier"}}"#.utf8
    ))
    try require(codeAssistObject.projectID == "obj-project-2" && codeAssistObject.planLabel == "Free",
                "Gemini loadCodeAssist 对象项目解析错误")

    let jwtPayload = Data(#"{"email":"gemini.user@example.test","sub":"123"}"#.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    let fakeJWT = "eyJhbGciOiJSUzI1NiJ9.\(jwtPayload).signature"
    try require(GeminiQuotaParser.extractEmail(fromIDToken: fakeJWT) == "gemini.user@example.test",
                "Gemini id_token 邮箱解析错误")

    let geminiQuotaFixture = #"{"resetTime":"2026-11-28T12:00:00Z","buckets":[{"modelId":"gemini-2.5-flash","tokenType":"REQUESTS","remainingFraction":0.9,"resetTime":"2026-11-28T15:00:00.500Z"},{"modelId":"gemini-2.5-pro","tokenType":"REQUESTS","remainingFraction":0.8},{"modelId":"gemini-2.5-pro_vertex","tokenType":"REQUESTS","remainingFraction":0.45,"resetTime":"2026-11-28T11:00:00Z"},{"modelId":"gemini-3.1-pro-preview","tokenType":"REQUESTS","remainingFraction":1.0}]}"#
    let gemini = try GeminiQuotaParser.parse(
        accountID: "gem",
        quotaJSON: Data(geminiQuotaFixture.utf8),
        email: "gemini.user@example.test",
        planLabel: "AI Pro"
    )
    try require(gemini.provider == .gemini && gemini.accountEmail == "gemini.user@example.test" && gemini.planLabel == "AI Pro",
                "Gemini 账号元数据解析错误")
    try require(gemini.buckets.map(\.id) == ["gemini-3.1-pro-preview", "gemini-2.5-pro", "gemini-2.5-flash"],
                "Gemini 模型去重或排序错误")
    try require(gemini.buckets.map(\.title) == ["Gemini 3.1 Pro Preview", "Gemini 2.5 Pro", "Gemini 2.5 Flash"],
                "Gemini 模型显示名称错误")
    try require(gemini.buckets[0].formattedRemainingPercent == "100%"
                && gemini.buckets[1].formattedRemainingPercent == "45%"
                && gemini.buckets[2].formattedRemainingPercent == "90%"
                && gemini.buckets[0].resetsAt != nil && gemini.buckets[1].resetsAt != nil,
                "Gemini 剩余百分比合并或重置时间解析错误")
    let geminiFallbackRoot = try GeminiQuotaParser.parse(
        accountID: "gem2",
        quotaJSON: Data(#"{"quotas":[{"modelId":"gemini-2.5-pro","remainingFraction":0.5}]}"#.utf8)
    )
    try require(geminiFallbackRoot.buckets.count == 1 && geminiFallbackRoot.buckets[0].formattedRemainingPercent == "50%",
                "Gemini quotas 回退键解析错误")
    try requireQuotaError("Gemini 接受了空额度响应") {
        _ = try GeminiQuotaParser.parse(accountID: "bad", quotaJSON: Data(#"{"buckets":[]}"#.utf8))
    }
}

actor MockQuotaFetcher: QuotaFetching {
    enum Response {
        case quota(Date, Double)
        case failure
        case suspended
    }

    var response: Response = .quota(Date(timeIntervalSince1970: 1_800_000_000), 20)
    private(set) var requests: [String] = []
    private var waiting: [String: CheckedContinuation<QuotaAccountSnapshot, Error>] = [:]

    func setResponse(_ response: Response) { self.response = response }

    func fetchQuota(for account: QuotaAccountConfig) async throws -> QuotaAccountSnapshot {
        requests.append(account.id)
        switch response {
        case .quota(let date, let used): return Self.snapshot(account, date: date, used: used)
        case .failure: throw QuotaError.commandFailed("模拟查询失败")
        case .suspended:
            // Simulate a provider that still delivers a result after cancellation.
            return try await withCheckedThrowingContinuation { waiting[account.id] = $0 }
        }
    }

    func completeCancelled(_ account: QuotaAccountConfig) {
        waiting.removeValue(forKey: account.id)?.resume(returning: Self.snapshot(account, date: .now, used: 99))
    }

    static func snapshot(_ account: QuotaAccountConfig, date: Date, used: Double) -> QuotaAccountSnapshot {
        QuotaAccountSnapshot(accountID: account.id, provider: account.provider, accountEmail: nil, planLabel: "Pro",
                             buckets: [.init(id: "test", title: "5 小时", usedPercent: used, resetsAt: nil,
                                             windowMinutes: 300, detail: nil)],
                             resetCreditsCount: nil, creditBalance: nil, fetchedAt: date)
    }
}

@MainActor
func waitForRefresh(_ monitor: QuotaMonitorModel) async throws {
    let deadline = Date().addingTimeInterval(2)
    while monitor.isRefreshing && Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
    try require(!monitor.isRefreshing, "模拟刷新超时")
}

func waitForRequests(_ count: Int, from fetcher: MockQuotaFetcher) async throws {
    let deadline = Date().addingTimeInterval(2)
    while await fetcher.requests.count < count && Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
    let observed = await fetcher.requests.count
    try require(observed >= count, "模拟请求未启动")
}

@MainActor
func testMonitor(directory: URL) async throws {
    let url = directory.appendingPathComponent("Quota/state.json")
    let fetcher = MockQuotaFetcher()
    let baseline = Date(timeIntervalSince1970: 1_800_000_000)
    let model = QuotaMonitorModel(fileURL: url, fetcher: fetcher, now: { baseline })
    let defaults = QuotaAccountConfig.defaultAccounts
    let codex = defaults[0]
    let key = QuotaPersistedState.historyKey(accountID: codex.id, bucketID: "test")
    try require(model.accounts == defaults && model.snapshots.isEmpty && !model.isRefreshing, "默认双账号或初始状态错误")
    let initialRequests = await fetcher.requests
    try require(initialRequests.isEmpty, "初始化时已发送查询")

    model.refreshStaleAccounts()
    try require(model.refreshingAccountIDs == Set(defaults.map(\.id)), "首开时未并发调度双账号")
    try await waitForRefresh(model)
    model.refreshStaleAccounts()
    let firstRequests = await fetcher.requests
    try require(model.snapshots.count == 2 && firstRequests.count == 2 && model.history[key]?.count == 1,
                "首开重复查询或未写入快照与采样")

    let reopened = QuotaMonitorModel(fileURL: url, fetcher: fetcher, now: { baseline })
    reopened.refreshStaleAccounts()
    try require(!reopened.isRefreshing && reopened.snapshots == model.snapshots && reopened.history == model.history,
                "有缓存的首开重新查询，或已保存的数据无法重读")

    await fetcher.setResponse(.quota(baseline.addingTimeInterval(59), 20.02))
    model.refresh(accountID: codex.id)
    try await waitForRefresh(model)
    try require(model.snapshots[codex.id]?.buckets.first?.usedPercent == 20.02 && model.history[key]?.count == 1,
                "60 秒内微小变化应更新快照并去重采样")
    await fetcher.setResponse(.quota(baseline.addingTimeInterval(59), 20.06))
    model.refresh(accountID: codex.id)
    try await waitForRefresh(model)
    try require(model.history[key]?.count == 2, "60 秒内显著变化被误删")
    for index in 1...100 {
        await fetcher.setResponse(.quota(baseline.addingTimeInterval(Double(index * 60 + 59)), 25))
        model.refresh(accountID: codex.id)
        try await waitForRefresh(model)
    }
    try require(model.history[key]?.count == 96
                && model.history[key]?.first?.timestamp == baseline.addingTimeInterval(5 * 60 + 59),
                "历史上限、时间边界或淘汰顺序错误")

    let beforeFailure = model.snapshots
    await fetcher.setResponse(.failure)
    model.refresh(accountID: codex.id)
    try await waitForRefresh(model)
    try require(model.snapshots == beforeFailure && model.errorsByAccountID[codex.id] == "模拟查询失败",
                "查询失败未保留旧缓存或未发布错误")

    let count = await fetcher.requests.count
    await fetcher.setResponse(.suspended)
    model.refresh(accountID: codex.id)
    try await waitForRequests(count + 1, from: fetcher)
    await fetcher.setResponse(.quota(baseline.addingTimeInterval(10_000), 42))
    model.refresh(accountID: codex.id)
    try await waitForRefresh(model)
    await fetcher.completeCancelled(codex)
    await Task.yield()
    try require(model.snapshots[codex.id]?.buckets.first?.usedPercent == 42 && model.errorsByAccountID[codex.id] == nil,
                "旧请求覆盖新结果，或成功后错误未清除")

    model.filter = .antigravity
    model.beginAddAccount()
    model.draftLabel = " \n "
    model.saveAccountDraft()
    try require(model.editorOpen && model.editorError != nil && model.accounts.count == 2, "空白名称未通过表单校验")
    model.draftLabel = " 工作账号 "
    model.draftPlanOverride = " Ultra "
    model.draftCustomHomePath = " ~/test-home "
    model.draftCustomBinaryPath = " /tmp/test-agy "
    model.saveAccountDraft()
    guard let added = model.accounts.last else { throw QuotaTestFailure(message: "没有保存新增账号") }
    try require(!model.editorOpen && added.provider == .antigravity && added.label == "工作账号" && added.planOverride == "Ultra"
                && added.customHomePath == "~/test-home" && added.customBinaryPath == "/tmp/test-agy" && !added.isBuiltIn,
                "新增账号未保存规范化字段或供应商")
    try require(model.visibleAccounts.map(\.id) == [defaults[1].id, added.id], "供应商筛选错误")
    model.beginEditAccount(added)
    model.draftLabel = "新名称"
    model.saveAccountDraft()
    try require(model.accounts.last?.id == added.id && model.accounts.last?.label == "新名称", "编辑账号丢失稳定 ID")
    model.deleteAccount(id: added.id)
    model.beginEditAccount(codex)
    model.draftCustomHomePath = "~/different"
    model.saveAccountDraft()
    try require(model.snapshots[codex.id] == nil && model.history[key] == nil, "切换配置目录后仍显示上一账号额度")
    model.deleteAccount(id: defaults[1].id)
    try require(model.canRestoreBuiltInAccounts && model.snapshots[defaults[1].id] == nil
                && model.history.values.isEmpty, "删除账号后未清理历史、快照或恢复入口")
    model.restoreBuiltInAccounts()
    try require(!model.canRestoreBuiltInAccounts && model.filter == .all && model.accounts.map(\.id) == defaults.map(\.id),
                "恢复内置账号重复或遗漏账号")
    let disk = try JSONFileStore<QuotaPersistedState>(fileURL: url).load()
    try require(disk.accounts == model.accounts && disk.snapshots == model.snapshots && disk.history == model.history,
                "变更后的账号、快照及采样未同步落盘")

    let pendingCount = await fetcher.requests.count
    await fetcher.setResponse(.suspended)
    model.refreshAll()
    try await waitForRequests(pendingCount + 2, from: fetcher)
    model.beginAddAccount()
    model.shutdown()
    for account in defaults { await fetcher.completeCancelled(account) }
    await Task.yield()
    try require(!model.editorOpen && !model.isRefreshing && model.errorsByAccountID.isEmpty && model.snapshots == disk.snapshots,
                "关闭模型未释放编辑器及活动任务，或迟到结果覆盖缓存")
    model.refreshStaleAccounts()
    try require(!model.isRefreshing, "刷新失败或取消后的再次进入启动了自动查询")
}

@MainActor
func testSnapshotFreshness(directory: URL) async throws {
    let url = directory.appendingPathComponent("QuotaFreshness/state.json")
    let fetcher = MockQuotaFetcher()
    let baseline = Date(timeIntervalSince1970: 1_800_000_000)
    var now = baseline
    var state = QuotaPersistedState.empty
    let stale = state.accounts[0]
    let boundary = state.accounts[1]
    let missing = QuotaAccountConfig(id: "missing", provider: .codex, label: "尚未查询",
                                     planOverride: nil, customHomePath: nil, customBinaryPath: nil, isBuiltIn: false)
    state.accounts.append(missing)
    state.snapshots[stale.id] = MockQuotaFetcher.snapshot(stale, date: baseline.addingTimeInterval(-301), used: 10)
    state.snapshots[boundary.id] = MockQuotaFetcher.snapshot(boundary, date: baseline.addingTimeInterval(-300), used: 20)
    try JSONFileStore<QuotaPersistedState>(fileURL: url).save(state)

    await fetcher.setResponse(.suspended)
    let monitor = QuotaMonitorModel(fileURL: url, fetcher: fetcher, now: { now })
    try require(!monitor.isRefreshing, "读取过期的磁盘快照时提前查询")
    monitor.refreshStaleAccounts()
    try require(monitor.refreshingAccountIDs == [stale.id, missing.id],
                "首开应逐账号查询过期和缺失快照，恰好 300 秒的快照仍有效")
    try await waitForRequests(2, from: fetcher)

    await fetcher.setResponse(.failure)
    now = baseline.addingTimeInterval(1)
    monitor.refreshStaleAccounts()
    try require(monitor.refreshingAccountIDs == [stale.id, boundary.id, missing.id],
                "时间超过 300 秒后未查询刚刚过期的账号")
    try await waitForRequests(3, from: fetcher)
    await fetcher.completeCancelled(stale)
    await fetcher.completeCancelled(missing)
    try await waitForRefresh(monitor)
    let requests = await fetcher.requests
    try require(requests.count == 3 && Set(requests) == [stale.id, boundary.id, missing.id],
                "自动检查重复发起了进行中的请求")
    try require(monitor.snapshots[stale.id]?.buckets.first?.usedPercent == 99
                && monitor.snapshots[missing.id]?.buckets.first?.usedPercent == 99
                && monitor.snapshots[boundary.id] == state.snapshots[boundary.id],
                "自动检查取消了现有请求，或查询失败未保留旧快照")
}

func testFakeExecutables(directory: URL) async throws {
    func executable(_ name: String, _ body: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url.path
    }

    var codex = QuotaAccountConfig.defaultAccounts[0]
    codex.customHomePath = directory.path
    codex.customBinaryPath = try executable("fake-codex", """
        test "$*" = "app-server --listen stdio://" || exit 4
        test "$CODEX_HOME" = "$(dirname "$0")" || exit 5
        /bin/dd if=/dev/zero bs=1024 count=200 >&2 2>/dev/null
        IFS= read -r initialize
        case "$initialize" in *initialize*) ;; *) exit 6 ;; esac
        echo '{"id":1,"result":{}}'
        IFS= read -r initialized
        IFS= read -r limits
        IFS= read -r account
        case "$initialized:$limits:$account" in *initialized*account/rateLimits/read*account/read*) ;; *) exit 7 ;; esac
        echo '{"id":3,"result":{"account":{"email":"fake@example.test"}}}'
        echo '{"id":2,\(codexFixture.dropFirst())'
        """)
    let fetcher = CLIQuotaFetcher(timeoutSeconds: 3)
    let snapshot = try await fetcher.fetchQuota(for: codex)
    try require(snapshot.buckets.count == 3 && snapshot.accountEmail == "fake@example.test", "CLI Codex 收发协议或 stderr 排空失败")

    var agy = QuotaAccountConfig.defaultAccounts[1]
    agy.customHomePath = directory.path
    agy.customBinaryPath = try executable("fake-agy", """
        test "$*" = "--print-timeout 1s --output-format json -p /usage" || exit 8
        test "$HOME" = "$(dirname "$0")" || exit 9
        echo '本地诊断行'
        echo '\(agyFixture)'
        """)
    let agySnapshot = try await fetcher.fetchQuota(for: agy)
    try require(agySnapshot.buckets.count == 4, "CLI Antigravity 启动参数、环境或 JSON 输出错误")

    agy.customBinaryPath = try executable("fake-agy-timeout", "trap '' TERM\nwhile :; do :; done")
    let timedAccount = agy
    let fastFetcher = CLIQuotaFetcher(timeoutSeconds: 0.2)
    do {
        _ = try await fastFetcher.fetchQuota(for: timedAccount)
        throw QuotaTestFailure(message: "超时命令返回成功")
    } catch QuotaError.timedOut(.antigravity) {
        // Expected.
    }
    let task = Task { try await fetcher.fetchQuota(for: timedAccount) }
    try await Task.sleep(nanoseconds: 50_000_000)
    task.cancel()
    do {
        _ = try await task.value
        throw QuotaTestFailure(message: "取消的命令返回成功")
    } catch QuotaError.cancelled {
        // Expected.
    }
}

func makeHTTPResponse(url: URL, statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
}

@MainActor
func testDeepSeekAndGeminiIntegration(directory: URL) async throws {
    let service = "com.clipflow.mac.quota.selftest.\(UUID().uuidString)"
    let credentials = CredentialStore(service: service)
    var createdCredentialIDs: [String] = []
    defer {
        for id in createdCredentialIDs { try? credentials.delete(id: id) }
    }

    // 1. DeepSeek monitor CRUD + Keychain isolation + HTTP fetch
    let stateURL = directory.appendingPathComponent("QuotaHTTP/state.json")
    let baseline = Date(timeIntervalSince1970: 1_800_000_000)

    final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        var urls: [String] = []
        var authHeaders: [String] = []
        func record(_ request: URLRequest) {
            lock.lock()
            urls.append(request.url?.absoluteString ?? "")
            authHeaders.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            lock.unlock()
        }
    }
    let dsLog = RequestLog()
    let dsFetcher = CLIQuotaFetcher(
        timeoutSeconds: 3,
        credentials: credentials,
        transport: { request in
            dsLog.record(request)
            let url = request.url!
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-deepseek-test-2" else {
                return (Data(#"{"error":{"message":"invalid key"}}"#.utf8), makeHTTPResponse(url: url, statusCode: 401))
            }
            let body = #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"48.50","granted_balance":"8.50","topped_up_balance":"40.00"}]}"#
            return (Data(body.utf8), makeHTTPResponse(url: url, statusCode: 200))
        },
        now: { baseline }
    )
    let monitor = QuotaMonitorModel(fileURL: stateURL, fetcher: dsFetcher, credentials: credentials, now: { baseline })
    monitor.filter = .deepseek
    monitor.beginAddAccount()
    try require(monitor.draftProvider == .deepseek, "按 DeepSeek 筛选时新建账号未默认选中 DeepSeek")
    monitor.draftLabel = "主 API"
    monitor.saveAccountDraft()
    try require(monitor.editorOpen && monitor.editorError != nil, "DeepSeek 缺少 API Key 时未拦截保存")
    monitor.draftAPIKey = "sk-deepseek-test-1"
    monitor.draftCustomBaseURL = "http://api.deepseek.com"
    monitor.saveAccountDraft()
    try require(monitor.editorOpen && monitor.editorError != nil, "DeepSeek 远程 HTTP 地址未拦截保存")
    monitor.draftCustomBaseURL = "https://api.deepseek.com/v1"
    monitor.saveAccountDraft()
    guard let dsAccount = monitor.accounts.last, dsAccount.provider == .deepseek, let credID = dsAccount.credentialID else {
        throw QuotaTestFailure(message: "DeepSeek 账号未保存或缺少钥匙串 ID")
    }
    createdCredentialIDs.append(credID)
    let stateRaw = try String(contentsOf: stateURL, encoding: .utf8)
    try require(!stateRaw.contains("sk-deepseek-test-1"), "DeepSeek API Key 明文泄漏到了 state.json")
    try require(try credentials.secret(id: credID) == "sk-deepseek-test-1", "DeepSeek API Key 未写入独立钥匙串服务")

    // Edit label without replacing API key preserves secret.
    monitor.beginEditAccount(dsAccount)
    try require(monitor.draftHasSavedAPIKey && monitor.draftAPIKey.isEmpty, "编辑 DeepSeek 账号时未隐藏已保存密钥")
    monitor.draftLabel = "DeepSeek 生产"
    monitor.saveAccountDraft()
    try require(try credentials.secret(id: credID) == "sk-deepseek-test-1", "留空保存破坏了已存在的 DeepSeek 密钥")

    // First fetch fails with 401 for sk-deepseek-test-1.
    monitor.refresh(accountID: dsAccount.id)
    try await waitForRefresh(monitor)
    try require(monitor.errorsByAccountID[dsAccount.id]?.contains("401") == true, "DeepSeek 401 错误未正确呈现")

    // Update API key -> clears error and succeeds.
    monitor.beginEditAccount(monitor.accounts.last!)
    monitor.draftAPIKey = "sk-deepseek-test-2"
    monitor.saveAccountDraft()
    if let updatedCred = monitor.accounts.last?.credentialID, !createdCredentialIDs.contains(updatedCred) {
        createdCredentialIDs.append(updatedCred)
    }
    try require(monitor.errorsByAccountID[dsAccount.id] == nil, "更新 DeepSeek API Key 后未清除旧错误")
    monitor.refresh(accountID: dsAccount.id)
    try await waitForRefresh(monitor)
    try require(monitor.snapshots[dsAccount.id]?.creditBalance == "¥48.50"
                && monitor.snapshots[dsAccount.id]?.balances?.first?.formattedTotal == "¥48.50"
                && dsLog.urls.last == "https://api.deepseek.com/user/balance",
                "DeepSeek 余额拉取或快照保存失败")

    // Delete removes Keychain secret.
    let finalCredID = monitor.accounts.last!.credentialID!
    monitor.deleteAccount(id: dsAccount.id)
    var secretStillExists = true
    do {
        _ = try credentials.secret(id: finalCredID)
    } catch {
        secretStillExists = false
    }
    try require(!secretStillExists, "删除 DeepSeek 账号后未删除对应钥匙串条目")

    // 2. Gemini OAuth: valid token, expired token refresh + persistence, missing credentials
    let geminiDir = directory.appendingPathComponent("gemini-home")
    try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
    let jwtPayload = Data(#"{"email":"dev@google.test"}"#.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    let idToken = "eyJhbGciOiJSUzI1NiJ9.\(jwtPayload).sig"

    // 2a. Valid unexpired token
    let credsURL = geminiDir.appendingPathComponent("oauth_creds.json")
    let validExpiryMs = Int64(baseline.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
    try """
    {"access_token":"ya29.valid","refresh_token":"1//ref","id_token":"\(idToken)","expiry_date":\(validExpiryMs)}
    """.write(to: credsURL, atomically: true, encoding: .utf8)

    let geminiAccount = QuotaAccountConfig(
        id: "gemini.test",
        provider: .gemini,
        label: "个人 Gemini",
        customHomePath: geminiDir.path,
        isBuiltIn: false
    )
    let geminiFetcher = CLIQuotaFetcher(
        timeoutSeconds: 3,
        credentials: credentials,
        transport: { request in
            let url = request.url!
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.valid" else {
                return (Data(#"{"error":{"message":"unauthorized"}}"#.utf8), makeHTTPResponse(url: url, statusCode: 401))
            }
            if url.absoluteString.contains("loadCodeAssist") {
                return (Data(#"{"cloudaicompanionProject":"proj-xyz","paidTier":{"id":"g1-ultra-tier","name":"Google AI Ultra"}}"#.utf8),
                        makeHTTPResponse(url: url, statusCode: 200))
            }
            let bodyText = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            guard bodyText.contains("proj-xyz") else {
                return (Data(#"{"error":{"message":"missing project"}}"#.utf8), makeHTTPResponse(url: url, statusCode: 400))
            }
            return (Data(#"{"buckets":[{"modelId":"gemini-2.5-pro","remainingFraction":0.72,"resetTime":"2026-11-28T10:00:00Z"}]}"#.utf8),
                    makeHTTPResponse(url: url, statusCode: 200))
        },
        now: { baseline }
    )
    let geminiSnapshot = try await geminiFetcher.fetchQuota(for: geminiAccount)
    try require(geminiSnapshot.accountEmail == "dev@google.test"
                && geminiSnapshot.planLabel == "AI Ultra"
                && geminiSnapshot.buckets.first?.formattedRemainingPercent == "72%",
                "Gemini OAuth 有效令牌查询失败")

    // 2b. Expired token auto-refresh via fake gemini CLI oauth2.js + persistence
    let fakeInstall = directory.appendingPathComponent("fake-gemini-pkg")
    let binDir = fakeInstall.appendingPathComponent("bin")
    let oauthDir = fakeInstall.appendingPathComponent("lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist")
    try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: oauthDir, withIntermediateDirectories: true)
    let fakeBin = binDir.appendingPathComponent("gemini")
    try "#!/bin/sh\nexit 0\n".write(to: fakeBin, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeBin.path)
    try """
    const OAUTH_CLIENT_ID = 'fake-client-id.apps.googleusercontent.com';
    const OAUTH_CLIENT_SECRET = 'GOCSPX-fake-secret';
    """.write(to: oauthDir.appendingPathComponent("oauth2.js"), atomically: true, encoding: .utf8)

    let expiredMs = Int64(baseline.addingTimeInterval(-120).timeIntervalSince1970 * 1000)
    try """
    {"access_token":"ya29.expired","refresh_token":"1//ref-keep","id_token":"\(idToken)","expiry_date":\(expiredMs)}
    """.write(to: credsURL, atomically: true, encoding: .utf8)

    var refreshAccount = geminiAccount
    refreshAccount.customBinaryPath = fakeBin.path
    let refreshFetcher = CLIQuotaFetcher(
        timeoutSeconds: 3,
        credentials: credentials,
        transport: { request in
            let url = request.url!
            if url.absoluteString == "https://oauth2.googleapis.com/token" {
                let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                guard body.contains("client_id=fake-client-id.apps.googleusercontent.com"),
                      body.contains("client_secret=GOCSPX-fake-secret"),
                      body.contains("refresh_token=1%2F%2Fref-keep") else {
                    return (Data(#"{"error":"invalid_client"}"#.utf8), makeHTTPResponse(url: url, statusCode: 400))
                }
                return (Data(#"{"access_token":"ya29.refreshed","expires_in":3600,"token_type":"Bearer"}"#.utf8),
                        makeHTTPResponse(url: url, statusCode: 200))
            }
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.refreshed" else {
                return (Data(#"{"error":{"message":"stale token"}}"#.utf8), makeHTTPResponse(url: url, statusCode: 401))
            }
            if url.absoluteString.contains("loadCodeAssist") {
                return (Data(#"{"cloudaicompanionProject":"proj-ref","currentTier":{"id":"free-tier"}}"#.utf8),
                        makeHTTPResponse(url: url, statusCode: 200))
            }
            return (Data(#"{"buckets":[{"modelId":"gemini-2.5-flash","remainingFraction":0.64}]}"#.utf8),
                    makeHTTPResponse(url: url, statusCode: 200))
        },
        now: { baseline }
    )
    let refreshedSnapshot = try await refreshFetcher.fetchQuota(for: refreshAccount)
    try require(refreshedSnapshot.planLabel == "Free" && refreshedSnapshot.buckets.first?.formattedRemainingPercent == "64%",
                "Gemini 过期令牌刷新后查询失败")
    let persistedCreds = try JSONSerialization.jsonObject(with: Data(contentsOf: credsURL)) as? [String: Any]
    try require(persistedCreds?["access_token"] as? String == "ya29.refreshed"
                && persistedCreds?["refresh_token"] as? String == "1//ref-keep",
                "Gemini 刷新后的新令牌未写回 oauth_creds.json 或丢失了 refresh_token")

    // 2c. Missing credentials with gemini-api-key settings gives clear error
    let emptyGeminiDir = directory.appendingPathComponent("gemini-apikey-only")
    try FileManager.default.createDirectory(at: emptyGeminiDir, withIntermediateDirectories: true)
    try #"{"security":{"auth":{"selectedType":"gemini-api-key"}}}"#
        .write(to: emptyGeminiDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    let missingAccount = QuotaAccountConfig(id: "gem.missing", provider: .gemini, label: "Missing", customHomePath: emptyGeminiDir.path, isBuiltIn: false)
    do {
        _ = try await geminiFetcher.fetchQuota(for: missingAccount)
        throw QuotaTestFailure(message: "缺少 Gemini OAuth 凭证时未报错")
    } catch let QuotaError.commandFailed(message) {
        try require(message.contains("gemini-api-key") && message.contains("OAuth"), "缺少 OAuth 凭证时的提示不明确：\(message)")
    }

    // 3. Google Web OAuth loopback flow + PKCE + Keychain-backed Gemini refresh & mode switch
    final class CapturedAuthURL: @unchecked Sendable {
        private let lock = NSLock()
        var challenge: String?
        func setChallenge(_ value: String?) {
            lock.lock(); challenge = value; lock.unlock()
        }
        func getChallenge() -> String? {
            lock.lock(); defer { lock.unlock() }; return challenge
        }
    }
    let capturedAuth = CapturedAuthURL()
    let webAuthenticator = GeminiWebOAuthAuthenticator(
        timeoutSeconds: 5,
        transport: { request in
            let url = request.url!
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            var form: [String: String] = [:]
            for pair in body.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    form[String(parts[0])] = String(parts[1]).removingPercentEncoding ?? String(parts[1])
                }
            }
            guard form["grant_type"] == "authorization_code",
                  form["code"] == "web-auth-code-99",
                  let verifier = form["code_verifier"],
                  GeminiWebOAuthAuthenticator.pkceChallenge(for: verifier) == capturedAuth.getChallenge() else {
                return (Data(#"{"error":"invalid_grant"}"#.utf8), makeHTTPResponse(url: url, statusCode: 400))
            }
            let responseBody = """
            {"access_token":"ya29.web-token","refresh_token":"1//web-refresh","id_token":"\(idToken)","expires_in":3600,"token_type":"Bearer"}
            """
            return (Data(responseBody.utf8), makeHTTPResponse(url: url, statusCode: 200))
        },
        openBrowser: { authURL in
            guard let components = URLComponents(url: authURL, resolvingAgainstBaseURL: false) else { return false }
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            guard let redirect = query["redirect_uri"], let state = query["state"] else { return false }
            capturedAuth.setChallenge(query["code_challenge"])
            Task.detached {
                if let callbackURL = URL(string: "\(redirect)?code=web-auth-code-99&state=\(state)") {
                    _ = try? await URLSession.shared.data(from: callbackURL)
                }
            }
            return true
        },
        now: { baseline }
    )
    let webAuthResult = try await webAuthenticator.authenticate(customBinaryPath: fakeBin.path)
    try require(webAuthResult.email == "dev@google.test"
                && webAuthResult.credentialsJSON.contains("ya29.web-token")
                && webAuthResult.credentialsJSON.contains("1//web-refresh")
                && webAuthResult.credentialsJSON.contains("fake-client-id.apps.googleusercontent.com"),
                "Google 网页 OAuth 回调、PKCE 或令牌交换失败")

    struct StubWebAuthenticator: GeminiWebAuthenticating {
        let result: GeminiWebAuthResult
        func authenticate(customBinaryPath: String?) async throws -> GeminiWebAuthResult { result }
    }
    let expiredWebJSON = """
    {"access_token":"ya29.web-expired","refresh_token":"1//web-ref","id_token":"\(idToken)","client_id":"fake-client-id.apps.googleusercontent.com","client_secret":"GOCSPX-fake-secret","expiry_date":\(expiredMs)}
    """
    let webMonitor = QuotaMonitorModel(
        fileURL: directory.appendingPathComponent("QuotaWebGemini/state.json"),
        fetcher: CLIQuotaFetcher(
            timeoutSeconds: 3,
            credentials: credentials,
            transport: { request in
                let url = request.url!
                if url.absoluteString == "https://oauth2.googleapis.com/token" {
                    return (Data(#"{"access_token":"ya29.web-new","expires_in":3600,"token_type":"Bearer"}"#.utf8),
                            makeHTTPResponse(url: url, statusCode: 200))
                }
                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.web-new" else {
                    return (Data(#"{"error":{"message":"stale"}}"#.utf8), makeHTTPResponse(url: url, statusCode: 401))
                }
                if url.absoluteString.contains("loadCodeAssist") {
                    return (Data(#"{"cloudaicompanionProject":"proj-web","paidTier":{"id":"g1-pro-tier"}}"#.utf8),
                            makeHTTPResponse(url: url, statusCode: 200))
                }
                return (Data(#"{"buckets":[{"modelId":"gemini-2.5-pro","remainingFraction":0.85}]}"#.utf8),
                        makeHTTPResponse(url: url, statusCode: 200))
            },
            now: { baseline }
        ),
        credentials: credentials,
        geminiAuthenticator: StubWebAuthenticator(result: GeminiWebAuthResult(email: "dev@google.test", credentialsJSON: expiredWebJSON)),
        now: { baseline }
    )
    webMonitor.filter = .gemini
    webMonitor.beginAddAccount()
    try require(webMonitor.draftProvider == .gemini && webMonitor.draftGeminiAuthMode == .webOAuth,
                "新建 Gemini 账号未默认选择 Google 网页登录")
    webMonitor.draftLabel = "未授权"
    try require(webMonitor.saveAccountDraft() == nil && webMonitor.editorError != nil,
                "Google 网页登录未授权时未拦截保存")
    webMonitor.draftLabel = ""
    webMonitor.startGeminiWebLogin()
    let authDeadline = Date().addingTimeInterval(2)
    while webMonitor.isAuthenticatingGemini && Date() < authDeadline {
        try await Task.sleep(nanoseconds: 2_000_000)
    }
    try require(webMonitor.draftPendingGeminiAuth?.email == "dev@google.test" && webMonitor.draftLabel == "dev@google.test",
                "Google 网页登录完成后未自动回填邮箱与授权状态")
    guard let savedWebID = webMonitor.saveAccountDraft(),
          let savedWebAccount = webMonitor.accounts.first(where: { $0.id == savedWebID }),
          let webCredID = savedWebAccount.credentialID else {
        throw QuotaTestFailure(message: "Google 网页登录账号未保存到钥匙串")
    }
    createdCredentialIDs.append(webCredID)
    let webStateRaw = try String(contentsOf: directory.appendingPathComponent("QuotaWebGemini/state.json"), encoding: .utf8)
    try require(!webStateRaw.contains("ya29.web-expired") && !webStateRaw.contains("1//web-ref"),
                "Google 网页 OAuth 令牌明文泄漏到了 state.json")
    webMonitor.refresh(accountID: savedWebID)
    try await waitForRefresh(webMonitor)
    try require(webMonitor.snapshots[savedWebID]?.accountEmail == "dev@google.test"
                && webMonitor.snapshots[savedWebID]?.planLabel == "AI Pro"
                && webMonitor.snapshots[savedWebID]?.buckets.first?.formattedRemainingPercent == "85%",
                "钥匙串存储的 Google 网页 OAuth 令牌刷新或查询失败")
    let updatedKeychainSecret = try credentials.secret(id: webCredID)
    try require(updatedKeychainSecret.contains("ya29.web-new") && updatedKeychainSecret.contains("1//web-ref"),
                "刷新后的 Google 网页 OAuth 令牌未写回钥匙串")

    // Switching web OAuth account to local CLI cleans up obsolete Keychain credential.
    webMonitor.beginEditAccount(savedWebAccount)
    try require(webMonitor.draftGeminiAuthMode == .webOAuth && webMonitor.draftHasSavedGeminiOAuth,
                "编辑网页登录 Gemini 账号时未保留网页登录状态")
    webMonitor.draftGeminiAuthMode = .localCLI
    webMonitor.draftCustomHomePath = geminiDir.path
    _ = webMonitor.saveAccountDraft()
    var webSecretStillExists = true
    do {
        _ = try credentials.secret(id: webCredID)
    } catch {
        webSecretStillExists = false
    }
    try require(!webSecretStillExists, "从 Google 网页登录切换到本机 CLI 凭证后未清理旧钥匙串条目")

    // 4. Legacy state.json compatibility (without customBaseURL, credentialID, balances)
    let legacyJSON = #"{"accounts":[{"id":"builtin.codex.local","provider":"codex","label":"本机 Codex","isBuiltIn":true}],"snapshots":{"builtin.codex.local":{"accountID":"builtin.codex.local","provider":"codex","buckets":[],"fetchedAt":1800000000}},"history":{}}"#
    let decodedLegacy = try JSONDecoder().decode(QuotaPersistedState.self, from: Data(legacyJSON.utf8))
    try require(decodedLegacy.accounts.count == 1 && decodedLegacy.accounts[0].credentialID == nil
                && decodedLegacy.snapshots["builtin.codex.local"]?.balances == nil,
                "旧版 Quota/state.json 向后兼容解码失败")
}

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClipFlowQuotaSelfTest-\(UUID().uuidString)")
do {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try testAccountPresentation()
    try testParsers()
    try await testMonitor(directory: directory)
    try await testSnapshotFreshness(directory: directory)
    try await testFakeExecutables(directory: directory)
    try await testDeepSeekAndGeminiIntegration(directory: directory)
    print("PASS: Codex、Antigravity、Gemini OAuth 与 DeepSeek 的界面名称和账号标签、额度与余额解析、模拟 CLI/HTTP 查询与令牌刷新、钥匙串隔离、取消、并发刷新、缓存、五分钟逐账号过期检查、历史采样及旧数据兼容")
} catch {
    fputs("FAIL: \((error as? QuotaTestFailure)?.message ?? error.localizedDescription)\n", stderr)
    exit(1)
}
