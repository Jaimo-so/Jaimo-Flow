import AppKit
import ClipFlowKit
import SwiftUI

struct ClipboardPage: View {
    @ObservedObject private var model: ClipboardLibraryModel
    @ObservedObject private var credentials: CredentialLibraryModel
    let phase: ClipFlowPhase
    private let app: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredTab: ClipFilter?

    init(app: AppModel, phase: ClipFlowPhase) {
        self.app = app
        self.phase = phase
        model = app.clipboard
        credentials = app.credentials
    }

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)

        VStack(spacing: 0) {
            LibrarySearchBar(
                query: $model.query,
                label: model.isCredentialGroup ? "搜索 API Key / 密码名称" : "搜索剪贴板历史",
                hint: model.isCredentialGroup ? "按名称搜索已保存的 API Key 和密码" : "输入关键词筛选剪贴板记录",
                onFocusChange: app.setSearchFocused
            )

            LibraryCategoryBar(label: "内容分类") {
                ForEach(ClipFilter.allCases) { filter in
                    Button {
                        app.setClipboardFilter(filter)
                    } label: {
                        HStack(spacing: 6) {
                            Text(filter.title).font(.system(size: 12.5))
                            Text("\(count(for: filter))")
                                .font(.system(size: 11))
                                .foregroundStyle(model.filter == filter ? theme.foregroundSecondary : theme.muted)
                                .monospacedDigit()
                        }
                        .foregroundStyle(model.filter == filter || hoveredTab == filter ? theme.foreground : theme.muted)
                        .padding(.horizontal, 11)
                        .frame(minHeight: 26)
                        .background(hoveredTab == filter ? theme.chip : .clear, in: Capsule())
                        .flowFilter(theme, selected: model.filter == filter)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .onHover { hovering in hoveredTab = hovering ? filter : nil }
                    .accessibilityLabel("\(filter.title)，\(count(for: filter)) 条")
                    .accessibilityAddTraits(model.filter == filter ? [.isSelected] : [])
                }
            } action: {
                if model.isCredentialGroup {
                    LibraryCreateButton(label: "新建 API Key / 密码", action: credentials.beginCreateCredential)
                }
            }

            LibraryBodyLayout { compact in
                if model.isCredentialGroup {
                    CredentialLibraryView(model: credentials, onSelectRow: leaveSearch)
                        .flowCard(theme)
                } else if compact {
                    VStack(spacing: 6) {
                        HistoryListView(model: model, phase: phase, onReload: app.load, onSelectRow: leaveSearch)
                            .flowCard(theme)
                        PreviewView(model: model, phase: phase, compact: true, onSaveAsPrompt: app.beginPromptFromClipboard)
                            .frame(height: 49)
                    }
                } else {
                    HStack(spacing: 8) {
                        HistoryListView(model: model, phase: phase, onReload: app.load, onSelectRow: leaveSearch)
                            .flowCard(theme)
                        PreviewView(model: model, phase: phase, compact: false, onSaveAsPrompt: app.beginPromptFromClipboard)
                            .frame(width: 296)
                    }
                }
            }

            LibraryFooter(
                returnLabel: "复制",
                secondaryHint: model.isCredentialGroup ? ("⌘E", "编辑") : ("⌘S", "收藏"),
                wideHint: ("⌘⌫", "删除"),
                count: footerCount
            )
        }
        .onAppear { credentials.loadCredentials() }
    }

    private func leaveSearch() {
        app.focusArea = .other
    }

    private func count(for filter: ClipFilter) -> Int {
        filter == .apiKey ? credentials.credentialEntries.count : model.count(for: filter)
    }

    private var footerCount: String {
        if model.isCredentialGroup {
            return credentials.credentialError == nil ? "\(credentials.filteredCredentials.count) 条 · 本机钥匙串" : "钥匙串读取失败"
        }
        switch phase {
        case .loading: return "加载中…"
        case .failed: return "读取失败"
        case .ready: return "\(model.filteredItems.count) 条 · 本地存储"
        }
    }
}

private struct HistoryListView: View {
    @ObservedObject var model: ClipboardLibraryModel
    let phase: ClipFlowPhase
    let onReload: () -> Void
    let onSelectRow: () -> Void

