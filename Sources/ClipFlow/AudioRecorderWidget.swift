import AppKit
@preconcurrency import AVFoundation
import SwiftUI

struct SavedRecording: Identifiable, Equatable {
    var id: String { url.path }
    let url: URL
    let name: String
    let createdAt: Date
    let duration: TimeInterval
    let byteSize: Int64

    var durationText: String { AudioRecorderModel.durationText(duration) }

    var relativeTimeText: String {
        let seconds = max(0, Date().timeIntervalSince(createdAt))
        if seconds < 60 { return "刚刚" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600)) 小时前" }
        return createdAt.formatted(.dateTime.month().day().hour().minute().locale(Locale(identifier: "zh_CN")))
    }

    static func loadAll(in directory: URL) -> [SavedRecording] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey
        ]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap { url -> SavedRecording? in
            guard url.pathExtension.lowercased() == "m4a" else { return nil }
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true else { return nil }
            let assetDuration = CMTimeGetSeconds(AVURLAsset(url: url).duration)
            let duration = assetDuration.isFinite ? max(0, assetDuration) : 0
            return SavedRecording(
                url: url,
                name: url.deletingPathExtension().lastPathComponent,
                createdAt: values?.creationDate ?? values?.contentModificationDate ?? Date(),
                duration: duration,
                byteSize: Int64(values?.fileSize ?? 0)
            )
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    static func filter(_ items: [SavedRecording], query: String) -> [SavedRecording] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    static func validatedFileName(_ raw: String) -> Result<String, String> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure("名称不能为空") }
        let invalid = CharacterSet(charactersIn: "/:\\").union(.newlines).union(.controlCharacters)
        guard trimmed.rangeOfCharacter(from: invalid) == nil, trimmed != ".", trimmed != ".." else {
            return .failure("名称包含无效字符")
        }
        return .success(trimmed)
    }
}

@MainActor
final class AudioRecorderModel: NSObject, ObservableObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
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
    @Published private(set) var recordings: [SavedRecording] = []
    @Published private(set) var playingURL: URL?
    @Published private(set) var isPlaybackPaused = false
    @Published var historyQuery = ""
    @Published var historyError: String?
    @Published var selectedRecordingID: String?

    var onWillRevealRecording: (() -> Void)?

    private let customDirectory: URL?
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var meterTimer: Timer?
    private var currentRecordingURL: URL?
    private var operationID = UUID()

    init(recordingsDirectory: URL? = nil) {
        customDirectory = recordingsDirectory
        super.init()
        refreshRecordings()
    }

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

    var elapsedText: String { Self.durationText(elapsedTime) }

    var latestRecordingURL: URL? {
        if case .saved(let url) = status { return url }
        return recordings.first?.url
    }

    var latestRecording: SavedRecording? {
        if case .saved(let url) = status {
            return recordings.first(where: { $0.url == url }) ?? recordings.first
        }
        return recordings.first
    }

    var filteredRecordings: [SavedRecording] {
        SavedRecording.filter(recordings, query: historyQuery)
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
        stopPlayback()
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
        selectedRecordingID = url.path
        refreshRecordings()
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
        guard let recording = latestRecording else { return }
        reveal(recording)
    }

    func reveal(_ recording: SavedRecording) {
        guard FileManager.default.fileExists(atPath: recording.url.path) else {
            historyError = "录音文件已经不存在，请刷新列表"
            refreshRecordings()
            return
        }
        historyError = nil
        onWillRevealRecording?()
        NSWorkspace.shared.activateFileViewerSelecting([recording.url])
    }

    func refreshRecordings() {
        do {
            recordings = SavedRecording.loadAll(in: try recordingsDirectory())
            if let selectedRecordingID, !recordings.contains(where: { $0.id == selectedRecordingID }) {
                self.selectedRecordingID = recordings.first?.id
            } else if selectedRecordingID == nil {
                selectedRecordingID = recordings.first?.id
            }
        } catch {
            recordings = []
            historyError = "无法读取录音目录：\(error.localizedDescription)"
        }
    }

    func isPlaying(_ recording: SavedRecording) -> Bool {
        playingURL == recording.url && player?.isPlaying == true && !isPlaybackPaused
    }

    func toggleLatestPlayback() {
        guard let recording = latestRecording else { return }
        togglePlayback(recording)
    }

    func togglePlayback(_ recording: SavedRecording) {
        guard !isActive else {
            historyError = "请先完成当前录音，再播放历史录音"
            return
        }
        if playingURL == recording.url {
            if isPlaybackPaused || player?.isPlaying != true {
                player?.play()
                isPlaybackPaused = false
            } else {
                player?.pause()
                isPlaybackPaused = true
            }
            historyError = nil
            return
        }
        stopPlayback()
        do {
            let newPlayer = try AVAudioPlayer(contentsOf: recording.url)
            newPlayer.delegate = self
            guard newPlayer.prepareToPlay(), newPlayer.play() else {
                throw RecorderError.couldNotStart
            }
            player = newPlayer
            playingURL = recording.url
            isPlaybackPaused = false
            selectedRecordingID = recording.id
            historyError = nil
        } catch {
            player = nil
            playingURL = nil
            isPlaybackPaused = false
            historyError = "无法播放「\(recording.name)」"
        }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playingURL = nil
        isPlaybackPaused = false
    }

    @discardableResult
    func delete(_ recording: SavedRecording) -> Bool {
        if playingURL == recording.url { stopPlayback() }
        do {
            if FileManager.default.fileExists(atPath: recording.url.path) {
                try FileManager.default.removeItem(at: recording.url)
            }
            if case .saved(let url) = status, url == recording.url {
                status = .idle
            }
            historyError = nil
            refreshRecordings()
            return true
        } catch {
            historyError = "无法删除「\(recording.name)」：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func rename(_ recording: SavedRecording, to rawName: String) -> Bool {
        switch SavedRecording.validatedFileName(rawName) {
        case .failure(let message):
            historyError = message
            return false
        case .success(let name):
            let destination = recording.url
                .deletingLastPathComponent()
                .appendingPathComponent(name)
                .appendingPathExtension("m4a")
            if destination.standardizedFileURL == recording.url.standardizedFileURL {
                historyError = nil
                return true
            }
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                historyError = "已有同名录音"
                return false
            }
            if playingURL == recording.url { stopPlayback() }
            do {
                try FileManager.default.moveItem(at: recording.url, to: destination)
                if case .saved(let url) = status, url == recording.url {
                    status = .saved(destination)
                }
                historyError = nil
                refreshRecordings()
                selectedRecordingID = destination.path
                return true
            } catch {
                historyError = "无法重命名：\(error.localizedDescription)"
                return false
            }
        }
    }

    func copyPath(_ recording: SavedRecording) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recording.url.path, forType: .string)
        historyError = nil
    }

    static func durationText(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time.rounded(.down)))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
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
        if let customDirectory {
            try FileManager.default.createDirectory(
                at: customDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            return customDirectory
        }
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

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.stopPlayback()
        }
    }

    private enum RecorderError: Error {
        case couldNotStart
        case missingApplicationSupport
    }
}

