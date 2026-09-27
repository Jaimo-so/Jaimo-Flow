import AppKit
@preconcurrency import AVFoundation
import SwiftUI

@MainActor
final class AudioRecorderModel: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum Status: Equatable {
        case idle
        case requesting
        case recording
        case paused
        case saved(URL)
        case denied
        case unavailable
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var meterLevels: [Double] = Array(repeating: 0.08, count: 28)

    var onWillRevealRecording: (() -> Void)?

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var currentRecordingURL: URL?
    private var operationID = UUID()

    var isRecording: Bool { status == .recording }
    var isPaused: Bool { status == .paused }
    var isActive: Bool { isRecording || isPaused }
    var canOpenSettings: Bool { status == .denied }

    var statusText: String {
        switch status {
        case .idle: return "录音仅保存在本机"
        case .requesting: return "正在请求麦克风权限…"
        case .recording: return "正在录音 · 仅保存在本机"
        case .paused: return "录音已暂停"
        case .saved: return "录音已保存到本机"
        case .denied: return "未获得麦克风权限"
        case .unavailable: return "没有可用的音频输入设备"
        case .failed(let message): return message
        }
    }

    var elapsedText: String {
        let seconds = max(0, Int(elapsedTime.rounded(.down)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var latestRecordingURL: URL? {
        if case .saved(let url) = status { return url }
        return nil
    }

    func toggleRecording() {
        if isRecording {
            pause()
        } else if isPaused {
            resume()
        } else {
            start()
        }
    }

    func start() {
        guard !isActive, status != .requesting else { return }
        let operationID = UUID()
        self.operationID = operationID
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecording(operationID: operationID)
        case .notDetermined:
            status = .requesting
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.operationID == operationID else { return }
                    granted ? self.beginRecording(operationID: operationID) : self.setDenied()
                }
            }
        case .denied, .restricted:
            status = .denied
        @unknown default:
            status = .failed("无法读取麦克风权限")
        }
    }

    func finish() {
        guard isActive, let recorder else { return }
        operationID = UUID()
        let duration = recorder.currentTime
        recorder.stop()
        stopMetering()
        elapsedTime = duration

        guard let url = currentRecordingURL,
              FileManager.default.fileExists(atPath: url.path) else {
            resetRecorder()
            status = .failed("录音保存失败")
            return
        }

        resetRecorder()
        status = .saved(url)
    }

    func finishIfNeeded() {
        if isActive {
            finish()
        } else if status == .requesting {
            operationID = UUID()
            status = .idle
        }
    }

    func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }

    func revealLatestRecording() {
        guard let url = latestRecordingURL else { return }
        onWillRevealRecording?()
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func beginRecording(operationID: UUID) {
        guard self.operationID == operationID else { return }
        do {
            guard AVCaptureDevice.default(for: .audio) != nil else {
                status = .unavailable
                return
            }

            let directory = try recordingsDirectory()
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "yyyy-MM-dd HH-mm-ss-SSS"
            let url = directory
                .appendingPathComponent("Jaimo Flow 录音 \(formatter.string(from: Date()))")
                .appendingPathExtension("m4a")

            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                AVEncoderBitRateKey: 128_000
            ]
            let newRecorder = try AVAudioRecorder(url: url, settings: settings)
            newRecorder.delegate = self
            newRecorder.isMeteringEnabled = true
            guard newRecorder.prepareToRecord(), newRecorder.record() else {
                throw RecorderError.couldNotStart
            }

            recorder = newRecorder
            currentRecordingURL = url
            elapsedTime = 0
            meterLevels = Array(repeating: 0.08, count: meterLevels.count)
            status = .recording
            startMetering()
        } catch {
            resetRecorder()
            status = .failed("无法开始录音")
        }
    }

    private func pause() {
        guard let recorder, recorder.isRecording else { return }
        recorder.pause()
        stopMetering()
        elapsedTime = recorder.currentTime
        status = .paused
    }

    private func resume() {
        guard let recorder, recorder.record() else {
            status = .failed("无法继续录音")
            return
        }
        status = .recording
        startMetering()
    }

    private func startMetering() {
        stopMetering()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshMeter() }
        }
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func refreshMeter() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        elapsedTime = recorder.currentTime

        let decibels = recorder.averagePower(forChannel: 0)
        let normalized = max(0.08, min(1, Double((decibels + 55) / 55)))
        meterLevels.removeFirst()
        meterLevels.append(normalized)
    }

    private func recordingsDirectory() throws -> URL {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw RecorderError.missingApplicationSupport
        }
        let directory = support
            .appendingPathComponent("ClipFlow", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return directory
    }

    private func resetRecorder() {
        stopMetering()
        recorder = nil
        currentRecordingURL = nil
    }

    private func setDenied() {
        resetRecorder()
        status = .denied
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            self?.resetRecorder()
            self?.status = .failed("录音过程中发生错误")
        }
    }

    private enum RecorderError: Error {
        case couldNotStart
        case missingApplicationSupport
    }
}

