@testable import ClipFlow
import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

let audio = Data([0, 1, 2, 255])

// 1. OpenAI whisper-1 -> verbose_json
let openAI = try RecordingASRRequest.make(provider: .openAI, baseURL: "https://example.com/v1", model: "whisper-1", apiKey: "secret", audio: audio)
check(openAI.url?.absoluteString == "https://example.com/v1/audio/transcriptions", "OpenAI URL")
check(openAI.value(forHTTPHeaderField: "Authorization") == "Bearer secret", "Authorization")
let contentType = openAI.value(forHTTPHeaderField: "Content-Type") ?? ""
check(contentType.hasPrefix("multipart/form-data; boundary="), "multipart content type")
let body = openAI.httpBody!
check(body.range(of: Data("name=\"model\"\r\n\r\nwhisper-1\r\n".utf8)) != nil, "model part")
check(body.range(of: Data("name=\"response_format\"\r\n\r\nverbose_json\r\n".utf8)) != nil, "verbose_json response format")
check(body.range(of: Data("name=\"file\"; filename=\"recording.m4a\"".utf8)) != nil, "file part")
check(body.range(of: audio) != nil, "audio bytes")

let openText = try RecordingASRRequest.decode(Data("{\"text\":\"测试文字\"}".utf8), provider: .openAI)
check(openText == "测试文字", "OpenAI plain text response")

// 2. OpenAI gpt-4o-transcribe-diarize -> diarized_json + chunking_strategy
let diarizeReq = try RecordingASRRequest.make(provider: .openAI, baseURL: "https://example.com/v1", model: "gpt-4o-transcribe-diarize", apiKey: "secret", audio: audio)
let diarizeBody = diarizeReq.httpBody!
check(diarizeBody.range(of: Data("name=\"response_format\"\r\n\r\ndiarized_json\r\n".utf8)) != nil, "diarized_json response format")
check(diarizeBody.range(of: Data("name=\"chunking_strategy\"\r\n\r\nauto\r\n".utf8)) != nil, "chunking_strategy auto")

let diarizedJSON = """
{
  "duration": 18.5,
  "segments": [
    {"start": 0.0, "end": 5.2, "text": "大家好，今天同步一下进度。", "speaker": "A"},
    {"start": 5.5, "end": 12.0, "text": "好的，录音转写已经支持区分演讲人了。", "speaker": "B"},
    {"start": 12.2, "end": 18.5, "text": "非常棒，我们继续完善字幕回放。", "speaker": "主持人"}
  ]
}
"""
let diarized = try RecordingASRRequest.decodeTranscript(Data(diarizedJSON.utf8), provider: .openAI, model: "gpt-4o-transcribe-diarize", fallbackDuration: 18.5)
check(diarized.speakers.count == 3, "three speakers parsed")
check(diarized.speakers[0].name == "演讲人 1", "generic A mapped to 演讲人 1")
check(diarized.speakers[1].name == "演讲人 2", "generic B mapped to 演讲人 2")
check(diarized.speakers[2].name == "主持人", "named speaker preserved")
check(diarized.segments.count == 3, "three segments parsed")
check(diarized.segments[1].startTime == 5.5 && diarized.segments[1].endTime == 12.0, "segment timestamps preserved")
check(diarized.srtText.contains("00:00:05,500 --> 00:00:12,000"), "SRT timestamp formatting")
check(diarized.formattedTextWithSpeakers.contains("[00:05] 演讲人 2：好的，录音转写已经支持区分演讲人了。"), "formatted text with speaker")

// 3. Qwen3-ASR request & sentence-split fallback
let qwen = try RecordingASRRequest.make(provider: .qwen, baseURL: "https://example.com/v1/chat/completions", model: "qwen3-asr-flash", apiKey: "secret", audio: audio)
check(qwen.url?.absoluteString == "https://example.com/v1/chat/completions", "Qwen full endpoint")
let payload = try JSONSerialization.jsonObject(with: qwen.httpBody!) as! [String: Any]
check(payload["model"] as? String == "qwen3-asr-flash", "Qwen model")
let qwenPayload = "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"content\":\"第一段内容非常完整，用来测试自动分句效果。第二段内容也足够长，应当被切分成独立的时间轴字幕！\"}}]}"
let qwenTranscript = try RecordingASRRequest.decodeTranscript(Data(qwenPayload.utf8), provider: .qwen, model: "qwen3-asr-flash", fallbackDuration: 20.0)
check(qwenTranscript.speakers.count == 1 && qwenTranscript.speakers[0].name == "演讲人 1", "Qwen default speaker")
check(qwenTranscript.segments.count == 2, "Qwen sentence split into 2 segments")
check(abs((qwenTranscript.segments.last?.endTime ?? 0) - 20.0) < 0.01, "Qwen proportional timestamps end at duration")

