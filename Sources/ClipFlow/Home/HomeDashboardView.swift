import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HomeDashboardView: View {
    @ObservedObject var model: HomeDashboardModel
    @ObservedObject var applicationsModel: ApplicationsModel
    let audioRecorderModel: AudioRecorderModel
    @ObservedObject var cameraModel: CameraCheckModel
    @ObservedObject var memoModel: MemoLibraryModel
    let onOpenApplications: () -> Void
    let onRecentApplicationsAppear: () -> Void

    @State private var editingWidgets = false
    @State private var draggedWidget: HomeDashboardModel.WidgetID?
    @State private var dropTargetWidget: HomeDashboardModel.WidgetID?
    @State private var noteFocusRequest = 0
    @FocusState private var focusedWidget: HomeDashboardModel.WidgetID?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(greeting) · \(Date.now.formatted(.dateTime.month().day().weekday(.wide).locale(Locale(identifier: "zh_CN"))))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.muted)
                    Text("工作台")
                        .font(.system(size: 23, weight: .semibold))
                        .tracking(-0.5)
                }
                Spacer()
                Button {
                    let willEdit = !editingWidgets
                    editingWidgets = willEdit
                    if willEdit {
                        model.beginEditingWidgets()
                        DispatchQueue.main.async {
                            focusedWidget = model.editingWidget
                        }
                    } else {
                        model.finishEditingWidgets()
                        focusedWidget = nil
                        draggedWidget = nil
                        dropTargetWidget = nil
                    }
                } label: {
                    Label(editingWidgets ? "完成" : "管理组件", systemImage: editingWidgets ? "checkmark" : "slider.horizontal.3")
                }
                .buttonStyle(GlassButtonStyle(kind: editingWidgets ? .primary : .normal))
                .fixedSize()
                .help("排序、调整大小与恢复已隐藏的组件")
            }
            .padding(.horizontal, 18)
            .frame(height: 64)

            GeometryReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 12) {
                        if editingWidgets && !model.restorableWidgets.isEmpty {
                            restoreBar(theme)
                                .transition(.opacity)
                        }

                        adaptiveWidgetGrid(columns: proxy.size.width >= 840 ? 3 : proxy.size.width >= 560 ? 2 : 1, theme: theme)
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
                    .padding(.top, 4)
                    .animation(reduceMotion ? nil : FlowMotion.layout, value: model.hiddenWidgets)
                }
            }
        }
        .overlay {
            if model.memoLibraryOpen {
                MemoLibraryOverlay(model: memoModel) { model.memoLibraryOpen = false }
                    .transition(FlowMotion.reveal(reduceMotion: reduceMotion))
            }
        }
        .overlay {
            if model.dailyReviewHistoryOpen {
                DailyReviewHistoryOverlay(model: model.dailyReview) {
                    model.dailyReviewHistoryOpen = false
                }
                .transition(FlowMotion.reveal(reduceMotion: reduceMotion))
            }
        }
        .overlay {
            if model.recordingWorkspaceOpen, let transcription = model.recordingTranscription {
                RecordingWorkspaceOverlay(
                    transcription: transcription,
                    onRevealRecording: { url in
                        audioRecorderModel.onWillRevealRecording?()
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    },
                    onClose: {
                        model.closeRecordingWorkspace()
                    }
                )
                .transition(FlowMotion.reveal(reduceMotion: reduceMotion))
            }
        }
        .animation(reduceMotion ? FlowMotion.reduced : FlowMotion.content, value: model.memoLibraryOpen)
        .animation(reduceMotion ? FlowMotion.reduced : FlowMotion.content, value: model.dailyReviewHistoryOpen)
        .animation(reduceMotion ? FlowMotion.reduced : FlowMotion.content, value: model.recordingWorkspaceOpen)
        .onReceive(NotificationCenter.default.publisher(for: .jaimoFocusQuickNote)) { _ in
            noteFocusRequest += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .jaimoStartCamera)) { _ in
            if model.visibleWidgets.contains(.camera) { cameraModel.start() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .jaimoStopLocalDevices)) { _ in
            cameraModel.stop()
        }
        .onChange(of: focusedWidget) { focused in
            guard editingWidgets, let focused else { return }
            model.selectWidget(focused)
        }
        .onChange(of: model.hiddenWidgets) { hidden in
            if hidden.contains(.camera) { cameraModel.stop() }
            if hidden.contains(.quickNote) { model.flushQuickNote() }
        }
        .onDisappear {
            cameraModel.stop()
            model.flushQuickNote()
            memoModel.flush()
        }
    }

    private var mirrorAspectRatio: CGFloat {
        model.mirrorAspectRatio(liveCamera: cameraModel.isRunning)
    }

    private func adaptiveWidgetGrid(columns: Int, theme: ClipFlowTheme) -> some View {
        HomeWidgetLayout(columns: columns, spacing: 12) {
            ForEach(model.visibleWidgets) { widget in
                widgetCell(widget, theme: theme)
                    .layoutValue(key: HomeWidgetSpan.self, value: model.size(for: widget) == .large ? 2 : 1)
                    .layoutValue(key: HomeWidgetHeight.self, value: widget == .recentApplications
                        ? max(HomeWidgetSize.medium.cardHeight, model.size(for: widget).cardHeight)
                        : model.size(for: widget).cardHeight)
                    .layoutValue(key: HomeWidgetAspectRatio.self, value: widget == .camera ? mirrorAspectRatio : 0)
                    .transition(FlowMotion.reveal(reduceMotion: reduceMotion))
                    .zIndex(model.editingWidget == widget ? 1 : 0)
            }
        }
        .animation(reduceMotion ? nil : FlowMotion.layout, value: model.widgetOrder)
        .animation(reduceMotion ? nil : FlowMotion.layout, value: model.widgetSizes)
        .animation(reduceMotion ? nil : FlowMotion.layout, value: model.hiddenWidgets)
        .animation(reduceMotion ? FlowMotion.reduced : FlowMotion.content, value: editingWidgets)
        .animation(reduceMotion ? nil : FlowMotion.layout, value: mirrorAspectRatio)
    }

    @ViewBuilder
    private func widgetCell(_ widget: HomeDashboardModel.WidgetID, theme: ClipFlowTheme) -> some View {
        if editingWidgets {
            baseWidgetCell(widget, theme: theme)
                .opacity(draggedWidget == widget ? 0.58 : 1)
                .overlay(alignment: .top) {
                    if dropTargetWidget == widget {
                        Capsule()
                            .fill(theme.accent)
                            .frame(height: 3)
                            .padding(.horizontal, 14)
                            .offset(y: -7)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .onDrag {
                    draggedWidget = widget
                    dropTargetWidget = nil
                    model.selectWidget(widget)
                    focusedWidget = widget
                    return NSItemProvider(object: widget.rawValue as NSString)
                }
                .onDrop(
                    of: [UTType.plainText],
                    isTargeted: dropTargetBinding(for: widget)
                ) { _ in
                    guard let draggedWidget else { return false }
                    model.move(draggedWidget, to: widget)
                    self.draggedWidget = nil
                    dropTargetWidget = nil
                    focusedWidget = draggedWidget
                    return true
                }
        } else {
            baseWidgetCell(widget, theme: theme)
        }
    }

    private func baseWidgetCell(_ widget: HomeDashboardModel.WidgetID, theme: ClipFlowTheme) -> some View {
        widgetView(widget, theme: theme)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(HomeWidgetFocus(editing: editingWidgets))
            .focused($focusedWidget, equals: widget)
            .onTapGesture {
                guard editingWidgets else { return }
                model.selectWidget(widget)
                focusedWidget = widget
            }
    }

    private func dropTargetBinding(for widget: HomeDashboardModel.WidgetID) -> Binding<Bool> {
        Binding {
            dropTargetWidget == widget
        } set: { isTargeted in
            if isTargeted, draggedWidget != nil, draggedWidget != widget {
                dropTargetWidget = widget
            } else if !isTargeted, dropTargetWidget == widget {
                dropTargetWidget = nil
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 6 { return "夜深了" }
        if hour < 12 { return "上午好" }
        if hour < 18 { return "下午好" }
        return "晚上好"
    }

    private func restoreBar(_ theme: ClipFlowTheme) -> some View {
        HStack(spacing: 8) {
            Text("已隐藏")
                .font(.system(size: 11))
                .foregroundStyle(theme.muted)
            ForEach(model.restorableWidgets) { widget in
                Button { model.restore(widget) } label: {
                    Label(widget.title, systemImage: "plus")
                }
                    .buttonStyle(GlassButtonStyle(kind: .normal))
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(10)
    }

    @ViewBuilder
    private func widgetView(_ widget: HomeDashboardModel.WidgetID, theme: ClipFlowTheme) -> some View {
        switch widget {
        case .dailyReview:
            IslandWidgetCard(
                title: widget.title,
                subtitle: nil,
                widget: widget,
                editing: editingWidgets,
                model: model
            ) {
                DailyReviewWidget(model: model.dailyReview) {
                    model.dailyReviewHistoryOpen = true
                }
            }

        case .clock:
            IslandWidgetCard(
                title: widget.title,
                subtitle: "上海 · 中国标准时间",
                widget: widget,
                editing: editingWidgets,
                model: model
            ) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(context.date, format: .dateTime.hour().minute())
                            .font(.system(size: 34, weight: .semibold))
                            .monospacedDigit()
                        Text(context.date.formatted(.dateTime.year().month(.wide).day().weekday(.wide)))
                            .font(.system(size: 12))
                            .foregroundStyle(theme.foregroundSecondary)
                        Text(TimeZone.current.identifier)
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

        case .quickNote:
            IslandWidgetCard(
                title: widget.title,
                subtitle: model.quickNoteSaveStatus == .saved ? "已保存" : model.quickNoteSaveStatus.text,
                widget: widget,
                editing: editingWidgets,
                model: model
            ) {
                NoteTextEditor(text: $model.quickNote, fontSize: 12, foreground: theme.foregroundSecondary, identifier: "jaimo.quickNote.editor", focusRequest: noteFocusRequest)
                    .overlay(alignment: .topLeading) {
                        if model.quickNote.isEmpty {
                            Text("记下稍后要处理的事…")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.muted)
                                .padding(.horizontal, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(9)
                    .flowInset(theme)
                    .frame(minHeight: 80)
                    .accessibilityLabel("快速便签")
                if model.quickNoteSaveStatus == .failed {
                    Button("重试保存") { model.flushQuickNote() }
                        .buttonStyle(GlassButtonStyle(kind: .normal))
                }
            }

        case .memo:
            IslandWidgetCard(
                title: widget.title,
                subtitle: "\(memoModel.items.count) 条",
                widget: widget,
                editing: editingWidgets,
                model: model
            ) {
                VStack(spacing: 7) {
                    if memoModel.items.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "note.text")
                                .font(.system(size: 21))
                                .foregroundStyle(theme.muted)
                            Text("记录需要长期保留的事情")
                                .font(.system(size: 11.5))
                                .foregroundStyle(theme.foregroundSecondary)
                            Button("新建备忘录") {
                                memoModel.createMemo()
                                model.memoLibraryOpen = true
                            }
                            .buttonStyle(GlassButtonStyle(kind: .primary))
                            .fixedSize()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        let visibleMemos = memoModel.sortedItems.prefix(model.size(for: widget) == .large ? 3 : 2)
                        VStack(spacing: 0) {
                            ForEach(visibleMemos) { memo in
                                Button {
                                    memoModel.selectedID = memo.id
                                    model.memoLibraryOpen = true
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: memo.isPinned ? "pin.fill" : "note.text")
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(memo.isPinned ? theme.star : theme.muted)
                                            .frame(width: 18)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(memo.title.isEmpty ? "无标题备忘录" : memo.title)
                                                .font(.system(size: 11.5, weight: .medium))
                                                .lineLimit(1)
                                            Text(memo.body.isEmpty ? "暂无正文" : memo.body.replacingOccurrences(of: "\n", with: " "))
                                                .font(.system(size: 11))
                                                .foregroundStyle(theme.muted)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 9))
                                            .foregroundStyle(theme.muted)
                                    }
                                    .padding(7)
                                    .contentShape(RoundedRectangle(cornerRadius: 9))
                                }
                                .buttonStyle(IslandRecentRowStyle())
                                if memo.id != visibleMemos.last?.id {
                                    Divider().overlay(theme.weakHairline).padding(.leading, 34)
                                }
                            }
                        }
                        .flowInset(theme)
                        Spacer(minLength: 0)
                        HStack {
                            Button {
                                memoModel.createMemo()
                                model.memoLibraryOpen = true
                            } label: {
                                Label("新建", systemImage: "plus")
                            }
                            .buttonStyle(GlassButtonStyle(kind: .primary))
                            .fixedSize()
                            Button("打开全部") { model.memoLibraryOpen = true }
                                .buttonStyle(GlassButtonStyle(kind: .quiet))
                                .fixedSize()
                            Spacer()
                        }
                    }
                }
            }

        case .audioRecorder:
            IslandWidgetCard(
                title: widget.title,
                subtitle: nil,
                widget: widget,
                editing: editingWidgets,
                model: model
            ) {
                if let transcription = model.recordingTranscription {
                    AudioRecorderWidgetWithTranscription(
                        model: audioRecorderModel,
                        transcription: transcription,
                        onOpenWorkspace: model.openRecordingWorkspace(selecting:)
                    )
                } else {
                    AudioRecorderWidget(
                        model: audioRecorderModel,
                        autoTranscriptionEnabled: model.shouldAutoTranscribeRecording,
                        onOpenWorkspace: model.openRecordingWorkspace(selecting:)
                    )
                }
            }

        case .camera:
            MirrorWidgetView(model: model, cameraModel: cameraModel, editing: editingWidgets)

        case .recentApplications:
            IslandWidgetCard(
                title: widget.title,
                subtitle: "\(min(3, applicationsModel.recentApplications.count)) 个应用",
                widget: widget,
                editing: editingWidgets,
                model: model
            ) {
                if applicationsModel.recentApplications.isEmpty {
                    VStack(spacing: 9) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 20))
                            .foregroundStyle(theme.muted)
                        Text("还没有启动记录")
                            .font(.system(size: 12.5))
                            .foregroundStyle(theme.foregroundSecondary)
                        Button("打开应用程序", action: onOpenApplications)
                            .buttonStyle(GlassButtonStyle(kind: .normal))
                            .fixedSize()
                    }
                    .frame(maxWidth: .infinity, minHeight: 90)
                } else {
                    VStack(spacing: 4) {
                        ForEach(applicationsModel.recentApplications.prefix(3)) { application in
                            Button {
                                applicationsModel.launch(application)
                            } label: {
                                HStack(spacing: 9) {
                                    Image(nsImage: application.icon)
                                        .resizable()
                                        .interpolation(.high)
                                        .frame(width: 30, height: 30)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(application.displayName)
                                            .font(.system(size: 11.5, weight: .medium))
                                            .lineLimit(1)
                                        Text(application.relativeLaunchTime)
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(theme.muted)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(theme.muted)
                                }
                                .padding(7)
                                .contentShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(IslandRecentRowStyle())
                            .accessibilityLabel("启动 \(application.displayName)")
                        }
                    }
                }
            }
            .onAppear(perform: onRecentApplicationsAppear)
        }
    }
}

