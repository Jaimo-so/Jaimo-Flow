import AppKit
import SwiftUI

struct QuotaView: View {
    @ObservedObject var model: QuotaMonitorModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        ZStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    header(theme)
                    filters(theme)
                    if let error = model.storageError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.foregroundSecondary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .flowInset(theme)
                            .padding(.horizontal, 18)
                            .padding(.top, 8)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                    ScrollView {
                        if model.visibleAccounts.isEmpty {
                            emptyState(theme)
                                .padding(18)
                        } else {
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                QuotaMasonryLayout(columns: columnCount(for: geometry.size.width), spacing: 12) {
                                    ForEach(model.visibleAccounts) { account in
                                        QuotaAccountCard(
                                            account: account, model: model, theme: theme, now: context.date
                                        )
                                    }
                                }
                            }
                            .padding(.horizontal, 18)
                            .padding(.top, 12)
                            .padding(.bottom, 18)
                        }
                    }
                }
            }
            .disabled(model.editorOpen)
            .accessibilityHidden(model.editorOpen)

            if model.editorOpen {
                QuotaAccountEditor(model: model, theme: theme)
                    .transition(FlowMotion.reveal(reduceMotion: reduceMotion))
                    .zIndex(1)
            }
        }
        .animation(reduceMotion ? FlowMotion.reduced : FlowMotion.content, value: model.editorOpen)
    }

    private func header(_ theme: ClipFlowTheme) -> some View {
        HStack(spacing: 10) {
            Text("账号额度")
                .font(.system(size: 23, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Text("\(model.accounts.count) 个账号")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(theme.muted)
                .fixedSize()
            Button("添加账号", action: model.beginAddAccount)
                .buttonStyle(GlassButtonStyle(kind: .normal))
                .fixedSize()
            Button(action: model.refreshAll) {
                HStack(spacing: 6) {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small).scaleEffect(0.65)
                            .frame(width: 12, height: 12)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: "arrow.clockwise").accessibilityHidden(true)
                    }
                    Text("刷新全部")
                }
            }
            .buttonStyle(GlassButtonStyle(kind: .primary))
            .fixedSize()
            .disabled(model.accounts.isEmpty)
            .accessibilityValue(model.isRefreshing ? "正在刷新" : "")
            .help("刷新全部（⌘R）")
        }
        .padding(.horizontal, 18)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    private func filters(_ theme: ClipFlowTheme) -> some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(QuotaProviderFilter.allCases) { filter in
                        let selected = model.filter == filter
                        Button { model.filter = filter } label: {
                            Text(filter.title)
                                .fontWeight(selected ? .semibold : .medium)
                        }
                        .buttonStyle(GlassButtonStyle(kind: selected ? .normal : .quiet))
                        .fixedSize()
                        .overlay {
                            Capsule().strokeBorder(selected ? theme.accent.opacity(0.55) : .clear)
                                .allowsHitTesting(false)
                        }
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                    }
                }
                .padding(.vertical, 1)
            }
            if model.canRestoreBuiltInAccounts {
                Button("恢复本机账号", action: model.restoreBuiltInAccounts)
                    .buttonStyle(GlassButtonStyle(kind: .normal))
                    .fixedSize()
            }
        }
        .padding(.horizontal, 18)
    }

    private func emptyState(_ theme: ClipFlowTheme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.accounts.isEmpty ? "还没有账号" : "没有此供应商的账号")
                .font(.system(size: 14, weight: .semibold))
            Button("添加账号", action: model.beginAddAccount)
                .buttonStyle(GlassButtonStyle(kind: .normal))
                .fixedSize()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flowCard(theme)
    }

    private func columnCount(for width: CGFloat) -> Int {
        width >= 940 ? 3 : width >= 580 ? 2 : 1
    }
}

private struct QuotaMasonryLayout: Layout {
    let columns: Int
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let totalWidth = proposal.width ?? 600
        let count = max(1, columns)
        let columnWidth = max(0, (totalWidth - CGFloat(count - 1) * spacing) / CGFloat(count))
        var columnHeights = Array(repeating: CGFloat(0), count: count)

