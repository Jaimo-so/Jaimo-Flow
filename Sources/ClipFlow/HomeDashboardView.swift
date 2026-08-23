import AppKit
@preconcurrency import AVFoundation
import SwiftUI

enum HomeWidgetLayoutRole: String, Codable {
    case compact
    case regular
    case wide
}

struct HomeWidgetDescriptor: Identifiable {
    let id: HomeDashboardModel.WidgetID
    let title: String
    let defaultOrder: Int
    let defaultVisibility: Bool
    let layoutRole: HomeWidgetLayoutRole
}

enum HomeWidgetRegistry {
    static let descriptors: [HomeWidgetDescriptor] = [
        .init(id: .clock, title: "时间", defaultOrder: 0, defaultVisibility: true, layoutRole: .regular),
        .init(id: .quickNote, title: "快速便签", defaultOrder: 1, defaultVisibility: true, layoutRole: .regular),
        .init(id: .audioRecorder, title: "录音", defaultOrder: 2, defaultVisibility: true, layoutRole: .regular),
        .init(id: .camera, title: "摄像头检查", defaultOrder: 3, defaultVisibility: true, layoutRole: .regular),
        .init(id: .recentApplications, title: "最近使用", defaultOrder: 4, defaultVisibility: true, layoutRole: .regular)
    ]

    static var orderedIDs: [HomeDashboardModel.WidgetID] {
        descriptors.sorted { $0.defaultOrder < $1.defaultOrder }.map(\.id)
    }

    static func descriptor(for id: HomeDashboardModel.WidgetID) -> HomeWidgetDescriptor {
        descriptors.first { $0.id == id }
            ?? .init(id: id, title: id.rawValue, defaultOrder: .max, defaultVisibility: true, layoutRole: .regular)
    }
}

@MainActor
final class HomeDashboardModel: ObservableObject {
    enum WidgetID: String, CaseIterable, Identifiable {
        case clock
        case quickNote
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
        didSet { scheduleQuickNoteSave() }
    }
    @Published private(set) var quickNoteSaveStatus: QuickNoteSaveStatus = .saved
    @Published private(set) var widgetOrder: [WidgetID]
    @Published private(set) var hiddenWidgets: Set<WidgetID>
    @Published private(set) var editingWidget: WidgetID?

    private enum Key {
        static let quickNote = "home.quickNote"
        static let widgetOrder = "home.widgetOrder"
        static let hiddenWidgets = "home.hiddenWidgets"
    }

    private let defaults: UserDefaults
    private var quickNoteSaveWorkItem: DispatchWorkItem?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        editingWidget = nil
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

    private func persistLayout() {
        defaults.set(widgetOrder.map(\.rawValue), forKey: Key.widgetOrder)
        defaults.set(hiddenWidgets.map(\.rawValue).sorted(), forKey: Key.hiddenWidgets)
    }

    func flushQuickNote() {
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
}

struct HomeDashboardView: View {
    @ObservedObject var model: HomeDashboardModel
    @ObservedObject var applicationsModel: ApplicationsModel
    let onOpenApplications: () -> Void