/// Keep keyboard selection without the system's prominent blue focus ring.
private struct HomeWidgetFocus: ViewModifier {
    let editing: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusable(editing).focusEffectDisabled()
        } else {
            // Older systems cannot suppress the card ring; its menu and buttons
            // remain keyboard accessible without focusing the entire card.
            content
        }
    }
}

private struct IslandWidgetCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let widget: HomeDashboardModel.WidgetID
    let editing: Bool
    @ObservedObject var model: HomeDashboardModel
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    private func badge(_ theme: ClipFlowTheme) -> (icon: String, tint: Color) {
        switch widget {
        case .quickNote: return ("pencil", theme.star)
        case .recentApplications: return ("square.grid.2x2.fill", theme.accent)
        case .audioRecorder: return ("mic.fill", theme.danger)
        case .memo: return ("doc.text.fill", theme.orange)
        case .dailyReview: return ("calendar", theme.purple)
        case .clock: return ("clock.fill", theme.cyan)
        case .camera: return ("camera.fill", theme.cyan)
        }
    }

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        let badge = badge(theme)
        let shape = RoundedRectangle(cornerRadius: WindowMetrics.tileRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: badge.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(widget == .quickNote ? .black.opacity(0.72) : .white)
                    .frame(width: 26, height: 26)
                    .background(badge.tint.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize()
                Spacer(minLength: 0)
                if let subtitle, !editing {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.muted)
                        .lineLimit(2)
                }
                if editing {
                    HStack(spacing: 2) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(theme.muted)
                            .frame(width: 22, height: 26)
                            .accessibilityLabel("拖动 \(title) 组件调整顺序")
                            .help("拖动组件调整顺序")
                        HomeWidgetMenu(widget: widget, model: model)
                    }
                }
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(14)
        .flowGlass(shape, fill: theme.tileFill(tint: badge.tint), theme: theme)
        .background {
            if colorScheme == .dark { shape.fill(theme.card.opacity(0.54)) }
        }
        .overlay {
            if editing && model.editingWidget == widget {
                shape.strokeBorder(theme.foregroundSecondary.opacity(0.55)).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if editing, HomeWidgetRegistry.descriptor(for: widget).allowedSizes.count > 1 {
                Button { model.stepSize(for: widget) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(FlowIconButtonStyle())
                .padding(7)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8).onEnded { value in
                        let outward = value.translation.width + value.translation.height
                        model.stepSize(for: widget, direction: outward >= 0 ? 1 : -1)
                    }
                )
                .accessibilityLabel("调整 \(title) 组件尺寸")
                .accessibilityHint("点击扩大，或拖动手柄在可用档位之间调整")
                .help("拖动调整组件尺寸")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title)组件")
        .accessibilityHint(editing ? "拖动整张组件卡片调整顺序，尺寸菜单或右下角手柄可调整大小" : "")
    }
}