        for subview in subviews {
            let column = shortestColumnIndex(in: columnHeights)
            let size = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
            columnHeights[column] += (columnHeights[column] > 0 ? spacing : 0) + size.height
        }
        return CGSize(width: totalWidth, height: columnHeights.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let count = max(1, columns)
        let columnWidth = max(0, (bounds.width - CGFloat(count - 1) * spacing) / CGFloat(count))
        var columnHeights = Array(repeating: CGFloat(0), count: count)

        for subview in subviews {
            let column = shortestColumnIndex(in: columnHeights)
            let x = bounds.minX + CGFloat(column) * (columnWidth + spacing)
            let yOffset = columnHeights[column] + (columnHeights[column] > 0 ? spacing : 0)
            let size = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
            subview.place(
                at: CGPoint(x: x, y: bounds.minY + yOffset),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: columnWidth, height: size.height)
            )
            columnHeights[column] = yOffset + size.height
        }
    }

    private func shortestColumnIndex(in heights: [CGFloat]) -> Int {
        var bestIndex = 0
        var bestHeight = heights[0]
        for index in 1..<heights.count where heights[index] < bestHeight {
            bestHeight = heights[index]
            bestIndex = index
        }
        return bestIndex
    }
}

private struct QuotaAccountCard: View {
    let account: QuotaAccountConfig
    let model: QuotaMonitorModel
    let theme: ClipFlowTheme
    let now: Date

    private var snapshot: QuotaAccountSnapshot? { model.snapshots[account.id] }
    private var error: String? { model.errorsByAccountID[account.id] }
    private var refreshing: Bool { model.refreshingAccountIDs.contains(account.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let snapshot {
                ForEach(snapshot.buckets) { bucket in
                    divider
                    QuotaBucketRow(
                        bucket: bucket,
                        samples: model.history[QuotaPersistedState.historyKey(accountID: account.id, bucketID: bucket.id)] ?? [],
                        theme: theme,
                        now: now
                    )
                }
                if let balances = snapshot.balances, !balances.isEmpty {
                    ForEach(balances) { balance in
                        divider
                        QuotaBalanceRow(balance: balance, theme: theme)
                    }
                } else if snapshot.buckets.isEmpty {
                    Text(account.provider.usesAPIKey ? "服务未提供余额信息" : "CLI 未提供额度窗口")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.muted)
                }
                if snapshot.resetCreditsCount != nil || (snapshot.creditBalance != nil && (snapshot.balances?.isEmpty ?? true)) {
                    footer(snapshot)
                }
            } else if error == nil {
                HStack {
                    Text(refreshing ? "正在查询额度…" : "尚未查询额度")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.muted)
                    Spacer()
                    if !refreshing {
                        Button("立即查询", action: refresh)
                            .buttonStyle(GlassButtonStyle(kind: .normal))
                            .fixedSize()
                    }
                }
                .padding(8)
                .flowInset(theme)
            }

