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
    var onDidFinishRecording: ((URL) -> Void)?

    init(recordingsDirectory directoryOverride: URL? = nil) {
        self.directoryOverride = directoryOverride
        super.init()
        if let directory = directoryOverride ?? (try? recordingsDirectory()),
           let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]),
           let latest = files.filter({ $0.pathExtension.lowercased() == "m4a" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).first {
            status = .saved(latest)
        }
    }

    private let directoryOverride: URL?
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var currentRecordingURL: URL?
    private var operationID = UUID()
    private var isEnabled = true

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

    func canDeleteRecording(_ url: URL) -> Bool {
        !(isActive && currentRecordingURL == url)
    }

    func recordingWasDeleted(_ url: URL, latestRemaining: URL?) {
        guard case .saved(let savedURL) = status, savedURL == url else { return }
        status = latestRemaining.map { .saved($0) } ?? .idle
        elapsedTime = 0
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

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled { finishIfNeeded() }
    }

    func start() {
        guard isEnabled, !isActive, status != .requesting else { return }
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
        onDidFinishRecording?(url)
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

    private static let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss-SSS"
        return formatter
    }()

    private func beginRecording(operationID: UUID) {
        guard self.operationID == operationID else { return }
        do {
            guard AVCaptureDevice.default(for: .audio) != nil else {
                status = .unavailable
                return
            }

            let directory = try recordingsDirectory()
            let url = directory
                .appendingPathComponent("Jaimo Flow 录音 \(Self.filenameDateFormatter.string(from: Date()))")
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
        let directory = directoryOverride ?? support
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
            guard let self, self.recorder === recorder else { return }
            self.resetRecorder()
            self.status = .failed("录音过程中发生错误")
        }
    }

    private enum RecorderError: Error {
        case couldNotStart
        case missingApplicationSupport
    }
}

struct AudioRecorderWidgetWithTranscription: View {
    let model: AudioRecorderModel
    @ObservedObject var transcription: RecordingTranscriptionManager
    let onOpenWorkspace: (URL?) -> Void

    var body: some View {
        AudioRecorderWidget(
            model: model,
            transcription: transcription,
            autoTranscriptionEnabled: transcription.autoTranscribe && transcription.isConfigured,
            onOpenWorkspace: onOpenWorkspace
        )
    }
}

struct AudioRecorderWidget: View {
    @ObservedObject var model: AudioRecorderModel
    var transcription: RecordingTranscriptionManager? = nil
    let autoTranscriptionEnabled: Bool
    let onOpenWorkspace: (URL?) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        let latestURL = model.latestRecordingURL ?? transcription?.recordings.first?.url
        let latestState = latestURL.flatMap { transcription?.state(for: $0) } ?? .idle
        let latestTranscript = latestURL.flatMap { transcription?.transcript(for: $0) }

        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 9) {
                    Text(model.elapsedText)
                        .font(.system(size: 29, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .fixedSize()
                    Spacer(minLength: 0)
                    statusSubtitle(latestURL: latestURL, latestState: latestState, latestTranscript: latestTranscript, theme: theme)
                        .multilineTextAlignment(.trailing)
                }
                AudioMeterView(levels: model.meterLevels, active: model.isRecording)
                    .frame(height: 27)
                    .accessibilityHidden(true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .flowInset(theme)

            ViewThatFits(in: .horizontal) {
                controls(latestURL: latestURL, latestState: latestState, latestTranscript: latestTranscript, compact: false)
                controls(latestURL: latestURL, latestState: latestState, latestTranscript: latestTranscript, compact: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("录音组件")
    }

    private func controls(latestURL: URL?, latestState: RecordingTranscriptionState,
                          latestTranscript: RecordingTranscript?, compact: Bool) -> some View {
        HStack(spacing: 5) {
            Button {
                model.toggleRecording()
            } label: {
                if compact && model.status != .requesting {
                    Image(systemName: primaryButtonSymbol).accessibilityLabel(primaryButtonTitle)
                } else {
                    Label(primaryButtonTitle, systemImage: primaryButtonSymbol)
                }
            }
            .buttonStyle(GlassButtonStyle(kind: .primary, horizontalPadding: 9))
            .fixedSize()
            .disabled(model.status == .requesting)

            if model.isActive {
                Button {
                    model.finish()
                } label: {
                    Label("完成", systemImage: "stop.fill")
                }
                .buttonStyle(GlassButtonStyle(kind: .normal, horizontalPadding: 9))
                .fixedSize()
            }

            if model.canOpenSettings {
                Button("打开系统设置", action: model.openPrivacySettings)
                    .buttonStyle(GlassButtonStyle(kind: .normal, horizontalPadding: 9))
                    .fixedSize()
            } else if !model.isActive {
                Button {
                    onOpenWorkspace(latestURL)
                } label: {
                    if latestState.isTranscribing {
                        Label("查看转写", systemImage: "captions.bubble")
                    } else if latestTranscript != nil {
                        Label("查看字幕", systemImage: "captions.bubble")
                    } else {
                        Label("转写记录", systemImage: "captions.bubble")
                    }
                }
                .buttonStyle(GlassButtonStyle(kind: .normal, horizontalPadding: 9))
                .fixedSize()

                if latestURL != nil {
                    Button(action: model.revealLatestRecording) {
                        if compact {
                            Image(systemName: "folder").accessibilityLabel("在访达中显示录音")
                        } else { Text("访达") }
                    }
                    .buttonStyle(GlassButtonStyle(kind: .quiet))
                    .fixedSize()
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func statusSubtitle(
        latestURL: URL?,
        latestState: RecordingTranscriptionState,
        latestTranscript: RecordingTranscript?,
        theme: ClipFlowTheme
    ) -> some View {
        if model.canOpenSettings || model.status == .unavailable || model.status == .requesting {
            Text(model.statusText).font(.system(size: 11)).foregroundStyle(theme.foregroundSecondary)
        } else if case .failed = model.status {
            Text(model.statusText).font(.system(size: 11)).foregroundStyle(theme.danger)
        } else if model.isRecording {
            Text(autoTranscriptionEnabled ? "正在录音 · 完成后自动转写" : "正在录制麦克风声音")
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(theme.muted)
        } else if model.isPaused {
            Text("已暂停，点继续恢复录音")
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(theme.muted)
        } else if case .transcribing = latestState {
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                Text("正在自动转写演讲人与字幕…")
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(theme.accent)
            }
        } else if case .failed = latestState {
            Text("转写失败，点击查看重试")
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(theme.danger)
        } else if let latestTranscript {
            Text("已转写 · \(latestTranscript.speakers.count) 位演讲人 · \(latestTranscript.segments.count) 条字幕")
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(theme.accent)
        } else if let latestURL {
            Text(latestURL.deletingPathExtension().lastPathComponent)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(theme.muted)
        } else if autoTranscriptionEnabled {
            Text("录音完成后将自动转写字幕")
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(theme.muted)
        } else {
            Text("待机")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.muted)
        }
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
}

private struct AudioMeterView: View {
    let levels: [Double]
    let active: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        GeometryReader { proxy in
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(theme.danger.opacity(active ? 1 : 0.48).gradient)
                        .frame(maxWidth: .infinity)
                        .frame(height: max(3, (proxy.size.height - 2) * level))
                }
            }
            .frame(height: proxy.size.height)
        }
    }
}
