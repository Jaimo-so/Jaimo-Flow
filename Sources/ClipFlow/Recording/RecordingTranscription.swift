import AppKit
import AVFoundation
import ClipFlowKit
import SwiftUI

private extension RecordingASRProvider {
    var credentialIDKey: String { self == .qwen ? "recordingASRCredentialID" : "recordingASROpenAICredentialID" }
    var baseURLKey: String { self == .qwen ? "recordingASRBaseURL" : "recordingASROpenAIBaseURL" }
    var modelKey: String { self == .qwen ? "recordingASRModel" : "recordingASROpenAIModel" }
}

struct RecordingItem: Identifiable, Equatable {
    let url: URL
    let createdAt: Date
    let duration: TimeInterval

    var id: URL { url }

    var displayTitle: String {
        let stem = url.deletingPathExtension().lastPathComponent
        let prefix = "Jaimo Flow 录音 "
        if stem.hasPrefix(prefix) {
            return String(stem.dropFirst(prefix.count))
        }
        return stem
    }

    var durationText: String {
        RecordingTranscript.formatTimestamp(duration)
    }
}

enum RecordingTranscriptionState: Equatable {
    case idle
    case transcribing(String)
    case completed
    case failed(String)

    var isTranscribing: Bool {
        if case .transcribing = self { return true }
        return false
    }
}

@MainActor
final class RecordingPlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var currentURL: URL?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var playbackRate: Float = 1.0

    static let supportedRates: [Float] = [1.0, 1.25, 1.5, 2.0]

    private var player: AVAudioPlayer?
    private var loadedURL: URL?
    private var progressTimer: Timer?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0

    /// Instant, zero-I/O selection update when switching recordings in the list.
    func select(_ url: URL, duration knownDuration: TimeInterval) {
        if currentURL == url {
            if duration <= 0, knownDuration > 0 { duration = knownDuration }
            return
        }
        stop()
        currentURL = url
        duration = max(0, knownDuration)
        currentTime = 0
    }

    func togglePlayPause(for url: URL) {
        if loadedURL == url, let player {
            if player.isPlaying {
                player.pause()
                isPlaying = false
                stopTimer()
                currentTime = player.currentTime
            } else {
                player.rate = playbackRate
                if player.currentTime >= max(0, player.duration - 0.1) {
                    player.currentTime = 0
                    currentTime = 0
                }
                if player.play() {
                    isPlaying = true
                    startTimer()
                }
            }
            return
        }

        let startAt = currentURL == url ? currentTime : 0
        loadAsync(url: url, seekTo: startAt, autoPlay: true)
    }

    func seek(to time: TimeInterval, for url: URL, autoPlay: Bool = false) {
        if loadedURL == url, let player {
            let clamped = min(max(0, time), max(0, player.duration))
            player.currentTime = clamped
            currentTime = clamped
            if autoPlay && !player.isPlaying {
                player.rate = playbackRate
                if player.play() {
                    isPlaying = true
                    startTimer()
                }
            }
            return
        }

        currentURL = url
        currentTime = max(0, time)
        if autoPlay {
            loadAsync(url: url, seekTo: max(0, time), autoPlay: true)
        }
    }

    func setRate(_ rate: Float) {
        playbackRate = rate
        if let player {
            player.rate = rate
        }
    }

    func stop() {
        loadGeneration += 1
        loadTask?.cancel()
        loadTask = nil
        stopTimer()
        player?.stop()
        player = nil
        loadedURL = nil
        isPlaying = false
        currentTime = 0
    }

    func reset() {
        stop()
        currentURL = nil
        duration = 0
    }

    private func loadAsync(url: URL, seekTo targetTime: TimeInterval, autoPlay: Bool) {
        loadGeneration += 1
        let generation = loadGeneration
        loadTask?.cancel()
        stopTimer()
        player?.stop()
        player = nil
        loadedURL = nil
        isPlaying = false
        currentURL = url
        currentTime = max(0, targetTime)

        loadTask = Task { [weak self] in
            let prepared: AVAudioPlayer? = await Task.detached(priority: .userInitiated) {
                guard let newPlayer = try? AVAudioPlayer(contentsOf: url) else { return nil }
                newPlayer.enableRate = true
                newPlayer.prepareToPlay()
                return newPlayer
            }.value

            guard let self, self.loadGeneration == generation, !Task.isCancelled else { return }
            guard let newPlayer = prepared else {
                self.isPlaying = false
                return
            }
            newPlayer.delegate = self
            newPlayer.rate = self.playbackRate
            self.player = newPlayer
            self.loadedURL = url
            self.duration = newPlayer.duration
            let clamped = min(max(0, targetTime), max(0, newPlayer.duration))
            newPlayer.currentTime = clamped
            self.currentTime = clamped
            if autoPlay {
                if clamped >= max(0, newPlayer.duration - 0.1) {
                    newPlayer.currentTime = 0
                    self.currentTime = 0
                }
                if newPlayer.play() {
                    self.isPlaying = true
                    self.startTimer()
                }
            }
        }
    }

    private func startTimer() {
        stopTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying {
                    self.isPlaying = false
                    self.stopTimer()
                }
            }
        }
    }

    private func stopTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPlaying = false
            self.stopTimer()
            self.currentTime = self.duration
        }
    }
}