struct AudioRecorderWidget: View {
    @ObservedObject var model: AudioRecorderModel
    var onOpenHistory: () -> Void = {}
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
                } else {
                    if model.latestRecording != nil, !model.isActive {
                        Button(model.isPlayingLatest ? "暂停" : "播放") {
                            model.toggleLatestPlayback()
                        }
                        .buttonStyle(GlassButtonStyle(kind: .quiet))
                        .fixedSize()
                        .disabled(model.isActive)
                        .accessibilityLabel(model.isPlayingLatest ? "暂停播放最近录音" : "播放最近录音")
                    }
                    Button("历史录音", action: onOpenHistory)
                        .buttonStyle(GlassButtonStyle(kind: .quiet))
                        .fixedSize()
                        .accessibilityHint(model.recordings.isEmpty ? "查看已保存的录音" : "已保存 \(model.recordings.count) 条录音")
                }

                Spacer(minLength: 0)
            }
        }
        .frame(minHeight: 96)
        .onAppear { model.refreshRecordings() }
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
        if let recording = model.latestRecording { return recording.name }
        return nil
    }
}

private extension AudioRecorderModel {
    var isPlayingLatest: Bool {
        guard let latestRecording else { return false }
        return isPlaying(latestRecording)
    }
}

struct RecordingHistoryOverlay: View {
    @ObservedObject var model: AudioRecorderModel
    let onClose: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var searchFocused: Bool
    @State private var deleteArmed = false
    @State private var renamingID: String?
    @State private var draftName = ""

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .onTapGesture(perform: close)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("历史录音")
                            .font(.system(size: 14, weight: .semibold))
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.muted)
                    }
                    Spacer()
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(GlassButtonStyle(kind: .quiet, horizontalPadding: 0))
                    .accessibilityLabel("关闭历史录音")
                }
                .padding(.horizontal, 14)
                .frame(height: 58)

                Divider().overlay(theme.hairline)

                searchBar(theme)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                if let error = model.historyError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }

                if model.recordings.isEmpty {
                    emptyState("还没有历史录音", detail: "完成一次录音后，就会出现在这里。文件只保存在本机。", theme: theme)
                } else if model.filteredRecordings.isEmpty {
                    emptyState("没有匹配的录音", detail: "试试其他名称，或清空搜索。", theme: theme)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(model.filteredRecordings) { recording in
                                recordingRow(recording, theme: theme)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                    }
                }
            }
            .frame(width: 560, height: 460)
            .foregroundStyle(theme.foreground)
            .background(VisualEffectBackground())
            .background(theme.glass.opacity(0.98))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(theme.hairline, lineWidth: 0.7))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.56), radius: 34, y: 20)
            .onTapGesture { }
        }
        .onAppear {
            deleteArmed = false
            renamingID = nil
            model.refreshRecordings()
        }
        .onChange(of: model.selectedRecordingID) { _ in
            deleteArmed = false
            if renamingID != model.selectedRecordingID { renamingID = nil }
        }
    }

    private var subtitle: String {
        if model.recordings.isEmpty { return "仅保存在本机" }
        if model.historyQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(model.recordings.count) 条 · 仅保存在本机"
        }
        return "\(model.filteredRecordings.count) / \(model.recordings.count) 条 · 仅保存在本机"
    }

    private func searchBar(_ theme: ClipFlowTheme) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(theme.muted)
            TextField("搜索录音名称…", text: $model.historyQuery)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel("搜索历史录音")
            if !model.historyQuery.isEmpty {
                Button {
                    model.historyQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空录音搜索")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(searchFocused ? theme.foreground.opacity(0.28) : .clear))
    }

    private func recordingRow(_ recording: SavedRecording, theme: ClipFlowTheme) -> some View {
        let selected = model.selectedRecordingID == recording.id
        let playing = model.isPlaying(recording)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    model.selectedRecordingID = recording.id
                    model.togglePlayback(recording)
                } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(GlassButtonStyle(kind: playing ? .primary : .normal, horizontalPadding: 0))
                .disabled(model.isActive)
                .accessibilityLabel(playing ? "暂停 \(recording.name)" : "播放 \(recording.name)")

                VStack(alignment: .leading, spacing: 3) {
                    if renamingID == recording.id {
                        TextField("录音名称", text: $draftName, onCommit: { commitRename(recording) })
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5, weight: .medium))
                            .accessibilityLabel("录音名称")
                    } else {
                        Text(recording.name)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                    }
                    Text("\(recording.durationText) · \(recording.relativeTimeText) · \(ByteCountFormatter.string(fromByteCount: recording.byteSize, countStyle: .file))")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    deleteArmed = false
                    model.selectedRecordingID = recording.id
                }

                if selected && renamingID != recording.id {
                    Button("在访达中显示") { model.reveal(recording) }
                        .buttonStyle(GlassButtonStyle(kind: .quiet))
                        .fixedSize()
                    Button(deleteArmed ? "确认删除" : "删除") {
                        if deleteArmed {
                            _ = model.delete(recording)
                            deleteArmed = false
                        } else {
                            deleteArmed = true
                        }
                    }
                    .buttonStyle(GlassButtonStyle(kind: deleteArmed ? .danger : .normal))
                    .fixedSize()
                    .accessibilityHint("点击后需要再次确认")
                }
            }

            if selected && renamingID == recording.id {
                HStack {
                    Spacer()
                    Button("取消") { renamingID = nil }
                        .buttonStyle(GlassButtonStyle(kind: .quiet))
                    Button("保存") { commitRename(recording) }
                        .buttonStyle(GlassButtonStyle(kind: .primary))
                }
            }
        }
        .padding(8)
        .background(selected ? theme.selection : theme.chip)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contextMenu {
            Button(playing ? "暂停" : "播放") { model.togglePlayback(recording) }
                .disabled(model.isActive)
            Button("在访达中显示") { model.reveal(recording) }
            Button("复制路径") { model.copyPath(recording) }
            Button("重命名") { beginRename(recording) }
            Divider()
            Button("删除", role: .destructive) {
                model.selectedRecordingID = recording.id
                deleteArmed = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func emptyState(_ title: String, detail: String, theme: ClipFlowTheme) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 28))
                .foregroundStyle(theme.muted)
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func beginRename(_ recording: SavedRecording) {
        model.selectedRecordingID = recording.id
        draftName = recording.name
        renamingID = recording.id
        deleteArmed = false
    }

    private func commitRename(_ recording: SavedRecording) {
        if model.rename(recording, to: draftName) {
            renamingID = nil
        }
    }

    private func close() {
        renamingID = nil
        deleteArmed = false
        onClose()
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
