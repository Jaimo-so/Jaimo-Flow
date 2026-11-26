import SwiftUI

struct RecordingSubtitleFeedView: View {
    let transcript: RecordingTranscript
    let recording: RecordingItem
    let transcription: RecordingTranscriptionManager
    @ObservedObject var playback: RecordingPlaybackController
    @Binding var searchText: String
    @Binding var selectedSpeakerFilter: String?
    @Binding var editingSegmentID: UUID?
    @Binding var editingSegmentText: String
    let onCommitEdit: () -> Void
    let onCopy: (String, String) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = transcript.segments.filter { segment in
            if let speakerFilter = selectedSpeakerFilter, segment.speakerID != speakerFilter {
                return false
            }
            if !query.isEmpty {
                let speakerName = transcript.speakerName(for: segment.speakerID).lowercased()
                return segment.text.lowercased().contains(query) || speakerName.contains(query)
            }
            return true
        }
        let activeSegmentID = currentActiveSegmentID()

        ScrollViewReader { proxy in
            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Text("没有匹配的字幕内容")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.foregroundSecondary)
                    Button("清除筛选") {
                        searchText = ""
                        selectedSpeakerFilter = nil
                    }
                    .buttonStyle(GlassButtonStyle(kind: .quiet))
                    .fixedSize()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(filtered) { segment in
                            subtitleCard(segment: segment, isActive: segment.id == activeSegmentID, theme: theme)
                                .id(segment.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: activeSegmentID) { newID in
                    guard playback.isPlaying, let newID else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
        }
    }

    private func currentActiveSegmentID() -> UUID? {
        guard playback.currentURL == recording.url, playback.isPlaying || playback.currentTime > 0 else { return nil }
        let now = playback.currentTime
        if let exact = transcript.segments.first(where: { now >= $0.startTime && now <= max($0.endTime, $0.startTime + 0.1) }) {
            return exact.id
        }
        return transcript.segments.last(where: { now >= $0.startTime })?.id
    }

    private func subtitleCard(
        segment: RecordingTranscriptSegment,
        isActive: Bool,
        theme: ClipFlowTheme
    ) -> some View {
        let speakerName = transcript.speakerName(for: segment.speakerID)
        let dotColor = RecordingWorkspaceOverlay.speakerColor(index: transcript.speakerColorIndex(for: segment.speakerID), theme: theme)
        let isEditing = editingSegmentID == segment.id

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(transcript.speakers) { speaker in
                        Button {
                            transcription.reassignSpeaker(in: recording.url, segmentID: segment.id, speakerID: speaker.id)
                        } label: {
                            if speaker.id == segment.speakerID {
                                Label(speaker.name, systemImage: "checkmark")
                            } else {
                                Text(speaker.name)
                            }
                        }
                    }
                    Divider()
                    Button("新建演讲人并指派") {
                        if let created = transcription.addSpeaker(in: recording.url) {
                            transcription.reassignSpeaker(in: recording.url, segmentID: segment.id, speakerID: created.id)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(dotColor)
                            .frame(width: 8, height: 8)
                        Text(speakerName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.foreground)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    playback.seek(to: segment.startTime, for: recording.url, autoPlay: true)
                } label: {
                    Text("\(RecordingTranscript.formatTimestamp(segment.startTime)) – \(RecordingTranscript.formatTimestamp(segment.endTime))")
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(isActive ? theme.accent : theme.muted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isActive ? theme.accentWash : theme.chip)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("点击从此处播放")

                Spacer(minLength: 6)

                Button {
                    playback.seek(to: segment.startTime, for: recording.url, autoPlay: true)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10.5))
                }
                .buttonStyle(FlowIconButtonStyle())
                .help("从本段播放")
                .accessibilityLabel("从本段播放")

                Button {
                    if isEditing {
                        onCommitEdit()
                    } else {
                        onCommitEdit()
                        editingSegmentID = segment.id
                        editingSegmentText = segment.text
                    }
                } label: {
                    Image(systemName: isEditing ? "checkmark" : "pencil")
                        .font(.system(size: 11))
                }
                .buttonStyle(FlowIconButtonStyle())
                .help(isEditing ? "完成编辑" : "校对字幕")
                .accessibilityLabel(isEditing ? "完成编辑" : "校对字幕")

                Button {
                    onCopy("\(speakerName)：\(segment.text)", "已复制本段字幕")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(FlowIconButtonStyle())
                .help("复制本段")
                .accessibilityLabel("复制本段")
            }

            if isEditing {
                VStack(alignment: .trailing, spacing: 6) {
                    TextEditor(text: $editingSegmentText)
                        .font(.system(size: 13))
                        .lineSpacing(4)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 62)
                        .background(theme.canvas)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(theme.accent.opacity(0.5), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    HStack(spacing: 8) {
                        Button("取消") {
                            editingSegmentID = nil
                            editingSegmentText = ""
                        }
                        .buttonStyle(GlassButtonStyle(kind: .quiet))
                        .fixedSize()
                        Button("保存修改") {
                            onCommitEdit()
                        }
                        .buttonStyle(GlassButtonStyle(kind: .primary))
                        .fixedSize()
                    }
                }
            } else {
                Text(segment.text)
                    .font(.system(size: 13))
                    .lineSpacing(4.5)
                    .foregroundStyle(theme.foregroundSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isActive ? theme.selection : theme.card)
        .overlay(alignment: .leading) {
            if isActive {
                RoundedRectangle(cornerRadius: 2)
                    .fill(theme.accent)
                    .frame(width: 3)
                    .padding(.vertical, 6)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isActive ? theme.accent.opacity(0.32) : theme.hairline, lineWidth: 0.6)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
