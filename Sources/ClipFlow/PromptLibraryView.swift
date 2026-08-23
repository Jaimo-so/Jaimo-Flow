import ClipFlowKit
import SwiftUI
import UniformTypeIdentifiers

struct PromptLibraryBody: View {
    @ObservedObject var model: AppModel
    let compact: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        if compact {
            VStack(spacing: 0) {
                PromptListView(model: model)
                Divider().overlay(theme.hairline)
                PromptPreviewView(model: model, compact: true)
                    .frame(height: 49)
            }
        } else {
            HStack(spacing: 0) {
                PromptListView(model: model)
                Divider().overlay(theme.hairline)
                PromptPreviewView(model: model, compact: false)
                    .frame(width: 296)
            }
        }
    }
}

private struct PromptListView: View {
    @ObservedObject var model: AppModel
    @State private var draggedPromptID: Int64?
    @State private var dropTargetPromptID: Int64?

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ProgressView("正在读取提示词库…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                PromptStateView(
                    icon: "exclamationmark.triangle",
                    title: "无法读取提示词库",
                    detail: "本地数据库暂时不可用，请重试。",
                    actionTitle: "重试",
                    action: model.load
                )
            case .ready:
                if model.filteredPrompts.isEmpty {
                    emptyState
                } else {
                    ScrollViewReader { reader in
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 2) {
                                ForEach(model.filteredPrompts) { prompt in
                                    PromptRow(
                                        prompt: prompt,
                                        selected: model.selectedPromptID == prompt.id,
                                        dropTarget: dropTargetPromptID == prompt.id,
                                        dragProvider: {
                                            draggedPromptID = prompt.id
                                            return NSItemProvider(object: "prompt:\(prompt.id)" as NSString)
                                        }
                                    ) {
                                        model.selectedPromptID = prompt.id
                                        model.focusArea = .other
                                    }
                                    .id(prompt.id)
                                    .onDrop(
                                        of: [UTType.text],
                                        delegate: PromptRowDropDelegate(
                                            targetPromptID: prompt.id,
                                            draggedPromptID: $draggedPromptID,
                                            dropTargetPromptID: $dropTargetPromptID,
                                            move: model.movePrompt
                                        )
                                    )
                                    .contextMenu {
                                        Button("使用提示词") {
                                            model.selectedPromptID = prompt.id
                                            model.useSelectedPrompt()
                                        }
                                        Button("编辑") {
                                            model.selectedPromptID = prompt.id
                                            model.beginEditSelectedPrompt()
                                        }
                                        Divider()
                                        Button("删除", role: .destructive) {
                                            model.selectedPromptID = prompt.id
                                            model.deleteSelected()
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 6)
                        }
                        .onChange(of: model.selectedPromptID) { id in
                            guard let id else { return }
                            reader.scrollTo(id)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("提示词列表")
    }

    private var emptyState: some View {
        let needle = model.promptQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            return PromptStateView(
                icon: "magnifyingglass",
                title: "没有匹配「\(needle)」的提示词",
                detail: "试试更短的关键词，或按 ESC 清空搜索。"
            )
        }
        if model.promptScope == .favorite {
            return PromptStateView(
                icon: "star",
                title: "还没有收藏的提示词",
                detail: "选中提示词后按 ⌘S 收藏。"
            )
        }
        return PromptStateView(
            icon: "text.badge.plus",
            title: model.prompts.isEmpty ? "创建你的第一个提示词" : "该分组暂无提示词",
            detail: model.prompts.isEmpty
                ? "按 ⌘N 新建，或从剪贴板历史保存为提示词。"
                : "可以新建提示词，或切换到其他分组。",
            actionTitle: "新建提示词",
            action: { model.beginCreatePrompt() }
        )
    }
}

private struct PromptRow: View {
    let prompt: PromptItem
    let selected: Bool
    let dropTarget: Bool
    let dragProvider: () -> NSItemProvider
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        HStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.accent)
                    .frame(width: 48, height: 30)
                    .background(theme.chip)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.hairline, lineWidth: 0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(prompt.title)
                        .font(.system(size: 13.5))
                        .foregroundStyle(theme.foreground)
                        .lineLimit(1)
                    HStack(spacing: 7) {
                        Text(prompt.groupName)
                        Circle().frame(width: 2.5, height: 2.5).opacity(0.7)
                        Text(variableLabel)
                        if prompt.useCount > 0 {
                            Circle().frame(width: 2.5, height: 2.5).opacity(0.7)
                            Text("使用 \(prompt.useCount) 次").monospacedDigit()
                        }
                        if prompt.isFavorite {
                            Circle().frame(width: 2.5, height: 2.5).opacity(0.7)
                            Image(systemName: "star.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.star)
                                .accessibilityLabel("已收藏")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .highPriorityGesture(
                TapGesture(count: 1).onEnded { _ in action() }
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(prompt.title)，\(prompt.groupName)，\(variableLabel)\(prompt.isFavorite ? "，已收藏" : "")"
            )
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
            .accessibilityAction(named: Text("选择提示词"), action)

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.muted)
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
                .onDrag(dragProvider)
                .accessibilityLabel("拖动排序")
                .accessibilityHint("拖住后移动到另一条提示词的上方或下方")
        }
        .padding(.leading, 9)
        .padding(.vertical, 8)
        .background(selected ? theme.selection : hovering ? theme.chip : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .leading) {
            if selected {
                Capsule().fill(theme.accent).frame(width: 2.5).padding(.vertical, 9).offset(x: -3)
            }
        }
        .overlay(alignment: .top) {
            if dropTarget {
                Capsule()
                    .fill(theme.accent)
                    .frame(height: 2)
                    .padding(.horizontal, 7)
                    .offset(y: -1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onHover { hovering = $0 }
    }

    private var variableLabel: String {
        prompt.variables.isEmpty ? "无变量" : "\(prompt.variables.count) 个变量"
    }
}

private struct PromptRowDropDelegate: DropDelegate {
    let targetPromptID: Int64
    @Binding var draggedPromptID: Int64?
    @Binding var dropTargetPromptID: Int64?
    let move: (Int64, Int64, Bool) -> Void

    func dropEntered(info: DropInfo) {
        guard draggedPromptID != targetPromptID else { return }
        dropTargetPromptID = targetPromptID
    }

    func dropExited(info: DropInfo) {
        if dropTargetPromptID == targetPromptID { dropTargetPromptID = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedPromptID, draggedPromptID != targetPromptID else {
            self.draggedPromptID = nil
            dropTargetPromptID = nil
            return false
        }
        move(draggedPromptID, targetPromptID, info.location.y > 28)
        self.draggedPromptID = nil
        dropTargetPromptID = nil
        return true
    }
}

private struct PromptPreviewView: View {
    @ObservedObject var model: AppModel
    let compact: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        VStack(spacing: 0) {
            if compact {
                actions(theme).padding(.horizontal, 12).padding(.vertical, 11)
            } else if let prompt = model.selectedPrompt {
                VStack(spacing: 0) {
                    Text(prompt.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.foreground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 12)
                    ProgressiveTextView(
                        text: prompt.body,
                        foreground: theme.foregroundSecondary
                    )
                    .id(prompt.id)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    Divider().overlay(theme.hairline)
                    VStack(spacing: 7) {
                        infoLine("分组", prompt.groupName, theme: theme)
                        infoLine("变量", prompt.variables.isEmpty ? "无" : "\(prompt.variables.count) 个", theme: theme)
                        infoLine("使用次数", "\(prompt.useCount) 次", theme: theme)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    actions(theme).padding(.horizontal, 14).padding(.bottom, 13)
                }
            } else {
                Text("选中一个提示词后\n这里显示完整内容")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.glassSecondary)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("提示词预览")
    }

    private func actions(_ theme: ClipFlowTheme) -> some View {
        HStack(spacing: 6) {
            Button(action: model.useSelectedPrompt) {
                HStack(spacing: 5) {
                    Text(model.selectedPrompt?.variables.isEmpty == false ? "填写并复制" : "复制提示词")
                    KeyCap(text: "↵")
                }
            }
            .buttonStyle(GlassButtonStyle(kind: .primary))
            .frame(maxWidth: .infinity)
            .disabled(model.selectedPrompt == nil)
            .keyboardShortcut(.return, modifiers: [])

            Button(action: model.beginEditSelectedPrompt) {
                Image(systemName: "pencil").accessibilityHidden(true)
            }
            .buttonStyle(GlassButtonStyle(kind: .normal, horizontalPadding: 0))
            .frame(width: 26, height: 26)
            .disabled(model.selectedPrompt == nil)
            .accessibilityLabel("编辑提示词")
            .help("编辑（⌘E）")

            Button(action: model.toggleFavorite) {
                Image(systemName: model.selectedPrompt?.isFavorite == true ? "star.fill" : "star")
                    .foregroundStyle(model.selectedPrompt?.isFavorite == true ? theme.star : theme.foregroundSecondary)
                    .accessibilityHidden(true)
            }
            .buttonStyle(GlassButtonStyle(kind: .normal, horizontalPadding: 0))
            .frame(width: 26, height: 26)
            .disabled(model.selectedPrompt == nil)
            .accessibilityLabel(model.selectedPrompt?.isFavorite == true ? "取消收藏" : "收藏")

            Button(action: model.deleteSelected) {
                Image(systemName: "trash").accessibilityHidden(true)
            }
            .buttonStyle(GlassButtonStyle(kind: .danger, horizontalPadding: 0))
            .frame(width: 26, height: 26)
            .disabled(model.selectedPrompt == nil)
            .accessibilityLabel("删除提示词")
        }
    }

    private func infoLine(_ key: String, _ value: String, theme: ClipFlowTheme) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key).foregroundStyle(theme.muted)
            Spacer(minLength: 0)
            Text(value).foregroundStyle(theme.foregroundSecondary).lineLimit(1)
        }
        .font(.system(size: 11.5))
    }
}

struct PromptEditorView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var titleFocused: Bool
    @State private var creatingNewGroup = false
    @State private var groupPickerOpen = false
    @State private var draggedGroup: String?
    @State private var dropTargetGroup: String?

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        modalBackdrop {
            VStack(spacing: 0) {
                modalHeader(
                    model.editingPromptID == nil ? "新建提示词" : "编辑提示词",
                    close: { model.promptEditorOpen = false },
                    theme: theme
                )
                Divider().overlay(theme.hairline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        labeledField("标题", theme: theme) {
                            TextField("例如：文章润色", text: $model.promptDraftTitle)
                                .textFieldStyle(.plain)
                                .focused($titleFocused)
                                .promptField(theme)
                        }

                        labeledField("分组", theme: theme) {
                            VStack(spacing: 8) {
                                Button {
                                    groupPickerOpen.toggle()
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(creatingNewGroup ? "新建分组" : model.promptDraftGroup)
                                            .lineLimit(1)
                                        Spacer(minLength: 8)
                                        Image(systemName: groupPickerOpen ? "chevron.up" : "chevron.down")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(theme.muted)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .promptField(theme)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("选择提示词分组")
                                .accessibilityValue(creatingNewGroup ? "新建分组" : model.promptDraftGroup)
                                .accessibilityHint("展开已有分组列表")

                                if groupPickerOpen {
                                    ScrollView {
                                        VStack(spacing: 2) {
                                            ForEach(selectableGroups, id: \.self) { group in
                                                let draggable = model.promptGroups.contains(group)
                                                    && model.promptGroups.count > 1
                                                let row = PromptGroupOptionRow(
                                                    title: group,
                                                    selected: model.promptDraftGroup == group && !creatingNewGroup,
                                                    draggable: draggable,
                                                    dropTarget: dropTargetGroup == group
                                                ) {
                                                    selectGroup(group)
                                                }
                                                if draggable {
                                                    row
                                                        .onDrag {
                                                            draggedGroup = group
                                                            return NSItemProvider(object: group as NSString)
                                                        }
                                                        .onDrop(
                                                            of: [UTType.text],
                                                            delegate: PromptGroupDropDelegate(
                                                                targetGroup: group,
                                                                draggedGroup: $draggedGroup,
                                                                dropTargetGroup: $dropTargetGroup,
                                                                move: model.movePromptGroup
                                                            )
                                                        )
                                                } else {
                                                    row
                                                }
                                            }

                                            Divider().overlay(theme.hairline).padding(.vertical, 2)
                                            PromptGroupOptionRow(
                                                title: "新建分组…",
                                                selected: creatingNewGroup,
                                                isCreate: true
                                            ) {
                                                model.promptDraftGroup = ""
                                                creatingNewGroup = true
                                                groupPickerOpen = false
                                            }
                                        }
                                        .padding(5)
                                    }
                                    .frame(maxHeight: 176)
                                    .background(theme.glassSecondary.opacity(0.98))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 9)
                                            .stroke(theme.hairline, lineWidth: 0.5)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 9))
                                    .shadow(color: .black.opacity(0.28), radius: 16, y: 8)
                                }

                                if creatingNewGroup {
                                    TextField("输入新分组名称", text: $model.promptDraftGroup)
                                        .textFieldStyle(.plain)
                                        .promptField(theme)
                                }
                            }
                        }

                        labeledField("提示词正文", theme: theme) {
                            TextEditor(text: $model.promptDraftBody)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(theme.foreground)
                                .scrollContentBackground(.hidden)
                                .padding(7)
                                .frame(minHeight: 150)
                                .background(theme.chip)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.hairline, lineWidth: 0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .onChange(of: model.promptDraftBody) { _ in model.syncDraftVariables() }
                        }

                        Text("使用 {{变量名}} 插入变量。调用提示词时，Jaimo Flow 会要求填写变量，再生成最终文本。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.muted)
                            .fixedSize(horizontal: false, vertical: true)

                        if !model.promptDraftVariables.isEmpty {
                            labeledField("变量设置", theme: theme) {
                                VStack(spacing: 8) {
                                    ForEach(model.promptDraftVariables.indices, id: \.self) { index in
                                        HStack(spacing: 8) {
                                            Text(model.promptDraftVariables[index].name)
                                                .font(.system(size: 12, design: .monospaced))
                                                .foregroundStyle(theme.foregroundSecondary)
                                                .frame(width: 92, alignment: .leading)
                                                .lineLimit(1)
                                            TextField("默认值（可选）", text: defaultValueBinding(index))
                                                .textFieldStyle(.plain)
                                                .promptField(theme)
                                            Toggle("必填", isOn: requiredBinding(index))
                                                .toggleStyle(.checkbox)
                                                .font(.system(size: 11.5))
                                                .fixedSize()
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
                Divider().overlay(theme.hairline)
                HStack(spacing: 8) {
                    Spacer()
                    Button("取消") { model.promptEditorOpen = false }
                        .buttonStyle(GlassButtonStyle(kind: .normal))
                        .fixedSize()
                    Button("保存提示词") { model.savePromptDraft() }
                        .buttonStyle(GlassButtonStyle(kind: .primary))
                        .fixedSize()
                        .keyboardShortcut("s", modifiers: .command)
                }
                .padding(14)
            }
            .frame(maxWidth: 560, maxHeight: 570)
            .promptModalCard(theme)
            .padding(28)
        }
        .onAppear {
            creatingNewGroup = false
            groupPickerOpen = false
            draggedGroup = nil
            dropTargetGroup = nil
            DispatchQueue.main.async { titleFocused = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.editingPromptID == nil ? "新建提示词" : "编辑提示词")
    }

    private func defaultValueBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { model.promptDraftVariables.indices.contains(index) ? model.promptDraftVariables[index].defaultValue : "" },
            set: { if model.promptDraftVariables.indices.contains(index) { model.promptDraftVariables[index].defaultValue = $0 } }
        )
    }

    private func requiredBinding(_ index: Int) -> Binding<Bool> {
        Binding(
            get: { model.promptDraftVariables.indices.contains(index) && model.promptDraftVariables[index].isRequired },
            set: { if model.promptDraftVariables.indices.contains(index) { model.promptDraftVariables[index].isRequired = $0 } }
        )
    }

    private func selectGroup(_ group: String) {
        model.promptDraftGroup = group
        creatingNewGroup = false
        groupPickerOpen = false
    }

    private var selectableGroups: [String] {
        model.promptGroups.contains("未分组")
            ? model.promptGroups
            : ["未分组"] + model.promptGroups
    }
}

private struct PromptGroupOptionRow: View {
    let title: String
    let selected: Bool
    var isCreate = false
    var draggable = false
    var dropTarget = false
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        Button(action: action) {
            HStack(spacing: 8) {
                if isCreate {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.accent)
                        .frame(width: 14)
                }
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
                if draggable {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.muted)
                        .frame(width: 14)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 31)
            .background(
                dropTarget ? theme.accent.opacity(0.18)
                    : selected ? theme.selection
                    : hovering ? theme.chip
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(dropTarget ? theme.accent : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(isCreate ? "新建分组" : title)
        .accessibilityHint(draggable ? "可拖拽调整分组顺序" : "")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct PromptGroupDropDelegate: DropDelegate {
    let targetGroup: String
    @Binding var draggedGroup: String?
    @Binding var dropTargetGroup: String?
    let move: (String, String, Bool) -> Void

    func dropEntered(info: DropInfo) {
        guard draggedGroup != targetGroup else { return }
        dropTargetGroup = targetGroup
    }

    func dropExited(info: DropInfo) {
        if dropTargetGroup == targetGroup { dropTargetGroup = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedGroup, draggedGroup != targetGroup else {
            self.draggedGroup = nil
            dropTargetGroup = nil
            return false
        }
        move(draggedGroup, targetGroup, info.location.y > 15.5)
        self.draggedGroup = nil
        dropTargetGroup = nil
        return true
    }
}

struct PromptRunnerView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        modalBackdrop {
            VStack(spacing: 0) {
                modalHeader(
                    model.runnerPrompt?.title ?? "填写提示词变量",
                    close: { model.promptRunnerOpen = false },
                    theme: theme
                )
                Divider().overlay(theme.hairline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 13) {
                        ForEach(model.runnerPrompt?.variables ?? [], id: \.name) { variable in
                            labeledField(variable.name + (variable.isRequired ? " *" : ""), theme: theme) {
                                TextField("输入\(variable.name)", text: valueBinding(variable.name), axis: .vertical)
                                    .textFieldStyle(.plain)
                                    .lineLimit(2...5)
                                    .promptField(theme)
                            }
                        }

                        if let prompt = model.runnerPrompt {
                            labeledField("生成预览", theme: theme) {
                                Text(PromptTemplate.render(prompt.body, values: model.promptVariableValues))
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(theme.foregroundSecondary)
                                    .lineSpacing(7)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(theme.chip)
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.hairline, lineWidth: 0.5))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    .padding(16)
                }
                Divider().overlay(theme.hairline)
                HStack(spacing: 8) {
                    Spacer()
                    Button("取消") { model.promptRunnerOpen = false }
                        .buttonStyle(GlassButtonStyle(kind: .normal))
                        .fixedSize()
                    Button("复制最终文本") { model.copyRenderedPrompt() }
                        .buttonStyle(GlassButtonStyle(kind: .primary))
                        .fixedSize()
                        .disabled(model.hasMissingRequiredPromptVariables)
                        .keyboardShortcut(.return, modifiers: [.command])
                }
                .padding(14)
            }
            .frame(maxWidth: 520, maxHeight: 520)
            .promptModalCard(theme)
            .padding(34)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("填写提示词变量")
    }

    private func valueBinding(_ name: String) -> Binding<String> {
        Binding(
            get: { model.promptVariableValues[name] ?? "" },
            set: { model.promptVariableValues[name] = $0 }
        )
    }
}

struct PromptDeleteConfirmationView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        modalBackdrop {
            VStack(spacing: 14) {
                Image(systemName: "trash")
                    .font(.system(size: 20))
                    .foregroundStyle(theme.danger)
                    .frame(width: 42, height: 42)
                    .background(theme.danger.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                Text("删除这个提示词？")
                    .font(.system(size: 14, weight: .semibold))
                Text("「\(model.selectedPrompt?.title ?? "")」将被永久删除，此操作不会影响剪贴板历史。")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("取消") { model.promptDeleteConfirmationOpen = false }
                        .buttonStyle(GlassButtonStyle(kind: .normal))
                    Button("删除") { model.confirmDeletePrompt() }
                        .buttonStyle(GlassButtonStyle(kind: .danger))
                }
            }
            .padding(22)
            .frame(width: 340)
            .promptModalCard(theme)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("确认删除提示词")
    }
}

private struct PromptStateView: View {
    let icon: String
    let title: String
    let detail: String
    var actionTitle: String?
    var action: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(theme.muted)
                .frame(width: 42, height: 42)
                .background(theme.chip)
                .clipShape(RoundedRectangle(cornerRadius: 11))
            Text(title).font(.system(size: 13.5)).foregroundStyle(theme.foregroundSecondary)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(theme.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(7)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(GlassButtonStyle(kind: .normal))
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(26)
    }
}

private func modalBackdrop<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    ZStack {
        Color.black.opacity(0.42).ignoresSafeArea()
        content()
    }
}

private func modalHeader(
    _ title: String,
    close: @escaping () -> Void,
    theme: ClipFlowTheme
) -> some View {
    HStack {
        Text(title).font(.system(size: 14, weight: .semibold))
        Spacer()
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.muted)
        .accessibilityLabel("关闭")
    }
    .padding(.horizontal, 16)
    .frame(height: 51)
}

private func labeledField<Content: View>(
    _ label: String,
    theme: ClipFlowTheme,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 7) {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.foregroundSecondary)
        content()
    }
}

private extension View {
    func promptField(_ theme: ClipFlowTheme) -> some View {
        self
            .font(.system(size: 12.5))
            .foregroundStyle(theme.foreground)
            .padding(.horizontal, 9)
            .frame(minHeight: 30)
            .background(theme.chip)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.hairline, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    func promptModalCard(_ theme: ClipFlowTheme) -> some View {
        self
            .background(VisualEffectBackground())
            .background(theme.glass.opacity(0.98))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.hairline, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.65), radius: 46, y: 24)
    }
}