    @StateObject private var cameraModel = CameraCheckModel()
    @StateObject private var audioRecorderModel = AudioRecorderModel()
    @State private var editingWidgets = false
    @FocusState private var noteFocused: Bool
    @FocusState private var focusedWidget: HomeDashboardModel.WidgetID?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("今天也是高效的一天")
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.muted)
                    Text(greeting)
                        .font(.system(size: 18, weight: .semibold))
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
                    }
                } label: {
                    Label(editingWidgets ? "完成" : "管理组件", systemImage: editingWidgets ? "checkmark" : "slider.horizontal.3")
                }
                .buttonStyle(GlassButtonStyle(kind: editingWidgets ? .primary : .normal))
                .fixedSize()
            }
            .padding(.horizontal, 18)
            .frame(height: 72)

            Divider().overlay(theme.weakHairline)

            GeometryReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 12) {
                        if !model.hiddenWidgets.isEmpty {
                            restoreBar(theme)
                        }

                        LazyVGrid(
                            columns: proxy.size.width >= 720
                                ? [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
                                : [GridItem(.flexible())],
                            spacing: 12
                        ) {
                            ForEach(model.visibleWidgets) { widget in
                                widgetView(widget, theme: theme)
                                    .frame(minHeight: 176)
                                    .focusable(editingWidgets)
                                    .focused($focusedWidget, equals: widget)
                                    .onTapGesture {
                                        guard editingWidgets else { return }
                                        model.selectWidget(widget)
                                        focusedWidget = widget
                                    }
                            }
                        }
                    }
                    .padding(18)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .jaimoFocusQuickNote)) { _ in
            noteFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .jaimoStartCamera)) { _ in
            cameraModel.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: .jaimoStopLocalDevices)) { _ in
            cameraModel.stop()
            audioRecorderModel.finishIfNeeded()
        }
        .onChange(of: focusedWidget) { focused in
            guard editingWidgets, let focused else { return }
            model.selectWidget(focused)
        }
        .onChange(of: model.hiddenWidgets) { hidden in
            if hidden.contains(.camera) { cameraModel.stop() }
            if hidden.contains(.audioRecorder) { audioRecorderModel.finishIfNeeded() }
        }
        .onDisappear {
            cameraModel.stop()
            audioRecorderModel.finishIfNeeded()
            model.flushQuickNote()
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 6 { return "夜深了，Jaimo Flow" }
        if hour < 12 { return "上午好，Jaimo Flow" }
        if hour < 18 { return "下午好，Jaimo Flow" }
        return "晚上好，Jaimo Flow"
    }

    private func restoreBar(_ theme: ClipFlowTheme) -> some View {
        HStack(spacing: 8) {
            Text("已隐藏")
                .font(.system(size: 11))
                .foregroundStyle(theme.muted)
            ForEach(model.widgetOrder.filter { model.hiddenWidgets.contains($0) }) { widget in
                Button(widget.title) { model.restore(widget) }
                    .buttonStyle(GlassButtonStyle(kind: .normal))
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(theme.hairline, style: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
        )
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
                            .font(.system(size: 44, weight: .semibold))
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
                subtitle: model.quickNoteSaveStatus.text,
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
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(minHeight: 112)
                    .accessibilityLabel("快速便签")
            }

        case .audioRecorder:
            IslandWidgetCard(
                title: widget.title,
                subtitle: audioRecorderModel.statusText,
                widget: widget,
                editing: editingWidgets,
                model: model
            ) {
                AudioRecorderWidget(model: audioRecorderModel)
            }

        case .camera:
            IslandWidgetCard(
                title: widget.title,
                subtitle: cameraModel.statusText,
                widget: widget,
                editing: editingWidgets,
                model: model
            ) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("会议前快速确认画面")
                            .font(.system(size: 14, weight: .semibold))
                        Text("画面只在本机预览，不录制、不保存、不上传。")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.muted)
                            .lineSpacing(4)

                        HStack(spacing: 7) {
                            Button {
                                cameraModel.isRunning ? cameraModel.stop() : cameraModel.start()
                            } label: {
                                Label(cameraModel.isRunning ? "停止预览" : "启动摄像头", systemImage: "video")
                            }
                            .buttonStyle(GlassButtonStyle(kind: .primary))
                            .fixedSize()

                            if cameraModel.canOpenSettings {
                                Button("打开系统设置", action: cameraModel.openPrivacySettings)
                                    .buttonStyle(GlassButtonStyle(kind: .normal))
                                    .fixedSize()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Group {
                        if cameraModel.isRunning {
                            CameraPreviewView(session: cameraModel.session)
                        } else {
                            VStack(spacing: 7) {
                                Image(systemName: "video.slash")
                                    .font(.system(size: 20))
                                Text("预览未开启")
                                    .font(.system(size: 10.5))
                            }
                            .foregroundStyle(theme.muted)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(theme.glassSecondary)
                        }
                    }
                    .frame(width: 150, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.hairline, lineWidth: 0.5))
                }
            }

        case .recentApplications:
            IslandWidgetCard(
                title: widget.title,
                subtitle: "从 Jaimo Flow 启动的本机应用",
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
                    .frame(maxWidth: .infinity, minHeight: 110)
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
}

private struct IslandWidgetCard<Content: View>: View {
    let title: String
    let subtitle: String
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
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.muted)
                        .lineLimit(2)
                }
                Spacer(minLength: 6)
                if editing {
                    HStack(spacing: 2) {
                        editButton("arrow.up", label: "向前移动 \(title)") { model.move(widget, by: -1) }
                        editButton("arrow.down", label: "向后移动 \(title)") { model.move(widget, by: 1) }
                        editButton("eye.slash", label: "隐藏 \(title)") { model.hide(widget) }
                    }
                }
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(theme.glassSecondary.opacity(0.72))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    editing && model.editingWidget == widget ? theme.accent.opacity(0.72) : theme.hairline,
                    style: editing
                        ? StrokeStyle(lineWidth: model.editingWidget == widget ? 1.2 : 0.7, dash: [4, 4])
                        : StrokeStyle(lineWidth: 0.5)
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title)组件")
        .accessibilityHint(editing ? "按 Option 加上下方向键调整顺序" : "")
    }

    private func editButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(IslandWidgetEditButtonStyle())
        .accessibilityLabel(label)
        .help(label)
    }
}

private struct IslandWidgetEditButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        configuration.label
            .foregroundStyle(theme.muted)
            .background(configuration.isPressed ? theme.chipHigh : theme.chip)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct IslandRecentRowStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        configuration.label
            .background(configuration.isPressed ? theme.chipHigh : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
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