struct HomeWidgetMenu: View {
    let widget: HomeDashboardModel.WidgetID
    @ObservedObject var model: HomeDashboardModel

    var body: some View {
        Menu {
            if widget == .camera {
                MirrorAspectMenu(model: model)
                Divider()
            }
            Section("组件尺寸") {
                ForEach(HomeWidgetRegistry.descriptor(for: widget).allowedSizes) { size in
                    Button {
                        model.selectWidget(widget)
                        model.setSize(size, for: widget)
                    } label: {
                        if model.size(for: widget) == size {
                            Label(size.title, systemImage: "checkmark")
                        } else {
                            Text(size.title)
                        }
                    }
                }
            }
            Divider()
            Button { move(by: -1) } label: {
                Label("向前移动", systemImage: "arrow.up")
            }
            .disabled(model.visibleWidgets.first == widget)
            Button { move(by: 1) } label: {
                Label("向后移动", systemImage: "arrow.down")
            }
            .disabled(model.visibleWidgets.last == widget)
            Divider()
            Button { model.hide(widget) } label: {
                Label("隐藏组件", systemImage: "eye.slash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("\(widget.title)组件选项")
        .help("调整大小、移动或隐藏组件")
    }

    private func move(by offset: Int) {
        let visible = model.visibleWidgets
        guard let index = visible.firstIndex(of: widget), visible.indices.contains(index + offset) else { return }
        model.move(widget, to: visible[index + offset])
    }
}

private struct IslandRecentRowStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        configuration.label
            .background(configuration.isPressed ? theme.chipHigh : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .modifier(FlowControlFeedback(isPressed: configuration.isPressed, cornerRadius: 10, hoverFill: theme.chip, pressedScale: 0.99))
    }
}