            if let error {
                VStack(alignment: .leading, spacing: 5) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(theme.foregroundSecondary)
                        .accessibilityAddTraits(.updatesFrequently)
                    Button("重试", action: refresh)
                        .buttonStyle(GlassButtonStyle(kind: .quiet))
                        .fixedSize()
                        .accessibilityLabel("重试查询\(account.label)")
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .flowInset(theme)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .flowCard(theme)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                providerBadge
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                Text(account.provider.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                if let plan = account.planOverride ?? snapshot?.planLabel {
                    Text(plan)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .flowGlass(Capsule(), fill: theme.chip, theme: theme)
                        .help(plan)
                }
                Spacer(minLength: 0)
                Button(action: refresh) {
                    if refreshing {
                        ProgressView().controlSize(.small).scaleEffect(0.65)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(FlowIconButtonStyle())
                .accessibilityLabel("刷新\(account.label)")
                .accessibilityValue(refreshing ? "正在刷新" : "")
                .help("刷新此账号")

                Menu {
                    Button("刷新", action: refresh)
                    Button("编辑") { model.beginEditAccount(account) }
                    Button("移除", role: .destructive) { model.deleteAccount(id: account.id) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.muted)
                        .frame(width: 28, height: 28)
                        .flowGlass(Circle(), fill: theme.chip, theme: theme)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("\(account.label)的更多操作")
                .help("更多操作")
            }

            if let label = account.cardLabel(accountEmail: snapshot?.accountEmail) {
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let email = snapshot?.accountEmail {
                emailBadge(email)
            }
            Text(updatedLabel)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(theme.muted)
                .accessibilityLabel("更新时间，\(updatedLabel)")
        }
    }

    @ViewBuilder
    private var providerBadge: some View {
        if let glyph = QuotaProviderIcons.framedGlyph(for: account.provider) {
            ZStack {
                providerBadgeBackground
                providerImage(glyph)
            }
        } else if let icon = QuotaProviderIcons.appIcon(for: account.provider, scheme: theme.scheme) {
            providerImage(icon)
        } else if account.provider == .gemini {
            providerBadgeBackground.overlay {
                Image(systemName: "sparkle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(red: 0.26, green: 0.52, blue: 0.96), Color(red: 0.61, green: 0.45, blue: 0.96)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        } else if account.provider == .deepseek {
            providerBadgeBackground.overlay {
                Text("DS")
                    .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color(red: 0.30, green: 0.42, blue: 1.0))
            }
        } else {
            providerBadgeBackground.overlay {
                Image(systemName: account.provider.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.foreground)
            }
        }
    }

    private var providerBadgeBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return shape
            .fill(theme.scheme == .dark ? theme.card : theme.chipHigh)
            .overlay { shape.strokeBorder(theme.hairline, lineWidth: 1) }
            .frame(width: 24, height: 24)
    }

    private func providerImage(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: 28, height: 28)
    }

    private func emailBadge(_ email: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "person.crop.circle.fill")
                .foregroundStyle(theme.accent)
                .accessibilityHidden(true)
            Text(email)
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.accentWash, in: Capsule())
        .overlay { Capsule().strokeBorder(theme.accent.opacity(0.23)).allowsHitTesting(false) }
        .help(email)
    }

    private var updatedLabel: String {
        guard let date = snapshot?.fetchedAt else { return "未查询" }
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        if minutes < 1 { return "刚刚" }
        if minutes < 60 { return "\(minutes) 分钟前" }
        if minutes < 1_440 { return "\(minutes / 60) 小时前" }
        return "\(minutes / 1_440) 天前"
    }

    private var divider: some View {
        Rectangle().fill(theme.weakHairline).frame(height: 1)
            .accessibilityHidden(true)
    }

    private func footer(_ snapshot: QuotaAccountSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            divider
            if let count = snapshot.resetCreditsCount {
                Label("重置券 ×\(count)", systemImage: "ticket")
            }
            if let balance = snapshot.creditBalance {
                Label("余额 \(balance)", systemImage: "creditcard")
            }
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(theme.foregroundSecondary)
    }

    private func refresh() { model.refresh(accountID: account.id) }
}

private enum QuotaProviderIcons {
    // Static properties cache both successful loads and missing resources for the lifetime of the process.
    private static let antigravityGlyph = bundledImage("antigravity")
    private static let antigravityAppIcon = NSImage(contentsOfFile: "/Applications/Antigravity.app/Contents/Resources/icon.icns")
    private static let codexLight = codexImage("codex-light", appResource: "icon-codex-light.png")
    private static let codexDark = codexImage("codex-dark", appResource: "icon-codex-dark-color.png")
    private static let geminiGlyph = bundledImage("gemini")
    private static let deepseekGlyph = bundledImage("deepseek")

    static func framedGlyph(for provider: QuotaProvider) -> NSImage? {
        switch provider {
        case .antigravity: return antigravityGlyph
        case .gemini: return geminiGlyph
        case .deepseek: return deepseekGlyph
        case .codex: return nil
        }
    }

