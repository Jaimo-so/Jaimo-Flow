import AppKit
import ClipFlowKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    let fixedMode: AppModel.LibraryMode?
    let embedded: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool
    @State private var hoveredTab: ClipFilter?

    init(
        model: AppModel,
        fixedMode: AppModel.LibraryMode? = nil,
        embedded: Bool = false
    ) {
        self.model = model
        self.fixedMode = fixedMode
        self.embedded = embedded
    }

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        framedContent(layeredContent(theme), theme: theme)
            .foregroundStyle(theme.foreground)
            .animation(reduceMotion ? FlowMotion.reduced : FlowMotion.content, value: model.settingsOpen)
            .animation(reduceMotion ? FlowMotion.reduced : FlowMotion.content, value: model.promptEditorOpen)
            .animation(reduceMotion ? FlowMotion.reduced : FlowMotion.content, value: model.promptRunnerOpen)
            .animation(reduceMotion ? FlowMotion.reduced : FlowMotion.content, value: model.promptDeleteConfirmationOpen)
            .animation(reduceMotion ? FlowMotion.reduced : FlowMotion.content, value: model.toastMessage)
            .onAppear {
                if let fixedMode { model.setMode(fixedMode) }
                if model.libraryMode == .history { model.loadCredentials() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .clipFlowFocusSearch)) { _ in
                searchFocused = true
                model.focusArea = .search
            }
            .onChange(of: searchFocused) { focused in
                if focused { model.focusArea = .search }
                else if model.focusArea == .search { model.focusArea = .other }
            }
    }

    private func layeredContent(_ theme: ClipFlowTheme) -> some View {
        let modalOpen = model.settingsOpen
            || model.promptEditorOpen
            || model.promptRunnerOpen
            || model.promptDeleteConfirmationOpen
            || model.credentialEditorOpen
            || model.credentialDeleteConfirmationOpen
        return ZStack {
            if !embedded {
                if colorScheme == .dark {
                    VisualEffectBackground().ignoresSafeArea()
                    theme.glass.ignoresSafeArea()
                } else {
                    theme.lightWindowBackground.ignoresSafeArea()
                }
            }

            VStack(spacing: 0) {
                searchBar(theme)
                Divider().overlay(theme.hairline)
                categoryBar(theme)
                Divider().overlay(theme.hairline)
                bodyArea(theme)
                Divider().overlay(theme.hairline)
                footer(theme)
            }
            .disabled(modalOpen)

            if model.settingsOpen && !embedded {
                SettingsView(model: model)
                    .transition(FlowMotion.reveal(reduceMotion: reduceMotion))
                    .zIndex(20)
            }

            if model.promptEditorOpen {
                PromptEditorView(model: model)
                    .transition(FlowMotion.reveal(reduceMotion: reduceMotion))
                    .zIndex(22)
            }

            if model.promptRunnerOpen {
                PromptRunnerView(model: model)
                    .transition(FlowMotion.reveal(reduceMotion: reduceMotion))
                    .zIndex(24)
            }

            if model.promptDeleteConfirmationOpen {
                PromptDeleteConfirmationView(model: model)
                    .transition(FlowMotion.reveal(reduceMotion: reduceMotion))
                    .zIndex(26)
            }

            if model.credentialEditorOpen {
                CredentialEditorView(model: model).zIndex(28)
            }

            if model.credentialDeleteConfirmationOpen {
                CredentialDeleteConfirmationView(model: model).zIndex(30)
            }

            if let message = model.toastMessage, !embedded {
                toast(message, theme: theme)
                    .transition(FlowMotion.reveal(reduceMotion: reduceMotion, distance: 10))
                    .zIndex(40)
            }
        }
    }

    @ViewBuilder
    private func framedContent<Content: View>(_ content: Content, theme: ClipFlowTheme) -> some View {
        if embedded {
            content
        } else {
            content
                .clipShape(RoundedRectangle(cornerRadius: WindowMetrics.cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: WindowMetrics.cornerRadius, style: .continuous)
                        .stroke((colorScheme == .dark ? Color.white : Color.black).opacity(0.18), lineWidth: 0.5)
                )
                .overlay(alignment: .top) {
                    WindowDragRegion()
                        .frame(height: 8)
                        .accessibilityHidden(true)
                }
        }
    }

    private func searchBar(_ theme: ClipFlowTheme) -> some View {
        HStack(spacing: 11) {
            if fixedMode == nil {
                HStack(spacing: 2) {
                    ForEach(AppModel.LibraryMode.allCases) { mode in
                        Button {
                            model.setMode(mode)
                        } label: {
                            Text(mode.title)
                                .font(.system(size: 11.5, weight: model.libraryMode == mode ? .semibold : .regular))
                                .foregroundStyle(model.libraryMode == mode ? theme.foreground : theme.muted)
                                .padding(.horizontal, 9)
                                .frame(height: 26)
                                .background(model.libraryMode == mode ? theme.chipHigh : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(model.libraryMode == mode ? [.isSelected] : [])
                    }
                }
                .padding(2)
                .background(theme.chip)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(theme.muted)
                .accessibilityHidden(true)
            TextField(
                model.isCredentialGroup ? "搜索 API Key / 密码名称…" : model.libraryMode == .history ? "搜索剪贴板历史…" : "搜索提示词…",
                text: model.libraryMode == .history ? $model.query : $model.promptQuery
            )
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(theme.foreground)
                .focused($searchFocused)
                .accessibilityLabel(model.isCredentialGroup ? "搜索 API Key / 密码名称" : model.libraryMode == .history ? "搜索剪贴板历史" : "搜索提示词")
                .accessibilityHint(model.isCredentialGroup ? "按名称搜索已保存的 API Key 和密码" : model.libraryMode == .history ? "输入关键词筛选剪贴板记录" : "输入关键词筛选提示词")
            KeyCap(text: "⌘F", muted: true)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(searchFocused ? (colorScheme == .dark ? Color.white : Color.black).opacity(0.04) : .clear)
    }

    private func categoryBar(_ theme: ClipFlowTheme) -> some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    if model.libraryMode == .history {
                        ForEach(ClipFilter.allCases) { filter in
                            Button {
                                model.setFilter(filter)
                            } label: {
                                HStack(spacing: 6) {
                                    Text(filter.title).font(.system(size: 12.5))
                                    Text("\(model.count(for: filter))")
                                        .font(.system(size: 11))
                                        .foregroundStyle(model.filter == filter ? theme.foregroundSecondary : theme.muted)
                                        .monospacedDigit()
                                }
                                .foregroundStyle(model.filter == filter || hoveredTab == filter ? theme.foreground : theme.muted)
                                .padding(.horizontal, 11)
                                .frame(minHeight: 26)
                                .background(model.filter == filter ? theme.chipHigh : hoveredTab == filter ? theme.chip : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                            .focusable(false)
                            .onHover { hovering in hoveredTab = hovering ? filter : nil }
                            .accessibilityLabel("\(filter.title)，\(model.count(for: filter)) 条")
                            .accessibilityAddTraits(model.filter == filter ? [.isSelected] : [])
                        }
                    } else {
                        ForEach(model.promptScopes) { scope in
                            Button {
                                model.setPromptScope(scope)
                            } label: {
                                HStack(spacing: 6) {
                                    Text(scope.title).font(.system(size: 12.5))
                                    Text("\(model.count(for: scope))")
                                        .font(.system(size: 11))
                                        .foregroundStyle(model.promptScope == scope ? theme.foregroundSecondary : theme.muted)
                                        .monospacedDigit()
                                }
                                .foregroundStyle(model.promptScope == scope ? theme.foreground : theme.muted)
                                .padding(.horizontal, 11)
                                .frame(minHeight: 26)
                                .background(model.promptScope == scope ? theme.chipHigh : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                            .focusable(false)
                            .accessibilityLabel("\(scope.title)，\(model.count(for: scope)) 条提示词")
                            .accessibilityAddTraits(model.promptScope == scope ? [.isSelected] : [])
                        }
                    }
                }
                .padding(.leading, 13)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
            }

            if model.libraryMode == .prompts || model.isCredentialGroup {
                Divider()
                    .overlay(theme.hairline)
                    .frame(height: 25)
                Button {
                    if model.isCredentialGroup { model.beginCreateCredential() }
                    else { model.beginCreatePrompt() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text("新建")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(theme.foreground)
                    .padding(.horizontal, 10)
                    .frame(height: 27)
                    .background(theme.accent.opacity(0.20))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(theme.accent.opacity(0.42), lineWidth: 0.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .help(model.isCredentialGroup ? "新建 API Key / 密码（⌘N）" : "新建提示词（⌘N）")
                .accessibilityLabel(model.isCredentialGroup ? "新建 API Key / 密码" : "新建提示词")
            }
        }
        .frame(height: 43)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.libraryMode == .history ? "内容分类" : "提示词分组")
    }

    private func bodyArea(_ theme: ClipFlowTheme) -> some View {
        GeometryReader { proxy in
            if model.libraryMode == .prompts {
                PromptLibraryBody(model: model, compact: proxy.size.width <= 720)
            } else if model.isCredentialGroup {
                CredentialLibraryView(model: model)
            } else if proxy.size.width <= 720 {
                VStack(spacing: 0) {
                    HistoryListView(model: model)
                    Divider().overlay(theme.hairline)
                    PreviewView(model: model, compact: true)
                        .frame(height: 49)
                }
            } else {
                HStack(spacing: 0) {
                    HistoryListView(model: model)
                    Divider().overlay(theme.hairline)
                    PreviewView(model: model, compact: false)
                        .frame(width: 296)
                }
            }
        }
        .frame(minHeight: 216, idealHeight: 412)
    }

    private func footer(_ theme: ClipFlowTheme) -> some View {
        GeometryReader { proxy in
            HStack(spacing: 12) {
                HStack(spacing: 13) {
                    footerHint("↑↓", "导航")
                    footerHint("↵", model.libraryMode == .history ? "复制" : "使用")
                    if proxy.size.width > 520 {
                        footerHint(model.isCredentialGroup ? "⌘E" : "⌘S", model.isCredentialGroup ? "编辑" : "收藏")
                    }
                    if proxy.size.width > 720 {
                        footerHint(model.libraryMode == .history ? "⌘⌫" : "⌘N", model.libraryMode == .history ? "删除" : "新建")
                        footerHint("⌘,", "设置")
                    }
                }
                Spacer(minLength: 4)
                Text(footerCount)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(maxHeight: .infinity)
            .background((colorScheme == .dark ? Color.white : Color.black).opacity(0.035))
        }
        .frame(height: 41)
    }

    private func footerHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            KeyCap(text: key)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(ClipFlowTheme(scheme: colorScheme).muted)
        }
        .fixedSize()
        .accessibilityHidden(true)
    }

    private var footerCount: String {
        if model.isCredentialGroup {
            return model.credentialError == nil ? "\(model.filteredCredentials.count) 条 · 本机钥匙串" : "钥匙串读取失败"
        }
        switch model.phase {
        case .loading: return "加载中…"
        case .failed: return "读取失败"
        case .ready:
            return model.libraryMode == .history
                ? "\(model.filteredItems.count) 条 · 本地存储"
                : "\(model.filteredPrompts.count) 条提示词 · 本地存储"
        }
    }

    private func toast(_ message: String, theme: ClipFlowTheme) -> some View {
        VStack {
            Spacer()
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.foreground)
                .padding(.horizontal, 15)
                .padding(.vertical, 8)
                .background(theme.glass.opacity(0.96))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.hairline, lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
                .padding(.bottom, 34)
                .accessibilityLabel(message)
                .accessibilityAddTraits(.updatesFrequently)
        }
        .allowsHitTesting(false)
    }
}

private struct HistoryListView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            switch model.phase {
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
                    action: model.load
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
                                        model.focusArea = .other
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
            .background(selected ? theme.selection : hovering ? theme.chip : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
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
    @ObservedObject var model: AppModel
    let compact: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        VStack(spacing: 0) {
            if compact {
                actions(theme)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
            } else {
                switch model.phase {
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
        .background(theme.glassSecondary)
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
            Button(action: model.copySelected) {
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
            .buttonStyle(GlassButtonStyle(kind: .normal, horizontalPadding: 0))
            .frame(width: 26, height: 26)
            .disabled(model.selectedItem == nil)
            .accessibilityLabel(model.selectedItem?.isFavorite == true ? "取消收藏" : "收藏")
            .help(model.selectedItem?.isFavorite == true ? "取消收藏（⌘S）" : "收藏（⌘S）")

            Button {
                model.beginCreatePrompt(prefillFromSelection: true)
            } label: {
                Image(systemName: "text.badge.plus")
                    .accessibilityHidden(true)
            }
            .buttonStyle(GlassButtonStyle(kind: .normal, horizontalPadding: 0))
            .frame(width: 26, height: 26)
            .disabled(model.selectedItem == nil || model.selectedItem?.kind == .image)
            .accessibilityLabel("保存为提示词")
            .help("保存为提示词")

            Button(action: model.deleteSelected) {
                Image(systemName: "trash")
                    .accessibilityHidden(true)
            }
            .buttonStyle(GlassButtonStyle(kind: .danger, horizontalPadding: 0))
            .frame(width: 26, height: 26)
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
