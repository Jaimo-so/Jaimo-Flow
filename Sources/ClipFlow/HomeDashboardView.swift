import AppKit
import ImageIO
@preconcurrency import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

enum HomeWidgetSize: String, Codable, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: return "小型"
        case .medium: return "中型"
        case .large: return "大型"
        }
    }

    var cardHeight: CGFloat {
        switch self {
        case .small: return 178
        case .medium: return 206
        case .large: return 280
        }
    }
}

enum MirrorAspect: String, CaseIterable, Identifiable {
    case automatic, landscape, portrait
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "自动"
        case .landscape: return "横向 16:9"
        case .portrait: return "竖向 9:16"
        }
    }
}

struct HomeWidgetDescriptor: Identifiable {
    let id: HomeDashboardModel.WidgetID
    let title: String
    let defaultOrder: Int
    let defaultVisibility: Bool
    let defaultSize: HomeWidgetSize
    let allowedSizes: [HomeWidgetSize]
}

enum HomeWidgetRegistry {
    static let descriptors: [HomeWidgetDescriptor] = [
        .init(id: .clock, title: "时间", defaultOrder: 0, defaultVisibility: true, defaultSize: .small, allowedSizes: [.small, .medium]),
        .init(id: .quickNote, title: "快速便签", defaultOrder: 1, defaultVisibility: true, defaultSize: .medium, allowedSizes: [.medium, .large]),
        .init(id: .memo, title: "备忘录", defaultOrder: 2, defaultVisibility: true, defaultSize: .medium, allowedSizes: [.medium, .large]),
        .init(id: .audioRecorder, title: "录音", defaultOrder: 3, defaultVisibility: true, defaultSize: .medium, allowedSizes: [.medium, .large]),
        .init(id: .camera, title: "镜子", defaultOrder: 4, defaultVisibility: true, defaultSize: .medium, allowedSizes: [.medium, .large]),
        .init(id: .recentApplications, title: "最近使用", defaultOrder: 5, defaultVisibility: true, defaultSize: .small, allowedSizes: [.small, .medium, .large])
    ]

    static var orderedIDs: [HomeDashboardModel.WidgetID] {
        descriptors.sorted { $0.defaultOrder < $1.defaultOrder }.map(\.id)
    }

    static func descriptor(for id: HomeDashboardModel.WidgetID) -> HomeWidgetDescriptor {
        descriptors.first { $0.id == id }
            ?? .init(id: id, title: id.rawValue, defaultOrder: .max, defaultVisibility: true, defaultSize: .medium, allowedSizes: [.medium])
    }
}

@MainActor
final class HomeDashboardModel: ObservableObject {
    // Keep recording alive when the dashboard is hidden or recreated during navigation.
    let audioRecorder = AudioRecorderModel()
    let memoLibrary = MemoLibraryModel()

    enum WidgetID: String, CaseIterable, Identifiable {
        case clock
        case quickNote
        case memo
        case audioRecorder
        case camera
        case recentApplications

        var id: String { rawValue }

        var title: String {
            HomeWidgetRegistry.descriptor(for: self).title
        }
    }

    enum QuickNoteSaveStatus: Equatable {
        case saving
        case saved
        case failed

        var text: String {
            switch self {
            case .saving: return "正在保存…"
            case .saved: return "已保存 · 仅本机"
            case .failed: return "保存失败，请继续输入后重试"
            }
        }
    }

    @Published var quickNote: String {
        didSet { if quickNote != oldValue { scheduleQuickNoteSave() } }
    }
    @Published private(set) var quickNoteSaveStatus: QuickNoteSaveStatus = .saved
    @Published private(set) var widgetOrder: [WidgetID]
    @Published private(set) var hiddenWidgets: Set<WidgetID>
    @Published private(set) var widgetSizes: [WidgetID: HomeWidgetSize]
    @Published private(set) var editingWidget: WidgetID?
    @Published private(set) var mirrorPhotoURL: URL?
    @Published private(set) var mirrorPhotoError: String?
    @Published private(set) var isLoadingMirrorPhoto = false
    @Published var mirrorAspect: MirrorAspect {
        didSet { defaults.set(mirrorAspect.rawValue, forKey: Key.mirrorAspect) }
    }
    @Published var memoLibraryOpen = false