    static func appIcon(for provider: QuotaProvider, scheme: ColorScheme) -> NSImage? {
        switch provider {
        case .codex: return scheme == .dark ? codexDark : codexLight
        case .antigravity: return antigravityAppIcon
        case .gemini, .deepseek: return nil
        }
    }

    private static func codexImage(_ name: String, appResource: String) -> NSImage? {
        bundledImage(name) ?? NSImage(contentsOfFile: "/Applications/ChatGPT.app/Contents/Resources/\(appResource)")
    }

    private static func bundledImage(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Quota") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}

private struct QuotaBalanceRow: View {
    let balance: QuotaBalanceInfo
    let theme: ClipFlowTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("可用余额（\(balance.currency)）")
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer(minLength: 0)
                Text(balance.formattedTotal)
                    .font(.system(size: 15, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(theme.foreground)
                    .fixedSize()
            }
            if let detail = balance.detailText {
                Text(detail)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("可用余额 \(balance.currency)")
        .accessibilityValue([balance.formattedTotal, balance.detailText].compactMap { $0 }.joined(separator: "，"))
    }
}

private struct QuotaBucketRow: View {
    let bucket: QuotaBucket
    let samples: [QuotaSample]
    let theme: ClipFlowTheme
    let now: Date

    private var usageColor: Color {
        if bucket.remainingPercent <= 15 { return theme.danger }
        if bucket.remainingPercent <= 35 { return theme.orange }
        return theme.accent
    }

    private var usageTextColor: Color {
        let color = NSColor(usageColor)
        return Color(nsColor: color.blended(
            withFraction: theme.scheme == .light ? 0.42 : 0.16,
            of: NSColor(theme.foreground)
        ) ?? color)
    }

    private var resetText: String {
        bucket.resetCountdownText(now: now)
            ?? (bucket.usedPercent == 0 ? "未消耗 · 满额可用" : "重置时间未提供")
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(bucket.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text(bucket.formattedRemainingPercent)
                        .font(.system(size: 13, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(usageTextColor)
                        .fixedSize()
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.weakHairline)
                        Capsule().fill(usageColor)
                            .frame(width: geometry.size.width * bucket.remainingFraction)
                    }
                }
                .frame(height: 5)
                Text(resetText)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            QuotaSparkline(samples: samples, color: usageColor, baseline: theme.hairline)
                .frame(width: 64, height: 26)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bucket.title)
        .accessibilityValue("\(bucket.formattedRemainingPercent)，\(resetText)")
    }
}

private struct QuotaSparkline: View {
    let samples: [QuotaSample]
    let color: Color
    let baseline: Color

    var body: some View {
        Canvas { context, size in
            let padding: CGFloat = 2
            let bottom = size.height - padding
            let right = size.width - padding
            var axis = Path()
            axis.move(to: CGPoint(x: padding, y: bottom))
            axis.addLine(to: CGPoint(x: right, y: bottom))
            context.stroke(axis, with: .color(baseline), lineWidth: 1)

            guard let first = samples.first, let last = samples.last else { return }
            let duration = last.timestamp.timeIntervalSince(first.timestamp)
            let points = samples.enumerated().map { index, sample in
                let x: Double
                if duration > 0 {
                    x = min(max(sample.timestamp.timeIntervalSince(first.timestamp) / duration, 0), 1)
                } else {
                    x = samples.count == 1 ? 1 : Double(index) / Double(samples.count - 1)
                }
                let remaining = min(max((100 - sample.usedPercent) / 100, 0), 1)
                return CGPoint(x: padding + x * (right - padding), y: bottom - remaining * (bottom - padding))
            }
            guard let start = points.first, let end = points.last else { return }
            var trend = Path()
            trend.move(to: start)
            for point in points.dropFirst() { trend.addLine(to: point) }
            context.stroke(trend, with: .color(color), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            let dot = CGRect(x: end.x - 2, y: end.y - 2, width: 4, height: 4)
            context.fill(Path(ellipseIn: dot), with: .color(color))
        }
        .accessibilityHidden(true)
    }
}

private struct QuotaAccountEditor: View {
    @ObservedObject var model: QuotaMonitorModel
    let theme: ClipFlowTheme
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name, plan, home, binary, apiKey, baseURL
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.25)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.editingAccountID == nil ? "添加账号" : "编辑账号")
                        .font(.system(size: 18, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)

                    ScrollView {
                        fields
                    }

                    if let error = model.editorError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.updatesFrequently)
                    }