@MainActor
final class RecordingTranscriptionManager: ObservableObject {
    @Published var provider: RecordingASRProvider = .qwen
    @Published var baseURL = ""
    @Published var model = ""
    @Published var key = ""
    @Published var autoTranscribe: Bool = true
    @Published var settingsMessage: String?
    @Published var settingsError: String?
    @Published var showingSettings = false

    @Published private(set) var recordings: [RecordingItem] = []
    @Published var selectedRecordingURL: URL?
    @Published private(set) var states: [URL: RecordingTranscriptionState] = [:]
    @Published private(set) var transcripts: [URL: RecordingTranscript] = [:]

    let playback = RecordingPlaybackController()

    private let credentials: CredentialStore
    private let defaults: UserDefaults
    private let directoryOverride: URL?
    var canDeleteRecording: ((URL) -> Bool)?
    var onRecordingDeleted: ((URL, URL?) -> Void)?
    private var taskIDs: [URL: UUID] = [:]
    private var activeTasks: [URL: Task<Void, Never>] = [:]
    private var reloadTask: Task<Void, Never>?
    private var durationCache: [URL: (modified: Date, duration: TimeInterval)] = [:]

    private static let providerKey = "recordingASRProvider"
    private static let autoTranscribeKey = "recordingASRAutoTranscribe"

    var hasKey: Bool { defaults.string(forKey: provider.credentialIDKey) != nil }
    var isConfigured: Bool { hasKey && Self.hasUsableModel(model) }

    var serviceSummary: String {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(provider.title) · \(trimmedModel.isEmpty ? provider.defaultModel : trimmedModel)"
    }

    var selectedRecording: RecordingItem? {
        guard let selectedRecordingURL else { return recordings.first }
        return recordings.first { $0.url == selectedRecordingURL } ?? recordings.first
    }

    var activeTranscriptionCount: Int {
        states.values.filter(\.isTranscribing).count
    }

    init(
        defaults: UserDefaults = .standard,
        credentialService: String = "com.clipflow.mac.recording-asr",
        recordingsDirectory: URL? = nil
    ) {
        self.defaults = defaults
        self.directoryOverride = recordingsDirectory
        self.credentials = CredentialStore(service: credentialService)
        provider = Self.storedProvider(in: defaults)
        autoTranscribe = Self.storedAutoTranscribe(in: defaults)
        loadSettings()
        reloadRecordings()
    }

    static func shouldAutoTranscribe(defaults: UserDefaults) -> Bool {
        guard storedAutoTranscribe(in: defaults) else { return false }
        let provider = storedProvider(in: defaults)
        return defaults.string(forKey: provider.credentialIDKey) != nil
            && hasUsableModel(defaults.string(forKey: provider.modelKey) ?? provider.defaultModel)
    }

    private static func storedProvider(in defaults: UserDefaults) -> RecordingASRProvider {
        defaults.string(forKey: providerKey).flatMap(RecordingASRProvider.init(rawValue:)) ?? .qwen
    }