struct AudioRecorderWidget: View {
    @ObservedObject var model: AudioRecorderModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(model.isActive ? theme.danger.opacity(0.14) : theme.chip)
                    Image(systemName: model.isActive ? "waveform" : "mic")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(model.isActive ? theme.danger : theme.foregroundSecondary)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.elapsedText)
                        .font(.system(size: 21, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                    if let activityLabel {
                        Text(activityLabel)
                            .font(.system(size: 10.5))
                            .lineLimit(2)
                            .foregroundStyle(theme.muted)
                    }
                }

                Spacer(minLength: 8)

                AudioMeterView(levels: model.meterLevels, active: model.isRecording)
                    .frame(width: 52, height: 30)
                    .accessibilityHidden(true)
            }

            HStack(spacing: 7) {
                Button {
                    model.toggleRecording()
                } label: {
                    Label(primaryButtonTitle, systemImage: primaryButtonSymbol)
                }
                .buttonStyle(GlassButtonStyle(kind: .primary))
                .fixedSize()
                .disabled(model.status == .requesting)

                if model.isActive {
                    Button {
                        model.finish()
                    } label: {
                        Label("完成", systemImage: "stop.fill")
                    }
                    .buttonStyle(GlassButtonStyle(kind: .normal))
                    .fixedSize()
                }

                if model.canOpenSettings {
                    Button("打开系统设置", action: model.openPrivacySettings)
                        .buttonStyle(GlassButtonStyle(kind: .normal))
                        .fixedSize()
                } else if model.latestRecordingURL != nil {
                    Button("在访达中显示", action: model.revealLatestRecording)
                        .buttonStyle(GlassButtonStyle(kind: .quiet))
                        .fixedSize()
                }

                Spacer(minLength: 0)
            }
        }
        .frame(minHeight: 96)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("录音组件")
    }

    private var primaryButtonTitle: String {
        if model.isRecording { return "暂停" }
        if model.isPaused { return "继续" }
        return model.status == .requesting ? "正在准备…" : "开始录音"
    }

    private var primaryButtonSymbol: String {
        if model.isRecording { return "pause.fill" }
        if model.isPaused { return "play.fill" }
        return "record.circle"
    }

    private var activityLabel: String? {
        if model.isRecording { return "正在录制麦克风声音" }
        if model.isPaused { return "已暂停，点继续恢复录音" }
        if let url = model.latestRecordingURL { return url.lastPathComponent }
        return nil
    }
}

private struct AudioMeterView: View {
    let levels: [Double]
    let active: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        GeometryReader { proxy in
            HStack(alignment: .center, spacing: 1) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(active ? theme.danger.opacity(0.86) : theme.muted.opacity(0.28))
                        .frame(maxWidth: .infinity)
                        .frame(height: max(3, (proxy.size.height - 2) * level))
                }
            }
            .frame(height: proxy.size.height)
        }
    }
}