                    HStack(spacing: 8) {
                        Spacer()
                        Button("取消", action: model.cancelEditor)
                            .buttonStyle(GlassButtonStyle(kind: .normal))
                            .fixedSize()
                            .keyboardShortcut(.cancelAction)
                        Button("保存") {
                            if let savedID = model.saveAccountDraft() {
                                model.refresh(accountID: savedID)
                            }
                        }
                        .buttonStyle(GlassButtonStyle(kind: .primary))
                        .fixedSize()
                        .disabled(model.isAuthenticatingGemini)
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(width: min(444, geometry.size.width - 36), height: min(468, geometry.size.height - 24))
                .flowCard(theme)
                .background {
                    VisualEffectBackground()
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .shadow(color: .black.opacity(0.22), radius: 28, y: 12)
                .accessibilityAddTraits(.isModal)
            }
        }
        .onAppear { focusedField = .name }
        .onChange(of: model.draftProvider) { _ in model.cancelGeminiWebLogin() }
        .onChange(of: model.draftGeminiAuthMode) { _ in model.cancelGeminiWebLogin() }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.editingAccountID == nil {
                Picker("供应商", selection: $model.draftProvider) {
                    ForEach(QuotaProvider.allCases) { provider in Text(provider.title).tag(provider) }
                }
                .font(.system(size: 12))
            } else {
                LabeledContent("供应商", value: model.draftProvider.title)
                    .font(.system(size: 12))
                    .frame(minHeight: 24)
            }

            textField("显示名称", placeholder: namePlaceholder, text: $model.draftLabel, field: .name)
            textField("套餐标签（选填）", placeholder: planPlaceholder, text: $model.draftPlanOverride, field: .plan)