    private static func storedAutoTranscribe(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: autoTranscribeKey) == nil || defaults.bool(forKey: autoTranscribeKey)
    }

    private static func hasUsableModel(_ model: String) -> Bool {
        !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func loadSettings() {
        baseURL = defaults.string(forKey: provider.baseURLKey) ?? provider.defaultURL
        model = defaults.string(forKey: provider.modelKey) ?? provider.defaultModel
        key = ""
        settingsError = nil
        settingsMessage = nil
    }

    @discardableResult
    func saveSettings() -> Bool {
        do {
            _ = try RecordingASRRequest.endpoint(baseURL: baseURL, provider: provider)
            let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedModel.isEmpty else {
                throw RecordingASRError.message("请填写模型名称。")
            }
            let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedKey.isEmpty {
                guard trimmedKey.rangeOfCharacter(from: .newlines) == nil else {
                    throw RecordingASRError.message("API Key 不能包含换行。")
                }
                let id = try credentials.save(
                    id: defaults.string(forKey: provider.credentialIDKey),
                    title: "录音转写 API Key - " + provider.title,
                    secret: trimmedKey
                )
                defaults.set(id, forKey: provider.credentialIDKey)
                key = ""
            }
            defaults.set(baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: provider.baseURLKey)
            defaults.set(trimmedModel, forKey: provider.modelKey)
            defaults.set(provider.rawValue, forKey: Self.providerKey)
            defaults.set(autoTranscribe, forKey: Self.autoTranscribeKey)
            settingsError = nil
            settingsMessage = "设置已保存"
            return true
        } catch {
            settingsMessage = nil
            settingsError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    func reloadRecordings() {
        reloadTask?.cancel()
        let directoryOverride = self.directoryOverride
        let cachedDurations = durationCache
        let existingTranscriptKeys = Set(transcripts.keys)

        reloadTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let scanned = await Task.detached(priority: .userInitiated) { () -> ([RecordingItem], [URL: (Date, TimeInterval)], [URL: RecordingTranscript]) in
                guard let directory = directoryOverride ?? (try? Self.recordingsDirectory()),
                      let files = try? FileManager.default.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey]
                      ) else {
                    return ([], [:], [:])
                }

                let audioFiles = files
                    .filter { $0.pathExtension.lowercased() == "m4a" }
                    .sorted { $0.lastPathComponent > $1.lastPathComponent }

                var items: [RecordingItem] = []
                var newDurations: [URL: (Date, TimeInterval)] = [:]
                var loadedTranscripts: [URL: RecordingTranscript] = [:]

                for url in audioFiles {
                    if Task.isCancelled { return ([], [:], [:]) }
                    let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                    let createdAt = values?.creationDate ?? values?.contentModificationDate ?? Date()
                    let modifiedAt = values?.contentModificationDate ?? createdAt

                    let safeDuration: TimeInterval
                    if let cached = cachedDurations[url], cached.modified == modifiedAt {
                        safeDuration = cached.duration
                    } else {
                        let loaded = await Self.loadDuration(for: url) ?? 0
                        safeDuration = loaded
                    }
                    newDurations[url] = (modifiedAt, safeDuration)
                    items.append(RecordingItem(url: url, createdAt: createdAt, duration: safeDuration))

                    if !existingTranscriptKeys.contains(url),
                       let loaded = Self.loadTranscriptFromDisk(for: url, fallbackDuration: safeDuration) {
                        loadedTranscripts[url] = loaded
                    }
                }
                return (items, newDurations, loadedTranscripts)
            }.value

            guard let self, !Task.isCancelled else { return }
            let (items, newDurations, loadedTranscripts) = scanned
            self.durationCache = newDurations
            for (url, transcript) in loadedTranscripts {
                self.transcripts[url] = transcript
                if self.states[url] == nil || self.states[url] == .idle {
                    self.states[url] = .completed
                }
            }
            for item in items where self.states[item.url] == nil {
                self.states[item.url] = self.transcripts[item.url] != nil ? .completed : .idle
            }
            self.recordings = items
            if let selected = self.selectedRecordingURL, !items.contains(where: { $0.url == selected }) {
                self.selectedRecordingURL = items.first?.url
            } else if self.selectedRecordingURL == nil {
                self.selectedRecordingURL = items.first?.url
            }
            if let selected = self.selectedRecording {
                self.playback.select(selected.url, duration: selected.duration)
            }
        }
    }

    func handleNewRecording(_ url: URL) {
        selectedRecordingURL = url
        reloadRecordings()
        if autoTranscribe && isConfigured {
            transcribe(url)
        }
    }

    func state(for url: URL) -> RecordingTranscriptionState {
        if let state = states[url] { return state }
        if transcripts[url] != nil { return .completed }
        return .idle
    }

    /// Pure O(1) memory lookup — never performs disk I/O during SwiftUI view updates.
    func transcript(for url: URL) -> RecordingTranscript? {
        transcripts[url]
    }

    func selectRecording(_ url: URL) {
        if selectedRecordingURL != url {
            selectedRecordingURL = url
        }
        let knownDuration = recordings.first(where: { $0.url == url })?.duration ?? 0
        playback.select(url, duration: knownDuration)
    }

    func transcribe(_ url: URL) {
        guard !state(for: url).isTranscribing else { return }
        guard saveSettings() else {
            states[url] = .failed(settingsError ?? "请检查转写设置。")
            return
        }
        guard let id = defaults.string(forKey: provider.credentialIDKey) else {
            states[url] = .failed("请先配置当前服务的 API Key。")
            showingSettings = true
            return
        }

        let apiKey: String
        do {
            apiKey = try credentials.secret(id: id)
        } catch {
            states[url] = .failed("无法从钥匙串读取 API Key，请重新填写保存。")
            showingSettings = true
            return
        }

        let address = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedProvider = provider
        let modelName = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackDuration = recordings.first(where: { $0.url == url })?.duration ?? 0

        activeTasks[url]?.cancel()
        states[url] = .transcribing("正在处理音频…")

        let taskID = UUID()
        taskIDs[url] = taskID
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let totalDuration = await Self.loadDuration(for: url) ?? (fallbackDuration.isFinite && fallbackDuration > 0 ? fallbackDuration : 0)
                let chunkRanges = try Self.planChunks(for: url, provider: selectedProvider, duration: totalDuration)
                var mergedTranscripts: [(offset: TimeInterval, transcript: RecordingTranscript)] = []

                for (index, range) in chunkRanges.enumerated() {
                    try Task.checkCancellation()
                    let chunkLabel = chunkRanges.count > 1
                        ? "第 \(index + 1)/\(chunkRanges.count) 段（\(RecordingTranscript.formatTimestamp(range.start)) – \(RecordingTranscript.formatTimestamp(range.end))）"
                        : ""
                    self.states[url] = .transcribing(chunkRanges.count > 1 ? "正在准备\(chunkLabel)…" : "正在处理音频…")

                    let (chunkURL, isTemp) = try await Self.prepareChunkFile(
                        sourceURL: url,
                        range: range,
                        isSingleWholeFile: chunkRanges.count == 1
                    )
                    defer {
                        if isTemp { try? FileManager.default.removeItem(at: chunkURL) }
                    }

                    let audio = try await Task.detached { () throws -> Data in
                        try Task.checkCancellation()
                        if selectedProvider == .qwen {
                            return try Self.convertForQwen(chunkURL)
                        }
                        let size = try chunkURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size > 0, size < 25_000_000 else {
                            throw RecordingASRError.message("单段音频超过 OpenAI 兼容接口的 25 MB 限制；原录音仍保存在本机。")
                        }
                        return try Data(contentsOf: chunkURL)
                    }.value

                    try Task.checkCancellation()
                    self.states[url] = .transcribing(
                        chunkRanges.count > 1
                            ? "正在转写\(chunkLabel)…"
                            : "正在上传并识别演讲人与字幕…"
                    )

                    let data = try await self.performASRRequest(
                        provider: selectedProvider,
                        baseURL: address,
                        model: modelName,
                        apiKey: apiKey,
                        audio: audio
                    )

                    try Task.checkCancellation()
                    let chunkDuration = max(0, range.end - range.start)
                    let chunkTranscript = try RecordingASRRequest.decodeTranscript(
                        data,
                        provider: selectedProvider,
                        model: modelName,
                        fallbackDuration: chunkDuration
                    )
                    mergedTranscripts.append((offset: range.start, transcript: chunkTranscript))
                }

                let finalTranscript = Self.mergeChunkTranscripts(
                    mergedTranscripts,
                    provider: selectedProvider.rawValue,
                    model: modelName,
                    totalDuration: totalDuration
                )

                try Task.checkCancellation()
                guard self.taskIDs[url] == taskID else { return }
                try Self.saveTranscriptToDisk(finalTranscript, for: url)
                self.transcripts[url] = finalTranscript
                self.states[url] = .completed
            } catch is CancellationError {
                guard self.taskIDs[url] == taskID else { return }
                self.states[url] = self.transcripts[url] != nil ? .completed : .idle
            } catch {
                guard self.taskIDs[url] == taskID else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.states[url] = .failed(message)
            }
            self.activeTasks[url] = nil
            self.taskIDs[url] = nil
        }

        activeTasks[url] = task
    }

    func cancelTranscription(for url: URL) {
        taskIDs[url] = nil
        activeTasks[url]?.cancel()
        activeTasks[url] = nil
        states[url] = transcripts[url] != nil ? .completed : .idle
    }

    func shutdown() {
        reloadTask?.cancel()
        reloadTask = nil
        for url in Array(activeTasks.keys) {
            cancelTranscription(for: url)
        }
        playback.reset()
        showingSettings = false
    }

    func renameSpeaker(in url: URL, speakerID: String, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var transcript = transcripts[url] else { return }
        guard let idx = transcript.speakers.firstIndex(where: { $0.id == speakerID }) else { return }
        transcript.speakers[idx].name = trimmed
        persistUpdatedTranscript(transcript, for: url)
    }

    @discardableResult
    func addSpeaker(in url: URL, name: String? = nil) -> RecordingSpeaker? {
        guard var transcript = transcripts[url] else { return nil }
        let nextIndex = transcript.speakers.count
        let resolvedName: String
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            resolvedName = "演讲人 \(nextIndex + 1)"
        }
        let speaker = RecordingSpeaker(
            id: "speaker_\(UUID().uuidString.prefix(8))",
            name: resolvedName,
            colorIndex: nextIndex
        )
        transcript.speakers.append(speaker)
        persistUpdatedTranscript(transcript, for: url)
        return speaker
    }

    func reassignSpeaker(in url: URL, segmentID: UUID, speakerID: String) {
        guard var transcript = transcripts[url],
              transcript.speakers.contains(where: { $0.id == speakerID }),
              let idx = transcript.segments.firstIndex(where: { $0.id == segmentID }) else { return }
        transcript.segments[idx].speakerID = speakerID
        persistUpdatedTranscript(transcript, for: url)
    }

    func updateSegmentText(in url: URL, segmentID: UUID, text: String) {
        guard var transcript = transcripts[url],
              let idx = transcript.segments.firstIndex(where: { $0.id == segmentID }),
              transcript.segments[idx].text != text else { return }
        transcript.segments[idx].text = text
        persistUpdatedTranscript(transcript, for: url)
    }

    func deleteRecording(_ url: URL) throws {
        guard canDeleteRecording?(url) != false else {
            throw RecordingASRError.message("这条录音正在录制或暂停中，请先完成录音。")
        }
        reloadTask?.cancel()
        cancelTranscription(for: url)
        if playback.currentURL == url { playback.reset() }

        var failures: [String] = []
        for file in [Self.transcriptJSONURL(for: url), Self.plainTextURL(for: url), url] {
            if file == url && !failures.isEmpty { break }
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            do { try FileManager.default.removeItem(at: file) }
            catch { failures.append(file.lastPathComponent) }
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            transcripts.removeValue(forKey: url)
            states.removeValue(forKey: url)
            durationCache.removeValue(forKey: url)
            recordings.removeAll { $0.url == url }
            if selectedRecordingURL == url { selectedRecordingURL = recordings.first?.url }
            onRecordingDeleted?(url, recordings.first?.url)
        }
        reloadRecordings()
        if !failures.isEmpty {
            throw RecordingASRError.message("部分文件未能删除：\(failures.joined(separator: "、"))。请检查文件权限后重试。")
        }
    }

    private func persistUpdatedTranscript(_ transcript: RecordingTranscript, for url: URL) {
        transcripts[url] = transcript
        try? Self.saveTranscriptToDisk(transcript, for: url)
    }

    private func performASRRequest(
        provider: RecordingASRProvider,
        baseURL: String,
        model: String,
        apiKey: String,
        audio: Data
    ) async throws -> Data {
        let session = URLSession(configuration: .ephemeral)
        let primaryRequest = try RecordingASRRequest.make(
            provider: provider,
            baseURL: baseURL,
            model: model,
            apiKey: apiKey,
            audio: audio
        )
        let (data, response) = try await session.data(for: primaryRequest)
        guard let http = response as? HTTPURLResponse else {
            throw RecordingASRError.message("服务返回无效响应。")
        }
        if (200..<300).contains(http.statusCode) {
            return data
        }

        // Some OpenAI-compatible relays do not support diarized_json / verbose_json
        // and return HTTP 400/422/500. Fall back once to standard json response.
        var finalStatus = http.statusCode
        var finalData = data
        if provider == .openAI && (http.statusCode == 400 || http.statusCode == 422 || http.statusCode == 500) {
            let fallbackRequest = try RecordingASRRequest.make(
                provider: provider,
                baseURL: baseURL,
                model: model,
                apiKey: apiKey,
                audio: audio,
                responseFormat: .plainJSON
            )
            let (fallbackData, fallbackResponse) = try await session.data(for: fallbackRequest)
            if let fallbackHTTP = fallbackResponse as? HTTPURLResponse {
                if (200..<300).contains(fallbackHTTP.statusCode) {
                    return fallbackData
                }
                finalStatus = fallbackHTTP.statusCode
                finalData = fallbackData
            }
        }

        let detail = Self.extractServerErrorMessage(from: finalData)
        var message = "转写请求失败（HTTP \(finalStatus)）"
        if let detail, !detail.isEmpty {
            message += "：\(detail)"
        } else {
            message += "，请检查接口地址、API Key、模型权限及额度。"
        }
        if provider == .openAI && model.lowercased().contains("qwen") {
            message += "（提示：qwen3-asr 模型通常需在设置中切换为「阿里云 Qwen3-ASR」协议）"
        }
        throw RecordingASRError.message(message)
    }

    nonisolated static func extractServerErrorMessage(from data: Data) -> String? {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let errorObj = obj["error"] as? [String: Any],
               let msg = errorObj["message"] as? String,
               !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return String(msg.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
            }
            if let msg = obj["message"] as? String,
               !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return String(msg.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
            }
            if let msg = obj["error"] as? String,
               !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return String(msg.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
            }
        }
        if let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty, !raw.hasPrefix("<") {
            return String(raw.prefix(160))
        }
        return nil
    }

    struct AudioChunkRange: Equatable {
        let start: TimeInterval
        let end: TimeInterval
    }

    nonisolated static func loadDuration(for url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        guard let cmDuration = try? await asset.load(.duration) else { return nil }
        let seconds = cmDuration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    nonisolated static func planChunks(
        for url: URL,
        provider: RecordingASRProvider,
        duration: TimeInterval
    ) throws -> [AudioChunkRange] {
        let safeDuration = duration.isFinite && duration > 0 ? duration : 0
        if provider == .qwen {
            let maxChunkSeconds: TimeInterval = 240
            guard safeDuration > maxChunkSeconds else {
                return [AudioChunkRange(start: 0, end: safeDuration)]
            }
            return buildChunkRanges(totalDuration: safeDuration, chunkSeconds: maxChunkSeconds)
        } else {
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if fileSize < 24_000_000 || safeDuration <= 0 {
                return [AudioChunkRange(start: 0, end: safeDuration)]
            }
            let maxChunkSeconds: TimeInterval = 600
            return buildChunkRanges(totalDuration: safeDuration, chunkSeconds: maxChunkSeconds)
        }
    }

    nonisolated static func buildChunkRanges(totalDuration: TimeInterval, chunkSeconds: TimeInterval) -> [AudioChunkRange] {
        guard totalDuration > 0, chunkSeconds > 0 else {
            return [AudioChunkRange(start: 0, end: max(0, totalDuration))]
        }
        var ranges: [AudioChunkRange] = []
        var cursor: TimeInterval = 0
        while cursor < totalDuration {
            let end = min(totalDuration, cursor + chunkSeconds)
            ranges.append(AudioChunkRange(start: cursor, end: end))
            if end >= totalDuration { break }
            cursor = end
        }
        return ranges
    }

    nonisolated static func prepareChunkFile(
        sourceURL: URL,
        range: AudioChunkRange,
        isSingleWholeFile: Bool
    ) async throws -> (URL, Bool) {
        if isSingleWholeFile {
            return (sourceURL, false)
        }
        let asset = AVURLAsset(url: sourceURL)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw RecordingASRError.message("无法初始化长录音分段导出器。")
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("jaimo-chunk-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: range.start, preferredTimescale: 600),
            duration: CMTime(seconds: max(0.1, range.end - range.start), preferredTimescale: 600)
        )
        await exporter.export()
        guard exporter.status == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            throw RecordingASRError.message("长录音分段导出失败：\(exporter.error?.localizedDescription ?? "未知错误")")
        }
        return (outputURL, true)
    }

    nonisolated static func mergeChunkTranscripts(
        _ chunks: [(offset: TimeInterval, transcript: RecordingTranscript)],
        provider: String,
        model: String,
        totalDuration: TimeInterval
    ) -> RecordingTranscript {
        if chunks.count == 1, chunks[0].offset == 0 {
            return chunks[0].transcript
        }
        var speakers: [RecordingSpeaker] = []
        var speakerNameToID: [String: String] = [:]
        var segments: [RecordingTranscriptSegment] = []

        for (offset, chunk) in chunks {
            var localIDToMergedID: [String: String] = [:]
            for speaker in chunk.speakers {
                if let existingID = speakerNameToID[speaker.name] {
                    localIDToMergedID[speaker.id] = existingID
                } else {
                    let newID = "speaker_\(speakers.count + 1)"
                    speakers.append(RecordingSpeaker(id: newID, name: speaker.name, colorIndex: speakers.count))
                    speakerNameToID[speaker.name] = newID
                    localIDToMergedID[speaker.id] = newID
                }
            }
            for segment in chunk.segments {
                let mappedSpeakerID = localIDToMergedID[segment.speakerID] ?? speakers.first?.id ?? "speaker_1"
                segments.append(
                    RecordingTranscriptSegment(
                        speakerID: mappedSpeakerID,
                        startTime: segment.startTime + offset,
                        endTime: segment.endTime + offset,
                        text: segment.text
                    )
                )
            }
        }

        if speakers.isEmpty {
            speakers = [RecordingSpeaker(id: "speaker_1", name: "演讲人 1", colorIndex: 0)]
        }
        let resolvedDuration = max(totalDuration, segments.last?.endTime ?? 0)
        return RecordingTranscript(
            provider: provider,
            model: model,
            duration: resolvedDuration,
            createdAt: Date(),
            speakers: speakers,
            segments: segments
        )
    }

    nonisolated static func convertForQwen(_ url: URL) throws -> Data {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "WAVE", "-d", "UI8@16000", "-c", "1", url.path, output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RecordingASRError.message("音频转换失败，原录音仍保存在本机。") }
        let data = try Data(contentsOf: output)
        guard ((data.count + 2) / 3 * 4) <= 10_000_000 else { throw RecordingASRError.message("单段音频编码后超过服务的 10 MB 限制。") }
        return data
    }

    nonisolated static func transcriptJSONURL(for recordingURL: URL) -> URL {
        recordingURL.deletingPathExtension().appendingPathExtension("transcript.json")
    }

    nonisolated static func plainTextURL(for recordingURL: URL) -> URL {
        recordingURL.deletingPathExtension().appendingPathExtension("txt")
    }

    nonisolated static func saveTranscriptToDisk(_ transcript: RecordingTranscript, for recordingURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(transcript)
        try jsonData.write(to: transcriptJSONURL(for: recordingURL), options: .atomic)
        try transcript.formattedTextWithSpeakers.write(
            to: plainTextURL(for: recordingURL),
            atomically: true,
            encoding: .utf8
        )
    }

    nonisolated static func loadTranscriptFromDisk(for recordingURL: URL, fallbackDuration: TimeInterval) -> RecordingTranscript? {
        let jsonURL = transcriptJSONURL(for: recordingURL)
        if let data = try? Data(contentsOf: jsonURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode(RecordingTranscript.self, from: data) {
                return decoded
            }
        }
        let txtURL = plainTextURL(for: recordingURL)
        if let legacyText = try? String(contentsOf: txtURL, encoding: .utf8),
           !legacyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return RecordingTranscript.fromPlainText(
                legacyText,
                provider: "legacy",
                model: "legacy",
                duration: fallbackDuration
            )
        }
        return nil
    }

    nonisolated static func recordingsDirectory() throws -> URL {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw RecordingASRError.message("无法访问应用支持目录。")
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
}
