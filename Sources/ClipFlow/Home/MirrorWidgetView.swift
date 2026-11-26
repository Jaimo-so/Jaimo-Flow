import AppKit
@preconcurrency import AVFoundation
import SwiftUI

struct MirrorWidgetView: View {
    @ObservedObject var model: HomeDashboardModel
    @ObservedObject var cameraModel: CameraCheckModel
    let editing: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        MirrorWidgetCard(
            widget: .camera,
            editing: editing,
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
                guard !editing else { return }
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
    }

    private func toggleMirror() {
        guard model.isWidgetAvailable(.camera) else { return }
        cameraModel.isRunning ? cameraModel.stop() : cameraModel.start()
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
                .flowGlass(RoundedRectangle(cornerRadius: WindowMetrics.tileRadius, style: .continuous), fill: theme.card, theme: theme)
                .overlay {
                    RoundedRectangle(cornerRadius: WindowMetrics.tileRadius, style: .continuous)
                        .strokeBorder(editing && model.editingWidget == widget ? theme.foregroundSecondary.opacity(0.55) : .clear)
                        .allowsHitTesting(false)
                }
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

struct MirrorAspectMenu: View {
    @ObservedObject var model: HomeDashboardModel

    var body: some View {
        Picker("画面比例", selection: $model.mirrorAspect) {
            ForEach(MirrorAspect.allCases) { aspect in
                Text(aspect.title).tag(aspect)
            }
        }
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
        guard status != .requesting, !isRunning else { return }
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
                    defer { session.commitConfiguration() }
                    session.sessionPreset = .medium
                    guard let device = AVCaptureDevice.default(for: .video) else {
                        throw CameraError.unavailable
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input) else {
                        throw CameraError.inputUnavailable
                    }
                    session.addInput(input)
                }
                if !session.isRunning { session.startRunning() }
                DispatchQueue.main.async {
                    guard let self, self.operationID == operationID else { return }
                    self.status = .running
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