    private enum Key {
        static let quickNote = "home.quickNote"
        static let widgetOrder = "home.widgetOrder"
        static let hiddenWidgets = "home.hiddenWidgets"
        static let widgetSizes = "home.widgetSizes"
        static let mirrorAspect = "home.mirrorAspect"
    }

    private let defaults: UserDefaults
    private var quickNoteSaveWorkItem: DispatchWorkItem?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mirrorAspect = MirrorAspect(rawValue: defaults.string(forKey: Key.mirrorAspect) ?? "") ?? .automatic
        quickNote = defaults.string(forKey: Key.quickNote) ?? ""

        let registeredIDs = HomeWidgetRegistry.orderedIDs
        let savedOrder = defaults.stringArray(forKey: Key.widgetOrder) ?? []
        let decodedOrder = savedOrder.compactMap(WidgetID.init(rawValue:))
        let missing = registeredIDs.filter { !decodedOrder.contains($0) }
        widgetOrder = decodedOrder + missing

        let hidden = defaults.stringArray(forKey: Key.hiddenWidgets) ?? []
        let defaultHidden = missing.filter {
            !HomeWidgetRegistry.descriptor(for: $0).defaultVisibility
        }
        hiddenWidgets = Set(hidden.compactMap(WidgetID.init(rawValue:))).union(defaultHidden)
        let savedSizes = defaults.dictionary(forKey: Key.widgetSizes) as? [String: String] ?? [:]
        widgetSizes = Dictionary(uniqueKeysWithValues: registeredIDs.map { widget in
            let descriptor = HomeWidgetRegistry.descriptor(for: widget)
            let saved = savedSizes[widget.rawValue].flatMap(HomeWidgetSize.init(rawValue:))
            let resolved = saved.flatMap { descriptor.allowedSizes.contains($0) ? $0 : nil }
                ?? descriptor.defaultSize
            return (widget, resolved)
        })
        editingWidget = nil
        mirrorPhotoURL = Self.existingMirrorPhotoURL()
        mirrorPhotoError = nil
        if mirrorPhotoURL == nil {
            Task { await randomizeMirrorPhoto() }
        }
    }

    var visibleWidgets: [WidgetID] {
        widgetOrder.filter { !hiddenWidgets.contains($0) }
    }

    func move(_ widget: WidgetID, by offset: Int) {
        guard let index = widgetOrder.firstIndex(of: widget) else { return }
        let target = min(max(index + offset, 0), widgetOrder.count - 1)
        guard target != index else { return }
        widgetOrder.remove(at: index)
        widgetOrder.insert(widget, at: target)
        persistLayout()
    }

    func move(_ widget: WidgetID, to targetWidget: WidgetID) {
        guard widget != targetWidget,
              let sourceIndex = widgetOrder.firstIndex(of: widget),
              let targetIndex = widgetOrder.firstIndex(of: targetWidget)
        else { return }
        widgetOrder.remove(at: sourceIndex)
        widgetOrder.insert(widget, at: min(targetIndex, widgetOrder.count))
        editingWidget = widget
        persistLayout()
    }

    func beginEditingWidgets() {
        editingWidget = editingWidget ?? visibleWidgets.first
    }

    func finishEditingWidgets() {
        editingWidget = nil
    }

    func selectWidget(_ widget: WidgetID) {
        editingWidget = widget
    }

    func moveSelectedWidget(by offset: Int) {
        guard let editingWidget else { return }
        move(editingWidget, by: offset)
    }

    func hide(_ widget: WidgetID) {
        hiddenWidgets.insert(widget)
        if editingWidget == widget {
            editingWidget = visibleWidgets.first
        }
        persistLayout()
    }

    func restore(_ widget: WidgetID) {
        hiddenWidgets.remove(widget)
        persistLayout()
    }

    func size(for widget: WidgetID) -> HomeWidgetSize {
        widgetSizes[widget] ?? HomeWidgetRegistry.descriptor(for: widget).defaultSize
    }

    func setSize(_ size: HomeWidgetSize, for widget: WidgetID) {
        guard HomeWidgetRegistry.descriptor(for: widget).allowedSizes.contains(size) else { return }
        widgetSizes[widget] = size
        persistLayout()
    }

    func stepSize(for widget: WidgetID, direction: Int = 1) {
        let allowed = HomeWidgetRegistry.descriptor(for: widget).allowedSizes
        guard allowed.count > 1, let index = allowed.firstIndex(of: size(for: widget)) else { return }
        let target = min(max(index + direction, 0), allowed.count - 1)
        guard target != index else { return }
        setSize(allowed[target], for: widget)
    }

    func chooseMirrorPhoto() {
        guard !isLoadingMirrorPhoto else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "选择照片"
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
        do {
            let extensionName = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension.lowercased()
            try installMirrorPhoto(Data(contentsOf: sourceURL), extensionName: extensionName)
        } catch {
            mirrorPhotoError = "无法保存照片：\(error.localizedDescription)"
        }
    }

    func randomizeMirrorPhoto() async {
        guard !isLoadingMirrorPhoto else { return }
        isLoadingMirrorPhoto = true
        mirrorPhotoError = nil
        defer { isLoadingMirrorPhoto = false }
        do {
            let url = URL(string: "https://picsum.photos/seed/\(UUID().uuidString)/1600/900.jpg")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            try installMirrorPhoto(data, extensionName: "jpg")
        } catch {
            mirrorPhotoError = "随机照片加载失败，请重试或选择本地照片。"
        }
    }

    private func installMirrorPhoto(_ data: Data, extensionName: String) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let directory = try Self.mirrorDirectory()
        let destination = directory.appendingPathComponent("cover.\(UUID().uuidString).\(extensionName)")
        try data.write(to: destination, options: .atomic)
        let oldURL = mirrorPhotoURL
        mirrorPhotoURL = destination
        mirrorPhotoError = nil
        if let oldURL { try? FileManager.default.removeItem(at: oldURL) }
    }

    func removeMirrorPhoto() {
        guard !isLoadingMirrorPhoto else { return }
        guard let mirrorPhotoURL else { return }
        do {
            try FileManager.default.removeItem(at: mirrorPhotoURL)
            self.mirrorPhotoURL = nil
            mirrorPhotoError = nil
        } catch {
            mirrorPhotoError = "无法删除照片：\(error.localizedDescription)"
        }
    }

    private func persistLayout() {
        defaults.set(widgetOrder.map(\.rawValue), forKey: Key.widgetOrder)
        defaults.set(hiddenWidgets.map(\.rawValue).sorted(), forKey: Key.hiddenWidgets)
        defaults.set(
            Dictionary(uniqueKeysWithValues: widgetSizes.map { ($0.key.rawValue, $0.value.rawValue) }),
            forKey: Key.widgetSizes
        )
    }

    func flushQuickNote() {
        guard quickNoteSaveStatus != .saved else { return }
        quickNoteSaveWorkItem?.cancel()
        quickNoteSaveWorkItem = nil
        persistQuickNote(quickNote)
    }

    private func scheduleQuickNoteSave() {
        quickNoteSaveWorkItem?.cancel()
        quickNoteSaveStatus = .saving
        let value = quickNote
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.persistQuickNote(value)
            }
        }
        quickNoteSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: workItem)
    }

    private func persistQuickNote(_ value: String) {
        defaults.set(value, forKey: Key.quickNote)
        guard quickNote == value else { return }
        quickNoteSaveWorkItem = nil
        quickNoteSaveStatus = defaults.string(forKey: Key.quickNote) == value ? .saved : .failed
    }

    private static func mirrorDirectory() throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ClipFlow", isDirectory: true)
            .appendingPathComponent("Mirror", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        return directory
    }

    private static func existingMirrorPhotoURL() -> URL? {
        guard let directory = try? mirrorDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return nil }
        return files.first { $0.lastPathComponent.hasPrefix("cover.") }
    }
}