            if model.draftProvider.usesAPIKey {
                secureField(
                    "API Key",
                    placeholder: model.draftHasSavedAPIKey ? "已保存，留空沿用当前密钥" : "输入 \(model.draftProvider.title) API Key",
                    text: $model.draftAPIKey,
                    field: .apiKey
                )
                Text("API Key 保存在本机 macOS 钥匙串中，不写入明文配置。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.muted)

                textField(
                    "接口地址（选填）",
                    placeholder: model.draftProvider.defaultBaseURL ?? "https://api.deepseek.com",
                    text: $model.draftCustomBaseURL,
                    field: .baseURL
                )
                Text("默认使用官方地址；远程地址须为 HTTPS，本机服务可用 HTTP。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.muted)
            } else if model.draftProvider == .gemini {
                VStack(alignment: .leading, spacing: 4) {
                    Text("登录方式")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.foregroundSecondary)
                    Picker("登录方式", selection: $model.draftGeminiAuthMode) {
                        ForEach(GeminiAuthMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                .padding(.top, 2)

                if model.draftGeminiAuthMode == .webOAuth {
                    geminiWebAuthSection
                } else {
                    HStack(alignment: .bottom, spacing: 8) {
                        textField(
                            "凭证目录（选填）",
                            placeholder: model.draftProvider.defaultDirectoryPlaceholder,
                            text: $model.draftCustomHomePath,
                            field: .home
                        )
                        Button("选择…", action: model.chooseDirectoryForDraft)
                            .buttonStyle(GlassButtonStyle(kind: .normal))
                            .fixedSize()
                            .accessibilityLabel("选择账号配置目录")
                    }
                    Text("默认读取 ~/.gemini/oauth_creds.json，需先在终端通过 gemini 使用 Google 账号登录。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.muted)

                    textField(
                        "CLI 路径（选填，用于自动刷新令牌）",
                        placeholder: "自动查找 \(model.draftProvider.defaultBinaryName)",
                        text: $model.draftCustomBinaryPath,
                        field: .binary
                    )
                }
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    let directory = model.draftProvider.defaultDirectoryPlaceholder
                    textField("配置目录（选填）", placeholder: directory, text: $model.draftCustomHomePath, field: .home)
                    Button("选择…", action: model.chooseDirectoryForDraft)
                        .buttonStyle(GlassButtonStyle(kind: .normal))
                        .fixedSize()
                        .accessibilityLabel("选择账号配置目录")
                }

                textField(
                    "CLI 路径（选填）",
                    placeholder: "自动查找 \(model.draftProvider.defaultBinaryName)",
                    text: $model.draftCustomBinaryPath,
                    field: .binary
                )
            }
        }
        .padding(.vertical, 1)
    }

    private var geminiWebAuthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isAuthenticatingGemini {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).scaleEffect(0.75)
                    Text("正在等待浏览器完成 Google 授权…")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.foregroundSecondary)
                    Spacer(minLength: 0)
                    Button("取消登录", action: model.cancelGeminiWebLogin)
                        .buttonStyle(GlassButtonStyle(kind: .quiet))
                        .fixedSize()
                }
            } else if let pending = model.draftPendingGeminiAuth {
                HStack(spacing: 8) {
                    Label(
                        pending.email.map { "已授权：\($0)" } ?? "已完成 Google 账号授权",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("重新登录", action: model.startGeminiWebLogin)
                        .buttonStyle(GlassButtonStyle(kind: .normal))
                        .fixedSize()
                }
            } else if model.draftHasSavedGeminiOAuth {
                HStack(spacing: 8) {
                    Label("已通过 Google 网页登录授权", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.accent)
                    Spacer(minLength: 0)
                    Button("重新登录", action: model.startGeminiWebLogin)
                        .buttonStyle(GlassButtonStyle(kind: .normal))
                        .fixedSize()
                }
            } else {
                HStack(spacing: 8) {
                    Button(action: model.startGeminiWebLogin) {
                        Label("打开浏览器登录 Google", systemImage: "globe")
                    }
                    .buttonStyle(GlassButtonStyle(kind: .primary))
                    .fixedSize()
                    Spacer(minLength: 0)
                }
            }
            Text("将通过默认浏览器完成 Google OAuth 授权，令牌加密保存在本机 macOS 钥匙串中；需本机已安装 gemini CLI 或配置 OAuth 环境变量。")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flowInset(theme)
    }

    private var namePlaceholder: String {
        switch model.draftProvider {
        case .deepseek: return "例如：DeepSeek 主账号"
        case .gemini: return "例如：个人 Google 账号"
        case .codex, .antigravity: return "例如：工作账号"
        }
    }

    private var planPlaceholder: String {
        model.draftProvider == .deepseek ? "例如：按量计费、个人" : "例如：Ultra、Pro"
    }

    private func secureField(_ title: String, placeholder: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.foregroundSecondary)
                .accessibilityHidden(true)
            SecureField(title, text: text, prompt: Text(placeholder).foregroundColor(theme.muted))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focusedField, equals: field)
                .padding(.horizontal, 9)
                .frame(height: 30)
                .flowInset(theme)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(focusedField == field ? theme.accent : .clear)
                        .allowsHitTesting(false)
                }
        }
    }

    private func textField(_ title: String, placeholder: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.foregroundSecondary)
                .accessibilityHidden(true)
            TextField(title, text: text, prompt: Text(placeholder).foregroundColor(theme.muted))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focusedField, equals: field)
                .padding(.horizontal, 9)
                .frame(height: 30)
                .flowInset(theme)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(focusedField == field ? theme.accent : .clear)
                        .allowsHitTesting(false)
                }
        }
    }
}
