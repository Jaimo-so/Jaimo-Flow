import Foundation

enum RecordingASRProvider: String, CaseIterable, Identifiable {
    case qwen, openAI
    var id: String { rawValue }
    var title: String { self == .qwen ? "阿里云 Qwen3-ASR" : "OpenAI 兼容接口" }
    var defaultURL: String { self == .qwen ? "https://dashscope.aliyuncs.com/compatible-mode/v1" : "https://api.openai.com/v1" }
    var defaultModel: String { self == .qwen ? "qwen3-asr-flash" : "gpt-4o-transcribe-diarize" }
    var path: String { self == .qwen ? "chat/completions" : "audio/transcriptions" }
    var modelHint: String {
        self == .qwen
            ? "推荐 qwen3-asr-flash（单条最长 5 分钟）"
            : "支持 gpt-4o-transcribe-diarize（自动区分演讲人）或 whisper-1（分段字幕）"
    }
}

enum RecordingASRError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

struct RecordingSpeaker: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var colorIndex: Int
}

struct RecordingTranscriptSegment: Identifiable, Codable, Equatable {
    let id: UUID
    var speakerID: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String

    init(id: UUID = UUID(), speakerID: String, startTime: TimeInterval, endTime: TimeInterval, text: String) {
        self.id = id
        self.speakerID = speakerID
        self.startTime = max(0, startTime)
        self.endTime = max(self.startTime, endTime)
        self.text = text
    }
}

struct RecordingTranscript: Codable, Equatable {
    var version: Int = 1
    var provider: String
    var model: String
    var duration: TimeInterval
    var createdAt: Date
    var speakers: [RecordingSpeaker]
    var segments: [RecordingTranscriptSegment]

    func speaker(for id: String) -> RecordingSpeaker? {
        speakers.first { $0.id == id }
    }

    func speakerName(for id: String) -> String {
        speaker(for: id)?.name ?? "演讲人 1"
    }

    func speakerColorIndex(for id: String) -> Int {
        speaker(for: id)?.colorIndex ?? 0
    }

    var plainText: String {
        segments.map(\.text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
    }

    var formattedTextWithSpeakers: String {
        segments.compactMap { segment in
            let body = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            return "[\(Self.formatTimestamp(segment.startTime))] \(speakerName(for: segment.speakerID))：\(body)"
        }.joined(separator: "\n\n")
    }

    var srtText: String {
        segments.enumerated().compactMap { index, segment in
            let body = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            let start = Self.formatSRTTimestamp(segment.startTime)
            let end = Self.formatSRTTimestamp(max(segment.endTime, segment.startTime + 0.5))
            return "\(index + 1)\n\(start) --> \(end)\n\(speakerName(for: segment.speakerID))：\(body)"
        }.joined(separator: "\n\n")
    }

    static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    static func formatSRTTimestamp(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        let totalMillis = Int((clamped * 1000).rounded())
        let hours = totalMillis / 3_600_000
        let minutes = (totalMillis % 3_600_000) / 60_000
        let secs = (totalMillis % 60_000) / 1000
        let millis = totalMillis % 1000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }

    static func fromPlainText(
        _ rawText: String,
        provider: String,
        model: String,
        duration: TimeInterval,
        createdAt: Date = Date()
    ) -> RecordingTranscript {
        let speaker = RecordingSpeaker(id: "speaker_1", name: "演讲人 1", colorIndex: 0)
        let chunks = splitIntoSubtitleChunks(rawText)
        let safeDuration = duration.isFinite && duration > 0 ? duration : Double(max(chunks.count * 4, 1))
        let totalWeight = max(1, chunks.reduce(0) { $0 + max(1, $1.count) })
        var cursor: TimeInterval = 0
        var segments: [RecordingTranscriptSegment] = []

        for (index, chunk) in chunks.enumerated() {
            let weight = Double(max(1, chunk.count))
            let span = index == chunks.count - 1
                ? max(0, safeDuration - cursor)
                : safeDuration * (weight / Double(totalWeight))
            let end = min(safeDuration, cursor + span)
            segments.append(
                RecordingTranscriptSegment(
                    speakerID: speaker.id,
                    startTime: cursor,
                    endTime: end,
                    text: chunk
                )
            )
            cursor = end
        }

        return RecordingTranscript(
            provider: provider,
            model: model,
            duration: safeDuration,
            createdAt: createdAt,
            speakers: [speaker],
            segments: segments
        )
    }

    static func splitIntoSubtitleChunks(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        let terminators: Set<Character> = ["。", "！", "？", "；", "!", "?", ";"]
        var sentences: [String] = []

        for rawLine in normalized.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            var current = ""
            let chars = Array(line)
            for i in chars.indices {
                let ch = chars[i]
                current.append(ch)
                let isEnglishPeriod = ch == "." && (i + 1 == chars.count || chars[i + 1] == " ")
                if terminators.contains(ch) || isEnglishPeriod {
                    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { sentences.append(trimmed) }
                    current = ""
                }
            }
            let remainder = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainder.isEmpty { sentences.append(remainder) }
        }

        // Merge overly short fragments into neighboring subtitle lines for natural readability.
        var merged: [String] = []
        for sentence in sentences {
            if let last = merged.last, (last.count < 12 || sentence.count < 8), last.count + sentence.count <= 90 {
                let joiner = last.last?.isASCII == true && sentence.first?.isASCII == true ? " " : ""
                merged[merged.count - 1] = last + joiner + sentence
            } else {
                merged.append(sentence)
            }
        }
        return merged.isEmpty ? [normalized] : merged
    }
}