struct HomeDashboardView: View {
    @ObservedObject var model: HomeDashboardModel
    @ObservedObject var applicationsModel: ApplicationsModel
    @ObservedObject var audioRecorderModel: AudioRecorderModel
    @ObservedObject var memoModel: MemoLibraryModel
    let onOpenApplications: () -> Void

    @StateObject private var cameraModel = CameraCheckModel()
    @State private var editingWidgets = false
    @State private var draggedWidget: HomeDashboardModel.WidgetID?
    @State private var dropTargetWidget: HomeDashboardModel.WidgetID?
    @FocusState private var noteFocused: Bool
    @FocusState private var focusedWidget: HomeDashboardModel.WidgetID?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("工作台")
                        .font(.system(size: 19, weight: .semibold))
                        .tracking(-0.5)
                    Text("\(greeting) · \(Date.now.formatted(.dateTime.month().day().weekday(.wide)))")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.muted)
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
                        if editingWidgets && !model.hiddenWidgets.isEmpty {
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
        .animation(reduceMotion ? FlowMotion.reduced : FlowMotion.content, value: model.memoLibraryOpen)
        .onReceive(NotificationCenter.default.publisher(for: .jaimoFocusQuickNote)) { _ in
            noteFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .jaimoStartCamera)) { _ in
            cameraModel.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: .jaimoStopLocalDevices)) { _ in
            cameraModel.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .jaimoFlushMemos)) { _ in
            memoModel.flush()
        }
        .onChange(of: focusedWidget) { focused in
            guard editingWidgets, let focused else { return }
            model.selectWidget(focused)
        }
        .onChange(of: model.hiddenWidgets) { hidden in
            if hidden.contains(.camera) { cameraModel.stop() }
        }
        .onDisappear {
            cameraModel.stop()
            model.flushQuickNote()
            memoModel.flush()
        }
    }

    private var mirrorAspectRatio: CGFloat {
        guard cameraModel.isRunning else { return 16 / 9 }
        switch model.mirrorAspect {
        case .landscape: return 16 / 9
        case .portrait: return 9 / 16
        case .automatic: return 16 / 9
        }
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
            ForEach(model.widgetOrder.filter { model.hiddenWidgets.contains($0) }) { widget in
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
                subtitle: model.quickNoteSaveStatus == .saved ? nil : model.quickNoteSaveStatus.text,
                widget: widget,
                editing: editingWidgets,
                model: model
            ) {
                TextEditor(text: $model.quickNote)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.foregroundSecondary)
                    .scrollContentBackground(.hidden)
                    .focused($noteFocused)
                    .overlay(alignment: .topLeading) {
                        if model.quickNote.isEmpty {
                            Text("记下稍后要处理的事…")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.muted)
                                .padding(.horizontal, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(minHeight: 80)
                    .accessibilityLabel("快速便签")
            }

        case .memo:
            IslandWidgetCard(
                title: widget.title,
                subtitle: nil,
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
                        ForEach(memoModel.sortedItems.prefix(model.size(for: widget) == .large ? 3 : 2)) { memo in
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
                        }
                        HStack {
                            Button {
                                memoModel.createMemo()
                                model.memoLibraryOpen = true
                            } label: {
                                Label("新建", systemImage: "plus")
                            }
                            .buttonStyle(GlassButtonStyle(kind: .normal))
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
                AudioRecorderWidget(model: audioRecorderModel)
            }

        case .camera:
            MirrorWidgetCard(
                widget: widget,
                editing: editingWidgets,
                model: model
            ) {
                Group {
                    if cameraModel.isRunning {
                        CameraPreviewView(session: cameraModel.session)
                    } else if let photoURL = model.mirrorPhotoURL {
                        CachedDiskImage(url: photoURL, maxPixelSize: 1000, contentMode: .fill)
                            .id(photoURL)
                    } else if model.isLoadingMirrorPhoto {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 28))
                            .foregroundStyle(theme.muted)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !editingWidgets else { return }
                    toggleMirror()
                }
                .contextMenu {
                    MirrorAspectMenu(model: model)
                    Divider()
                    Button("随机换一张") {
                        Task { await model.randomizeMirrorPhoto() }
                    }
                    .disabled(model.isLoadingMirrorPhoto)
                    Button(model.mirrorPhotoURL == nil ? "选择照片" : "替换照片") {
                        model.chooseMirrorPhoto()
                    }
                    .disabled(model.isLoadingMirrorPhoto)
                    if model.mirrorPhotoURL != nil {
                        Button("删除照片", role: .destructive) {
                            model.removeMirrorPhoto()
                        }
                        .disabled(model.isLoadingMirrorPhoto)
                    }
                    if cameraModel.canOpenSettings {
                        Divider()
                        Button("打开摄像头设置", action: cameraModel.openPrivacySettings)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(cameraModel.isRunning ? "镜子实时画面" : "镜子照片")
                .accessibilityHint(cameraModel.isRunning ? "点击关闭摄像头；右键管理照片" : "点击打开摄像头；右键管理照片")
            }

        case .recentApplications:
            IslandWidgetCard(
                title: widget.title,
                subtitle: nil,
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
                                    Image(systemName: "arrow.up.forward")
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
        }
    }

    private func toggleMirror() {
        cameraModel.isRunning ? cameraModel.stop() : cameraModel.start()
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

private struct MirrorWidgetCard<Content: View>: View {
    let widget: HomeDashboardModel.WidgetID
    let editing: Bool
    @ObservedObject var model: HomeDashboardModel
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        GeometryReader { proxy in
            content()
                .frame(width: proxy.size.width, height: proxy.size.height)
            .background(theme.card)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(editing ? (model.editingWidget == widget ? theme.foreground.opacity(0.18) : theme.hairline) : .clear, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if editing {
                    HStack(spacing: 2) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(theme.muted)
                            .frame(width: 22, height: 26)
                            .accessibilityLabel("拖动镜子组件调整顺序")
                            .help("拖动组件调整顺序")
                        HomeWidgetMenu(widget: widget, model: model)
                    }
                    .padding(7)
                    .background(theme.glassSecondary.opacity(0.94))
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .padding(8)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("镜子组件")
            .accessibilityHint(editing ? "拖动整张组件调整顺序，尺寸菜单可调整占用宽度" : "")
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

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.muted)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 6)
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
        .background(theme.card)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(editing ? (model.editingWidget == widget ? theme.foreground.opacity(0.18) : theme.hairline) : .clear, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

private struct MirrorAspectMenu: View {
    @ObservedObject var model: HomeDashboardModel

    var body: some View {
        Picker("画面比例", selection: $model.mirrorAspect) {
            ForEach(MirrorAspect.allCases) { aspect in
                Text(aspect.title).tag(aspect)
            }
        }
    }
}

private struct HomeWidgetMenu: View {
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

@MainActor
final class CameraCheckModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case requesting
        case running
        case denied
        case unavailable
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.clipflow.camera-preview", qos: .userInitiated)
    private var configured = false
    private var operationID = UUID()

    var isRunning: Bool { status == .running }
    var canOpenSettings: Bool { status == .denied }

    var statusText: String {
        switch status {
        case .idle: return "尚未请求摄像头权限"
        case .requesting: return "正在准备摄像头…"
        case .running: return "摄像头正常 · 画面仅本机预览"
        case .denied: return "未获得摄像头权限"
        case .unavailable: return "没有可用的摄像头"
        case .failed(let message): return message
        }
    }

    func start() {
        let operationID = UUID()
        self.operationID = operationID
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart(operationID: operationID)
        case .notDetermined:
            status = .requesting
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.operationID == operationID else { return }
                    granted ? self.configureAndStart(operationID: operationID) : self.setDenied()
                }
            }
        case .denied, .restricted:
            status = .denied
        @unknown default:
            status = .failed("无法读取摄像头权限")
        }
    }

    func stop() {
        operationID = UUID()
        let shouldTearDown = configured || session.isRunning || status == .running || status == .requesting
        status = .idle
        guard shouldTearDown else { return }
        configured = false
        let session = session
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
            guard !session.inputs.isEmpty else { return }
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            session.commitConfiguration()
        }
    }

    func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else { return }
        NSWorkspace.shared.open(url)
    }

    private func configureAndStart(operationID: UUID) {
        guard status != .running else { return }
        status = .requesting
        let session = session
        let needsConfiguration = !configured
        configured = true

        sessionQueue.async { [weak self] in
            do {
                if needsConfiguration {
                    session.beginConfiguration()
                    session.sessionPreset = .medium
                    guard let device = AVCaptureDevice.default(for: .video) else {
                        session.commitConfiguration()
                        throw CameraError.unavailable
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input) else {
                        session.commitConfiguration()
                        throw CameraError.inputUnavailable
                    }
                    session.addInput(input)
                    session.commitConfiguration()
                }
                if !session.isRunning { session.startRunning() }
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.operationID == operationID {
                        self.status = .running
                    } else {
                        self.sessionQueue.async {
                            if session.isRunning { session.stopRunning() }
                        }
                    }
                }
            } catch CameraError.unavailable {
                DispatchQueue.main.async {
                    guard let self, self.operationID == operationID else { return }
                    self.configured = false
                    self.status = .unavailable
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.operationID == operationID else { return }
                    self.configured = false
                    self.status = .failed("无法启动摄像头")
                }
            }
        }
    }

    private func setDenied() {
        status = .denied
    }

    private enum CameraError: Error {
        case unavailable
        case inputUnavailable
    }
}

private struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        nsView.previewLayer.session = session
    }
}

private final class CameraPreviewNSView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }
}
