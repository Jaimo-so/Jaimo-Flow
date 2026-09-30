import AppKit
import SwiftUI

struct VibeHubLibraryView: View {
    @ObservedObject var library: VibeHubLibraryModel
    @ObservedObject var appModel: AppModel
    @ObservedObject var agent: VibeHubAgentModel
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var searchFocused: Bool
    @FocusState private var titleFocused: Bool
    @State private var deleteArmed = false

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        VStack(spacing: 0) {
            header(theme)
            searchBar(theme)
            categories(theme)
            Divider().overlay(theme.hairline)
            if library.loadFailed {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 28))
                    Text("无法读取话术库").font(.system(size: 15, weight: .semibold))
                    Text("读取失败，原有话术文件已保留。").foregroundStyle(theme.muted)
                    Button("重新读取", action: library.reload)
                        .buttonStyle(GlassButtonStyle(kind: .primary)).fixedSize()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        phraseList(theme)
                            .frame(width: proxy.size.width < 720 ? 180 : 240)
                        Divider().overlay(theme.hairline)
                        if let item = library.selectedItem {
                            editor(item, theme: theme)
                        } else {
                            emptyEditor(theme)
                        }
                    }
                }
            }
            Divider().overlay(theme.hairline)
            HStack(spacing: 8) {
                Text("\(library.items.count) 条话术")
                Spacer()
                Text(library.saveStatus.text)
                    .foregroundStyle(library.saveStatus == .failed ? theme.danger : theme.muted)
                if library.saveStatus == .failed && !library.loadFailed {
                    Button("重试保存", action: library.flush).buttonStyle(.plain)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(theme.muted)
            .padding(.horizontal, 18)
            .frame(height: 32)
        }
        .disabled(agent.panel != .closed)
        .accessibilityHidden(agent.panel != .closed)
        .overlay {
            if agent.panel == .composer {
                VibeHubAgentComposer(agent: agent)
            } else if agent.panel == .preview {
                VibeHubAgentPreview(agent: agent)
            } else if agent.panel == .settings {
                VibeHubAgentSettingsView(agent: agent)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .jaimoFocusVibeHubSearch)) { _ in
            searchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .jaimoFocusVibeHubTitle)) { _ in
            titleFocused = true
        }
        .onChange(of: library.selectedID) { _ in deleteArmed = false }
        .onChange(of: agent.savedItemID) { id in
            if id != nil { appModel.showToast("已保存确认后的话术") }
        }
        .onDisappear { library.flush() }
    }

    private func header(_ theme: ClipFlowTheme) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Vibehub").font(.system(size: 19, weight: .semibold))
                Text("把新学的话术，留给下一次 Vibe Coding。")
                    .font(.system(size: 11)).foregroundStyle(theme.muted)
            }
            Spacer(minLength: 0)
            Button(action: create) { Label("新建话术", systemImage: "plus") }
                .buttonStyle(GlassButtonStyle(kind: .normal)).fixedSize()
                .disabled(library.loadFailed)
                .help("新建话术（⌘N）")
            Button(action: agent.openComposer) { Label("Agent 整理", systemImage: "sparkles") }
                .buttonStyle(GlassButtonStyle(kind: .primary)).fixedSize()
                .disabled(library.loadFailed)
            Button(action: agent.openSettings) { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(FlowIconButtonStyle()).disabled(agent.isRunning)
                .accessibilityLabel("Agent 设置").help("Agent 设置")
        }
        .padding(.horizontal, 18)
        .frame(height: 72)
    }

    private func searchBar(_ theme: ClipFlowTheme) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(theme.muted)
            TextField("搜索话术、标签、场景或含义…", text: $library.query)
                .textFieldStyle(.plain).focused($searchFocused)
                .accessibilityLabel("搜索 Vibehub 话术")
            if !library.query.isEmpty {
                Button { library.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(FlowIconButtonStyle()).accessibilityLabel("清空话术搜索")
            }
            KeyCap(text: "⌘F", muted: true)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(searchFocused ? theme.foreground.opacity(0.28) : .clear))
        .padding(.horizontal, 18)
    }

    private func categories(_ theme: ClipFlowTheme) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                scopeButton("全部", scope: .all, theme: theme)
                scopeButton("收藏", scope: .favorites, theme: theme)
                ForEach(VibeHubCategory.allCases) { category in
                    scopeButton(category.rawValue, scope: .category(category), theme: theme)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .frame(height: 48)
    }

    private func scopeButton(_ title: String, scope: VibeHubLibraryModel.Scope, theme: ClipFlowTheme) -> some View {
        Button { library.scope = scope } label: {
            HStack(spacing: 5) {
                Text(title)
                Text("\(library.count(in: scope))").monospacedDigit().foregroundStyle(theme.muted)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 9).frame(height: 28)
            .foregroundStyle(library.scope == scope ? theme.foreground : theme.muted)
            .background(library.scope == scope ? theme.chipHigh : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)，\(library.count(in: scope)) 条话术")
        .accessibilityAddTraits(library.scope == scope ? [.isSelected] : [])
    }

    private func phraseList(_ theme: ClipFlowTheme) -> some View {
        ScrollView {
            LazyVStack(spacing: 5) {
                if library.filteredItems.isEmpty {
                    VStack(spacing: 8) {
                        Text(library.query.isEmpty ? "这个分类还没有话术" : "没有匹配的话术")
                            .font(.system(size: 12, weight: .medium))
                        Text(library.query.isEmpty ? "新建一条，记录刚学到的表达。" : "试试其他关键词或分类。")
                            .font(.system(size: 11)).foregroundStyle(theme.muted)
                    }
                    .padding(.vertical, 24).padding(.horizontal, 8)
                }
                ForEach(library.filteredItems) { item in
                    Button { library.selectedID = item.id } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .top, spacing: 5) {
                                Text(item.title.isEmpty ? "无标题话术" : item.title)
                                    .font(.system(size: 12, weight: .semibold)).lineLimit(2)
                                Spacer(minLength: 0)
                                if item.isFavorite {
                                    Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(theme.star)
                                }
                            }
                            Text(item.phrase.isEmpty ? "写下可直接发给 Agent 的话术…" : item.phrase)
                                .font(.system(size: 11)).foregroundStyle(theme.foregroundSecondary).lineLimit(3)
                            Text(item.category.rawValue).font(.system(size: 11)).foregroundStyle(theme.muted)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(library.selectedID == item.id ? theme.selection : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(library.selectedID == item.id ? [.isSelected] : [])
                }
            }.padding(9)
        }
    }

    private func editor(_ item: VibeHubItem, theme: ClipFlowTheme) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TextField("话术标题", text: binding(\.title, default: ""))
                        .textFieldStyle(.plain).font(.system(size: 18, weight: .semibold))
                        .focused($titleFocused).accessibilityLabel("话术标题")
                    HStack(spacing: 8) {
                        Picker("分类", selection: binding(\.category, default: .uncategorized)) {
                            ForEach(VibeHubCategory.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .frame(maxWidth: 235)
                        Button("识别分类") {
                            library.classifySelected()
                            appModel.showToast("已按关键词归入「\(library.selectedItem?.category.rawValue ?? "未分类")」")
                        }
                        .buttonStyle(GlassButtonStyle(kind: .quiet)).fixedSize()
                        .disabled(item.phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("根据标题和话术中的关键词分类，可手动调整")
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        fieldLabel("标签", detail: "用逗号或顿号分隔", theme: theme)
                        TextField("例如：哈希路由、页面切换", text: binding(\.tags, default: ""))
                            .textFieldStyle(.plain).font(.system(size: 12))
                            .padding(10).background(theme.chip).clipShape(RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("话术标签")
                    }
                    textSection("话术原文", detail: "复制后可直接发给 Agent", keyPath: \.phrase, height: 155, theme: theme)
                    textSection("适用场景", detail: "什么时候用这句话", keyPath: \.scenario, height: 76, theme: theme)
                    textSection("术语与含义", detail: "记录定义、意义和理解", keyPath: \.meaning, height: 110, theme: theme)
                }
                .padding(20)
            }
            Divider().overlay(theme.hairline)
            ViewThatFits(in: .horizontal) {
                editorActions(item, showDate: true, theme: theme)
                editorActions(item, showDate: false, theme: theme)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func editorActions(_ item: VibeHubItem, showDate: Bool, theme: ClipFlowTheme) -> some View {
        HStack(spacing: 6) {
            if showDate {
                Text(item.updatedAt.formatted(.dateTime.month().day().hour().minute()))
                    .font(.system(size: 11)).foregroundStyle(theme.muted).fixedSize()
            }
            Spacer(minLength: 0)
            Button {
                library.updateSelected(\.isFavorite, to: !item.isFavorite)
            } label: {
                Image(systemName: item.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(item.isFavorite ? theme.star : theme.muted)
            }
            .buttonStyle(FlowIconButtonStyle())
            .accessibilityLabel(item.isFavorite ? "取消收藏话术" : "收藏话术")
            .help(item.isFavorite ? "取消收藏" : "收藏话术")
            Button(deleteArmed ? "确认删除" : "删除") {
                if deleteArmed { library.deleteSelected(); deleteArmed = false }
                else { deleteArmed = true }
            }
            .buttonStyle(GlassButtonStyle(kind: deleteArmed ? .danger : .quiet)).fixedSize()
            if deleteArmed {
                Button("取消") { deleteArmed = false }
                    .buttonStyle(GlassButtonStyle(kind: .quiet)).fixedSize()
            }
            Button {
                if let monitor = appModel.clipboardMonitor {
                    switch monitor.write(text: item.phrase) {
                    case .failure: appModel.showToast("复制失败，请重试")
                    case .text, .image: appModel.showToast("已复制完整话术")
                    }
                    return
                }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                if pasteboard.setString(item.phrase, forType: .string) { appModel.showToast("已复制完整话术") }
                else { appModel.showToast("复制失败，请重试") }
            } label: { Label("复制话术", systemImage: "doc.on.doc") }
            .buttonStyle(GlassButtonStyle(kind: .primary)).fixedSize()
            .disabled(item.phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func textSection(_ title: String, detail: String, keyPath: WritableKeyPath<VibeHubItem, String>, height: CGFloat, theme: ClipFlowTheme) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            fieldLabel(title, detail: detail, theme: theme)
            TextEditor(text: binding(keyPath, default: ""))
                .font(.system(size: 13)).lineSpacing(5)
                .scrollContentBackground(.hidden)
                .padding(8).frame(height: height)
                .background(theme.chip).clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(title)
        }
    }

    private func fieldLabel(_ title: String, detail: String, theme: ClipFlowTheme) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12, weight: .medium))
            Text(detail).font(.system(size: 11)).foregroundStyle(theme.muted)
        }
    }

    private func emptyEditor(_ theme: ClipFlowTheme) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "text.bubble").font(.system(size: 30)).foregroundStyle(theme.muted)
            Text("记录一句，下次直接用").font(.system(size: 15, weight: .medium))
            Button("新建话术", action: create)
                .buttonStyle(GlassButtonStyle(kind: .primary)).fixedSize()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<VibeHubItem, Value>, default fallback: Value) -> Binding<Value> where Value: Equatable {
        Binding(get: { library.selectedItem?[keyPath: keyPath] ?? fallback },
                set: { library.updateSelected(keyPath, to: $0) })
    }

    private func create() {
        if library.createPhrase() != nil { titleFocused = true }
    }
}