// 4. Transcript disk persistence round-trip in isolated temp directory
let tempPath = NSTemporaryDirectory()
let canonicalTempPath = tempPath.hasPrefix("/var/") ? "/private" + tempPath : tempPath
let tempDir = URL(fileURLWithPath: canonicalTempPath, isDirectory: true).appendingPathComponent("jaimo-asr-test-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tempDir) }
let fakeAudioURL = tempDir.appendingPathComponent("sample.m4a")
try RecordingTranscriptionManager.saveTranscriptToDisk(diarized, for: fakeAudioURL)
let reloaded = RecordingTranscriptionManager.loadTranscriptFromDisk(for: fakeAudioURL, fallbackDuration: 18.5)
check(reloaded?.speakers == diarized.speakers, "Transcript speakers round-trip")
check(reloaded?.segments == diarized.segments, "Transcript segments round-trip")
check(reloaded?.model == diarized.model && reloaded?.duration == diarized.duration, "Transcript metadata round-trip")
check(abs((reloaded?.createdAt.timeIntervalSince(diarized.createdAt) ?? 99)) < 1.0, "Transcript createdAt round-trip")
let plainTxt = try String(contentsOf: RecordingTranscriptionManager.plainTextURL(for: fakeAudioURL), encoding: .utf8)
check(plainTxt.contains("主持人：非常棒"), "Plain text sidecar written")

// 5. Security: reject remote HTTP, allow localhost HTTP
do { _ = try RecordingASRRequest.endpoint(baseURL: "http://example.com/v1", provider: .openAI); fatalError("insecure address accepted") } catch {}
let localEndpoint = try RecordingASRRequest.endpoint(baseURL: "http://127.0.0.1:8000/v1", provider: .openAI)
check(localEndpoint.absoluteString == "http://127.0.0.1:8000/v1/audio/transcriptions", "localhost HTTP allowed")

// 6. Long recording chunk planning, merging & server error extraction
let ranges = RecordingTranscriptionManager.buildChunkRanges(totalDuration: 665, chunkSeconds: 240)
check(ranges.count == 3, "11m05s splits into 3 chunks of 4m")
check(ranges[0].start == 0 && ranges[0].end == 240, "chunk 1 range")
check(ranges[1].start == 240 && ranges[1].end == 480, "chunk 2 range")
check(ranges[2].start == 480 && ranges[2].end == 665, "chunk 3 range")

let merged = RecordingTranscriptionManager.mergeChunkTranscripts(
    [(offset: 0, transcript: diarized), (offset: 240, transcript: diarized)],
    provider: "qwen",
    model: "qwen3-asr-flash",
    totalDuration: 480
)
check(merged.speakers.count == 3, "speakers deduplicated across chunks")
check(merged.segments.count == 6, "segments concatenated across chunks")
check(abs(merged.segments[3].startTime - 240.0) < 0.01, "second chunk timestamps offset properly")
check(RecordingTranscriptionManager.extractServerErrorMessage(from: Data("{\"error\":{\"message\":\"model not supported\"}}".utf8)) == "model not supported", "extract OpenAI error message")

// 7. Deletion and recorder synchronization use only the isolated directory and defaults.
let newer = tempDir.appendingPathComponent("2026-02.m4a")
let older = tempDir.appendingPathComponent("2026-01.m4a")
try Data([0]).write(to: newer)
try Data([0]).write(to: older)
try RecordingTranscriptionManager.saveTranscriptToDisk(diarized, for: newer)
let suite = "jaimo-asr-test-\(UUID().uuidString)"
let isolatedDefaults = UserDefaults(suiteName: suite)!
defer { isolatedDefaults.removePersistentDomain(forName: suite) }
let manager = await MainActor.run {
    RecordingTranscriptionManager(defaults: isolatedDefaults, credentialService: "test-\(UUID().uuidString)", recordingsDirectory: tempDir)
}
let recorder = await MainActor.run { AudioRecorderModel(recordingsDirectory: tempDir) }
for _ in 0..<100 {
    if await MainActor.run(body: { manager.recordings.count == 2 }) { break }
    try await Task.sleep(nanoseconds: 20_000_000)
}
try await MainActor.run {
    check(manager.recordings.count == 2, "temporary recordings loaded")
    check(recorder.latestRecordingURL == newer, "recorder selects latest")
    manager.canDeleteRecording = { recorder.canDeleteRecording($0) }
    manager.onRecordingDeleted = { recorder.recordingWasDeleted($0, latestRemaining: $1) }
    manager.selectRecording(newer)
    manager.playback.seek(to: 4, for: newer)
    try manager.deleteRecording(newer)
    check(!FileManager.default.fileExists(atPath: newer.path), "audio deleted")
    check(!FileManager.default.fileExists(atPath: RecordingTranscriptionManager.transcriptJSONURL(for: newer).path), "JSON deleted")
    check(!FileManager.default.fileExists(atPath: RecordingTranscriptionManager.plainTextURL(for: newer).path), "text deleted")
    check(manager.transcript(for: newer) == nil && manager.state(for: newer) == .idle, "cached transcript and state removed")
    check(manager.selectedRecordingURL == older, "selection advances")
    check(manager.playback.currentURL == nil && manager.playback.currentTime == 0 && manager.playback.duration == 0, "playback reset")
    check(recorder.latestRecordingURL == older, "recorder advances to remaining recording")
    manager.canDeleteRecording = { _ in false }
    do { try manager.deleteRecording(older); fatalError("protected recording deleted") } catch {}
    check(FileManager.default.fileExists(atPath: older.path), "protected recording remains")
    manager.canDeleteRecording = { recorder.canDeleteRecording($0) }
    try manager.deleteRecording(older)
    check(manager.selectedRecordingURL == nil && manager.recordings.isEmpty, "last deletion clears selection")
    check(recorder.status == .idle, "recorder returns to idle")
}
print("Recording ASR self-test passed")