    var body: some View {
        Group {
            switch phase {
            case .loading:
                VStack(spacing: 2) {
                    ForEach(0..<5, id: \.self) { index in SkeletonRow(index: index) }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                .accessibilityLabel("正在读取本地历史")
            case .failed:
                StateView(
                    icon: "exclamationmark.triangle",
                    title: "无法读取剪贴板历史",
                    detail: "本地数据库可能被占用或损坏。重试仍失败时，可在偏好设置中清空历史重建。",
                    isError: true,
                    actionTitle: "重试",
                    action: onReload
                )
            case .ready:
                if model.filteredItems.isEmpty {
                    emptyState
                } else {
                    ScrollViewReader { reader in
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 2) {
                                ForEach(model.filteredItems) { item in
                                    ClipRow(item: item, selected: model.selectedID == item.id) {
                                        model.selectedID = item.id
                                        onSelectRow()
                                    }
                                    .id(item.id)
                                }
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 6)
                        }
                        .onChange(of: model.selectedID) { id in
                            guard let id else { return }
                            reader.scrollTo(id)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .focusable(false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("剪贴板历史记录")
    }

    private var emptyState: some View {
        let query = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String
        let detail: String
        if !query.isEmpty {
            title = "没有匹配「\(query)」的记录"
            detail = "试试更短的关键词，或按 ESC 清空搜索后切换其他分类。"
        } else if model.filter == .favorite {
            title = "还没有收藏的记录"
            detail = "选中一条记录后按 ⌘S 收藏，收藏项不会被数量上限淘汰。"
        } else {
            title = "\(model.filter.title)分类下暂无记录"
            detail = "复制任意内容后会自动出现在这里。按 ⌥Space 可随时唤起窗口。"
        }
        return StateView(icon: "doc.on.clipboard", title: title, detail: detail)
    }
}

private struct ClipRow: View {
    let item: ClipItem
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        Button(action: action) {
            HStack(spacing: 11) {
                itemGlyph(theme)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(item.kind == .code
                              ? .system(size: 12.5, design: .monospaced)
                              : .system(size: 13.5))
                        .foregroundStyle(theme.foreground)
                        .lineLimit(1)
                    HStack(spacing: 7) {
                        Text(item.sourceAppName)
                        Circle().frame(width: 2.5, height: 2.5).opacity(0.7)
                        Text(item.relativeTimeText).monospacedDigit()
                        if item.isFavorite {
                            Circle().frame(width: 2.5, height: 2.5).opacity(0.7)
                            Image(systemName: "star.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.star)
                                .accessibilityLabel("已收藏")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(selected ? theme.selection : hovering ? theme.chipHigh : theme.inset,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .leading) {
                if selected {
                    Capsule()
                        .fill(theme.accent)
                        .frame(width: 2.5)
                        .padding(.vertical, 9)
                        .offset(x: -3)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(item.title)，来源 \(item.sourceAppName)，\(item.relativeTimeText)\(item.isFavorite ? "，已收藏" : "")")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    @ViewBuilder
    private func itemGlyph(_ theme: ClipFlowTheme) -> some View {
        if item.kind == .image, let path = item.imagePath {
            CachedDiskImage(url: path, maxPixelSize: 96, contentMode: .fill)
                .id(path)
                .frame(width: 48, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.hairline, lineWidth: 0.5))
                .accessibilityLabel(item.imageAlt ?? item.title)
        } else {
            Image(systemName: glyphName)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(item.kind == .link ? theme.foreground : theme.foregroundSecondary)
                .frame(width: 48, height: 30)
                .background(theme.chip)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.hairline, lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
        }
    }

    private var glyphName: String {
        switch item.kind {
        case .text: return "text.alignleft"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .link: return "link"
        case .image: return "photo"
        }
    }
}

private struct PreviewView: View {
    @ObservedObject var model: ClipboardLibraryModel
    let phase: ClipFlowPhase
    let compact: Bool
    let onSaveAsPrompt: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        VStack(spacing: 0) {
            if compact {
                actions(theme)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
            } else {
                switch phase {
                case .loading:
                    previewEmpty("正在读取本地历史…", theme: theme)
                case .failed:
                    previewEmpty("读取失败，暂无预览", theme: theme)
                case .ready:
                    if let item = model.selectedItem {
                        previewContent(item, theme: theme)
                    } else {
                        previewEmpty("选中一条记录后\n这里显示完整内容", theme: theme)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .flowCard(theme)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("内容预览")
    }

    private func previewContent(_ item: ClipItem, theme: ClipFlowTheme) -> some View {
        VStack(spacing: 0) {
            Group {
                if item.kind == .image, let path = item.imagePath {
                    CachedDiskImage(url: path, maxPixelSize: 640, contentMode: .fit)
                        .id(path)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.hairline, lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.5), radius: 12, y: 8)
                        .accessibilityLabel(item.imageAlt ?? item.title)
                } else {
                    ProgressiveTextView(
                        text: item.fullText ?? item.title,
                        foreground: theme.foregroundSecondary
                    )
                    .id(item.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)

            Divider().overlay(theme.hairline)
            VStack(spacing: 7) {
                ForEach(item.meta, id: \.self) { entry in infoLine(entry.key, entry.value, theme: theme) }
                infoLine("来源", item.sourceAppName, theme: theme)
                infoLine("复制时间", item.detailedTimeText, theme: theme)
            }
            .padding(.horizontal, 14)
            .padding(.top, 11)
            .padding(.bottom, 13)
            actions(theme)
                .padding(.horizontal, 14)
                .padding(.bottom, 13)
        }
    }

    private func infoLine(_ key: String, _ value: String, theme: ClipFlowTheme) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key).foregroundStyle(theme.muted)
            Spacer(minLength: 0)
            Text(value)
                .foregroundStyle(theme.foregroundSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .multilineTextAlignment(.trailing)
        }
        .font(.system(size: 11.5))
    }

    private func actions(_ theme: ClipFlowTheme) -> some View {
        HStack(spacing: 6) {
            Button(action: model.copySelection) {
                HStack(spacing: 5) { Text("复制到剪贴板"); KeyCap(text: "↵") }
            }
            .buttonStyle(GlassButtonStyle(kind: .primary))
            .frame(maxWidth: .infinity)
            .keyboardShortcut(.return, modifiers: [])
            .disabled(model.selectedItem == nil)

            Button(action: model.toggleFavorite) {
                Image(systemName: model.selectedItem?.isFavorite == true ? "star.fill" : "star")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(
                        model.selectedItem?.isFavorite == true ? theme.star : theme.foregroundSecondary
                    )
                    .accessibilityHidden(true)
            }
            .buttonStyle(FlowIconButtonStyle())
            .disabled(model.selectedItem == nil)
            .accessibilityLabel(model.selectedItem?.isFavorite == true ? "取消收藏" : "收藏")
            .help(model.selectedItem?.isFavorite == true ? "取消收藏（⌘S）" : "收藏（⌘S）")

            Button(action: onSaveAsPrompt) {
                Image(systemName: "text.badge.plus")
                    .accessibilityHidden(true)
            }
            .buttonStyle(FlowIconButtonStyle())
            .disabled(model.selectedItem == nil || model.selectedItem?.kind == .image)
            .accessibilityLabel("保存为提示词")
            .help("保存为提示词")

            Button(action: model.deleteSelection) {
                Image(systemName: "trash")
                    .accessibilityHidden(true)
            }
            .buttonStyle(FlowIconButtonStyle(danger: true))
            .disabled(model.selectedItem == nil)
            .accessibilityLabel("删除这条记录")
            .help("删除（⌘⌫）")

        }
        .frame(maxWidth: .infinity)
    }

    private func previewEmpty(_ text: String, theme: ClipFlowTheme) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(theme.muted)
            .multilineTextAlignment(.center)
            .lineSpacing(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
    }
}

private struct StateView: View {
    let icon: String
    let title: String
    let detail: String
    var isError = false
    var actionTitle: String?
    var action: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(isError ? theme.danger.opacity(0.95) : theme.muted)
                .frame(width: 42, height: 42)
                .background(isError ? theme.danger.opacity(0.14) : theme.chip)
                .overlay(
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(isError ? theme.danger.opacity(0.30) : theme.hairline, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 11))
            Text(title)
                .font(.system(size: 13.5))
                .foregroundStyle(theme.foregroundSecondary)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(theme.muted)
                .lineSpacing(7)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 330)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(GlassButtonStyle(kind: .normal))
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(26)
        .accessibilityElement(children: .combine)
    }
}

private struct SkeletonRow: View {
    let index: Int

    var body: some View {
        HStack(spacing: 11) {
            SkeletonBlock(cornerRadius: 5)
                .frame(width: 48, height: 30)
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBlock(cornerRadius: 4)
                    .frame(width: index.isMultiple(of: 2) ? 190 : 230, height: 9)
                SkeletonBlock(cornerRadius: 4)
                    .frame(width: 116, height: 8)
            }
            Spacer()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .padding(.horizontal, 7)
    }
}

private struct SkeletonBlock: View {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(theme.skeleton)
                .overlay {
                    if !reduceMotion {
                        LinearGradient(
                            colors: [.clear, theme.skeletonHigh, .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 1.4)
                        .offset(x: phase * proxy.size.width * 1.5)
                    } else {
                        theme.skeletonHigh
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}