struct RecordingASRRequest {
    enum OpenAIResponseFormat: String {
        case diarizedJSON = "diarized_json"
        case verboseJSON = "verbose_json"
        case plainJSON = "json"
    }

    static func preferredOpenAIResponseFormat(for model: String) -> OpenAIResponseFormat {
        let lower = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.contains("diarize") {
            return .diarizedJSON
        }
        return .verboseJSON
    }

    static func endpoint(baseURL: String, provider: RecordingASRProvider) throws -> URL {
        let address = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: address), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)),
              let url = parts.url else { throw RecordingASRError.message("请填写有效的 HTTPS 接口地址；本机服务可使用 HTTP。") }
        return url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).hasSuffix(provider.path)
            ? url : url.appendingPathComponent(provider.path)
    }

    static func make(
        provider: RecordingASRProvider,
        baseURL: String,
        model: String,
        apiKey: String,
        audio: Data,
        responseFormat: OpenAIResponseFormat? = nil
    ) throws -> URLRequest {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, !model.contains("\r"), !model.contains("\n") else { throw RecordingASRError.message("请填写有效的模型名称。") }
        guard !apiKey.isEmpty, apiKey.rangeOfCharacter(from: .newlines) == nil else { throw RecordingASRError.message("请填写有效的 API Key。") }
        var request = URLRequest(url: try endpoint(baseURL: baseURL, provider: provider), timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if provider == .qwen {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model, "stream": false,
                "messages": [["role": "user", "content": [["type": "input_audio", "input_audio": ["data": "data:audio/wav;base64,\(audio.base64EncodedString())"]]]]]
            ])
        } else {
            let boundary = "JaimoFlow-\(UUID().uuidString)"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = Data()
            func append(_ string: String) { body.append(Data(string.utf8)) }
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n")
            let resolvedFormat = responseFormat ?? preferredOpenAIResponseFormat(for: model)
            if resolvedFormat != .plainJSON {
                append("--\(boundary)\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\n\(resolvedFormat.rawValue)\r\n")
            }
            if resolvedFormat == .diarizedJSON {
                append("--\(boundary)\r\nContent-Disposition: form-data; name=\"chunking_strategy\"\r\n\r\nauto\r\n")
            }
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n")
            body.append(audio)
            append("\r\n--\(boundary)--\r\n")
            request.httpBody = body
        }
        return request
    }

    static func decode(_ data: Data, provider: RecordingASRProvider) throws -> String {
        let transcript = try decodeTranscript(data, provider: provider, model: provider.defaultModel, fallbackDuration: 0)
        return transcript.plainText
    }

    static func decodeTranscript(
        _ data: Data,
        provider: RecordingASRProvider,
        model: String,
        fallbackDuration: TimeInterval
    ) throws -> RecordingTranscript {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if provider == .openAI {
            let duration = (object?["duration"] as? Double) ?? fallbackDuration
            if let rawSegments = object?["segments"] as? [[String: Any]], !rawSegments.isEmpty {
                var speakers: [RecordingSpeaker] = []
                var speakerMap: [String: String] = [:]
                var segments: [RecordingTranscriptSegment] = []

                for item in rawSegments {
                    guard let rawText = item["text"] as? String else { continue }
                    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }

                    let start = (item["start"] as? Double) ?? (item["start"] as? NSNumber)?.doubleValue ?? 0
                    let end = (item["end"] as? Double) ?? (item["end"] as? NSNumber)?.doubleValue ?? start
                    let rawSpeaker = extractRawSpeaker(from: item) ?? "default"

                    let speakerID: String
                    if let existing = speakerMap[rawSpeaker] {
                        speakerID = existing
                    } else {
                        let index = speakers.count
                        let id = "speaker_\(index + 1)"
                        let displayName = normalizedSpeakerDisplayName(rawSpeaker, index: index)
                        speakers.append(RecordingSpeaker(id: id, name: displayName, colorIndex: index))
                        speakerMap[rawSpeaker] = id
                        speakerID = id
                    }

                    segments.append(
                        RecordingTranscriptSegment(
                            speakerID: speakerID,
                            startTime: start,
                            endTime: max(start, end),
                            text: text
                        )
                    )
                }

                if !segments.isEmpty {
                    let resolvedDuration = max(duration, segments.last?.endTime ?? 0)
                    return RecordingTranscript(
                        provider: provider.rawValue,
                        model: model,
                        duration: resolvedDuration,
                        createdAt: Date(),
                        speakers: speakers,
                        segments: segments
                    )
                }
            }

            if let text = object?["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return RecordingTranscript.fromPlainText(
                    text,
                    provider: provider.rawValue,
                    model: model,
                    duration: duration
                )
            }
            throw RecordingASRError.message("服务未返回完整的转写文字。")
        } else {
            var result: String?
            if let choice = (object?["choices"] as? [[String: Any]])?.first,
               (choice["finish_reason"] as? String) == nil || (choice["finish_reason"] as? String) == "stop" {
                let message = choice["message"] as? [String: Any]
                if let content = message?["content"] as? String {
                    result = content
                } else if let parts = message?["content"] as? [[String: Any]] {
                    result = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
                }
            }
            guard let value = result, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RecordingASRError.message("服务未返回完整的转写文字。")
            }
            return RecordingTranscript.fromPlainText(
                value,
                provider: provider.rawValue,
                model: model,
                duration: fallbackDuration
            )
        }
    }

    private static func extractRawSpeaker(from segment: [String: Any]) -> String? {
        if let s = segment["speaker"] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let s = segment["speaker_id"] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let n = segment["speaker_id"] as? NSNumber {
            return n.stringValue
        }
        if let n = segment["speaker"] as? NSNumber {
            return n.stringValue
        }
        return nil
    }

    private static func normalizedSpeakerDisplayName(_ raw: String, index: Int) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()
        if trimmed == "default"
            || upper.hasPrefix("SPEAKER_")
            || upper.hasPrefix("SPK")
            || (trimmed.count == 1 && trimmed.first?.isLetter == true)
            || Int(trimmed) != nil {
            return "演讲人 \(index + 1)"
        }
        return trimmed
    }
}
