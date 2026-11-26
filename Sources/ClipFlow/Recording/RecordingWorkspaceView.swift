import AppKit
import SwiftUI

struct RecordingWorkspaceOverlay: View {
    @ObservedObject var transcription: RecordingTranscriptionManager
    let onRevealRecording: (URL) -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var searchText = ""
    @State private var selectedSpeakerFilter: String?
    @State private var editingSpeaker: RecordingSpeaker?
    @State private var editingSpeakerName = ""
    @State private var editingSegmentID: UUID?
    @State private var editingSegmentText = ""
    @State private var copiedNotice: String?
    @State private var recordingToDelete: RecordingItem?
    @State private var deleteError: String?

    init(
        transcription: RecordingTranscriptionManager,
        onRevealRecording: @escaping (URL) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.transcription = transcription
        self.onRevealRecording = onRevealRecording
        self.onClose = onClose
    }

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.36)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: closeWorkspace)

                VStack(spacing: 0) {
                    header(theme: theme)
                    Divider().overlay(theme.hairline)

                    if transcription.showingSettings {
                        RecordingASRSettingsView(transcription: transcription, theme: theme)
                    } else {
                        workspaceContent(theme: theme)
                    }
                }
                .frame(
                    width: min(860, max(560, proxy.size.width - 36)),
                    height: min(600, max(420, proxy.size.height - 36))
                )
                .background(theme.canvas)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(theme.hairline, lineWidth: 0.7)
                )
                .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
                .contentShape(Rectangle())
                .onTapGesture { }
            }
        }
        .alert("删除录音？", isPresented: Binding(
            get: { recordingToDelete != nil },
            set: { if !$0 { recordingToDelete = nil } }
        ), presenting: recordingToDelete) { item in
            Button("删除", role: .destructive) { deleteRecording(item) }
            Button("取消", role: .cancel) {}
        } message: { item in
            Text("将永久删除“\(item.displayTitle)”及其转写字幕文件，此操作无法撤销。")
        }
        .alert("删除失败", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("好", role: .cancel) { deleteError = nil }
        } message: { Text(deleteError ?? "") }
        .onAppear {
            transcription.reloadRecordings()
            if let current = transcription.selectedRecording {
                transcription.playback.select(current.url, duration: current.duration)
            }
        }
        .onDisappear {
            commitSegmentEditIfNeeded()
            transcription.playback.stop()
        }
    }

    private func deleteRecording(_ item: RecordingItem) {
        if transcription.selectedRecording?.url == item.url {
            commitSegmentEditIfNeeded()
            selectedSpeakerFilter = nil
        }
        do { try transcription.deleteRecording(item.url) }
        catch { deleteError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    private func closeWorkspace() {
        commitSegmentEditIfNeeded()
        transcription.playback.stop()
        transcription.showingSettings = false
        onClose()
    }

    // MARK: - Header

    private func header(theme: ClipFlowTheme) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(transcription.showingSettings ? "录音转写设置" : "录音转写")
                        .font(.system(size: 15, weight: .semibold))
                    if !transcription.showingSettings {
                        Text(transcription.autoTranscribe && transcription.isConfigured ? "自动转写已开启" : "手动转写")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(transcription.autoTranscribe && transcription.isConfigured ? theme.accent : theme.muted)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(transcription.autoTranscribe && transcription.isConfigured ? theme.accentWash : theme.chip)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }
                Text(
                    transcription.showingSettings
                        ? "配置语音转写服务商与自动转写规则，API Key 仅存本机钥匙串"
                        : transcription.serviceSummary
                )
                .font(.system(size: 11))
                .foregroundStyle(theme.muted)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let copiedNotice {
                Text(copiedNotice)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.accent)
            }

            Button {
                commitSegmentEditIfNeeded()
                transcription.showingSettings.toggle()
            } label: {
                Label(transcription.showingSettings ? "返回字幕" : "ASR 设置", systemImage: transcription.showingSettings ? "text.alignleft" : "slider.horizontal.3")
            }
            .buttonStyle(GlassButtonStyle(kind: .normal))
            .fixedSize()

            Button(action: closeWorkspace) {
                Image(systemName: "xmark")
            }
            .buttonStyle(FlowIconButtonStyle())
            .accessibilityLabel("关闭录音转写")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    // MARK: - Main Workspace (Left List + Right Tingwu Transcript)

    private func workspaceContent(theme: ClipFlowTheme) -> some View {
        HStack(spacing: 0) {
            recordingSidebar(theme: theme)
                .frame(width: 214)

            Rectangle()
                .fill(theme.hairline)
                .frame(width: 0.7)

            detailPane(theme: theme)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func recordingSidebar(theme: ClipFlowTheme) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("录音记录（\(transcription.recordings.count)）")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.foregroundSecondary)
                Spacer()
                Button {
                    transcription.reloadRecordings()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(FlowIconButtonStyle())
                .accessibilityLabel("刷新录音列表")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider().overlay(theme.hairline)

            if transcription.recordings.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 22))
                        .foregroundStyle(theme.muted.opacity(0.6))
                    Text("还没有录音")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.foregroundSecondary)
                    Text("在首页录音卡片完成录制后会自动出现在这里")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.muted)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(transcription.recordings) { item in
                            sidebarRow(item: item, theme: theme)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .background(theme.card.opacity(0.5))
    }

    private func sidebarRow(item: RecordingItem, theme: ClipFlowTheme) -> some View {
        let isSelected = transcription.selectedRecording?.url == item.url
        let state = transcription.state(for: item.url)

        return Button {
            commitSegmentEditIfNeeded()
            selectedSpeakerFilter = nil
            transcription.selectRecording(item.url)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(item.displayTitle)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? theme.foreground : theme.foregroundSecondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(item.durationText)
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(theme.muted)

                    Spacer(minLength: 4)

                    statusBadge(for: state, theme: theme)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? theme.selection : Color.clear)
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(theme.accent)
                        .frame(width: 2.5)
                        .padding(.vertical, 5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contextMenu {
            Button("重新转写") {
                transcription.selectRecording(item.url)
                transcription.transcribe(item.url)
            }
            Button("在访达中显示") {
                onRevealRecording(item.url)
            }
            Divider()
            Button("删除录音", role: .destructive) {
                recordingToDelete = item
            }
        }
    }

    @ViewBuilder
    private func statusBadge(for state: RecordingTranscriptionState, theme: ClipFlowTheme) -> some View {
        switch state {
        case .transcribing:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("转写中")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.accent)
            }
        case .completed:
            Text("已转写")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.accent)
        case .failed:
            Text("失败")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.danger)
        case .idle:
            Text("未转写")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.muted)
        }
    }

    // MARK: - Right Detail Pane

    @ViewBuilder
    private func detailPane(theme: ClipFlowTheme) -> some View {
        if let recording = transcription.selectedRecording {
            let state = transcription.state(for: recording.url)
            let transcript = transcription.transcript(for: recording.url)

            VStack(spacing: 0) {
                detailToolbar(recording: recording, state: state, transcript: transcript, theme: theme)
                Divider().overlay(theme.hairline)

                if case .transcribing(let stage) = state {
                    transcribingBanner(stage: stage, url: recording.url, theme: theme)
                    Divider().overlay(theme.hairline)
                } else if case .failed(let message) = state {
                    failedBanner(message: message, url: recording.url, theme: theme)
                    Divider().overlay(theme.hairline)
                }

                if let transcript {
                    speakerBar(transcript: transcript, url: recording.url, theme: theme)
                    Divider().overlay(theme.hairline)
                    RecordingSubtitleFeedView(
                        transcript: transcript,
                        recording: recording,
                        transcription: transcription,
                        playback: transcription.playback,
                        searchText: $searchText,
                        selectedSpeakerFilter: $selectedSpeakerFilter,
                        editingSegmentID: $editingSegmentID,
                        editingSegmentText: $editingSegmentText,
                        onCommitEdit: commitSegmentEditIfNeeded,
                        onCopy: copyToPasteboard
                    )
                } else if !state.isTranscribing {
                    untranscribedEmptyState(recording: recording, theme: theme)
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("正在识别演讲人与字幕，完成后会自动展示…")
                            .font(.system(size: 12.5))
                            .foregroundStyle(theme.muted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Divider().overlay(theme.hairline)
                RecordingAudioPlayerBar(
                    recording: recording,
                    playback: transcription.playback
                )
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "mic.badge.plus")
                    .font(.system(size: 28))
                    .foregroundStyle(theme.muted.opacity(0.6))
                Text("暂无录音记录")
                    .font(.system(size: 14, weight: .semibold))
                Text("在首页录音卡片点击“开始录音”，结束后会自动转写并生成演讲人与时间轴字幕。")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailToolbar(
        recording: RecordingItem,
        state: RecordingTranscriptionState,
        transcript: RecordingTranscript?,
        theme: ClipFlowTheme
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(recording.displayTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text("时长 \(recording.durationText)")
                            .monospacedDigit()
                        if let transcript {
                            Text("·")
                            Text("\(transcript.speakers.count) 位演讲人")
                            Text("·")
                            Text("\(transcript.segments.count) 条字幕")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
                }

                Spacer(minLength: 8)

                if let transcript {
                    Menu {
                        Button("复制（含演讲人与时间戳）") {
                            copyToPasteboard(transcript.formattedTextWithSpeakers, notice: "已复制字幕全文")
                        }
                        Button("复制纯文本") {
                            copyToPasteboard(transcript.plainText, notice: "已复制纯文本")
                        }
                        Button("复制 SRT 字幕") {
                            copyToPasteboard(transcript.srtText, notice: "已复制 SRT 字幕")
                        }
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                if state.isTranscribing {
                    Button("取消转写") {
                        transcription.cancelTranscription(for: recording.url)
                    }
                    .buttonStyle(GlassButtonStyle(kind: .normal))
                    .fixedSize()
                } else {
                    Button(transcript == nil ? "立即转写" : "重新转写") {
                        commitSegmentEditIfNeeded()
                        transcription.transcribe(recording.url)
                    }
                    .buttonStyle(GlassButtonStyle(kind: transcript == nil ? .primary : .normal))
                    .fixedSize()
                }

                Button {
                    recordingToDelete = recording
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(theme.danger)
                }
                .buttonStyle(FlowIconButtonStyle())
                .help("删除录音")
                .accessibilityLabel("删除录音")

                Button {
                    onRevealRecording(recording.url)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(FlowIconButtonStyle())
                .help("在访达中显示录音与字幕文件")
                .accessibilityLabel("在访达中显示")
            }

            if transcript != nil {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.muted)
                    TextField("搜索字幕关键词…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11.5))
                                .foregroundStyle(theme.muted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清空搜索")
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(theme.chip)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func transcribingBanner(stage: String, url: URL, theme: ClipFlowTheme) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(stage)
                .font(.system(size: 12))
                .foregroundStyle(theme.foregroundSecondary)
            Spacer()
            Button("取消") {
                transcription.cancelTranscription(for: url)
            }
            .buttonStyle(GlassButtonStyle(kind: .quiet))
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme.accentWash)
    }

    private func failedBanner(message: String, url: URL, theme: ClipFlowTheme) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(theme.danger)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.danger)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button("重试") {
                transcription.transcribe(url)
            }
            .buttonStyle(GlassButtonStyle(kind: .normal))
            .fixedSize()
            Button("设置") {
                transcription.showingSettings = true
            }
            .buttonStyle(GlassButtonStyle(kind: .quiet))
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme.danger.opacity(0.08))
    }

    private func untranscribedEmptyState(recording: RecordingItem, theme: ClipFlowTheme) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "captions.bubble")
                .font(.system(size: 28))
                .foregroundStyle(theme.muted.opacity(0.65))
            Text("该录音尚未转写")
                .font(.system(size: 14, weight: .semibold))
            Text(
                transcription.isConfigured
                    ? "点击下方按钮立即生成演讲人与时间轴字幕。"
                    : "配置转写服务（支持阿里云 Qwen3-ASR / OpenAI 兼容接口）后，即可自动或手动转写。"
            )
            .font(.system(size: 12))
            .foregroundStyle(theme.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 340)

            HStack(spacing: 10) {
                if transcription.isConfigured {
                    Button("立即转写") {
                        transcription.transcribe(recording.url)
                    }
                    .buttonStyle(GlassButtonStyle(kind: .primary))
                    .fixedSize()
                } else {
                    Button("配置 ASR 服务") {
                        transcription.showingSettings = true
                    }
                    .buttonStyle(GlassButtonStyle(kind: .primary))
                    .fixedSize()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Speaker Filter & Rename Bar

    private func speakerBar(transcript: RecordingTranscript, url: URL, theme: ClipFlowTheme) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button {
                    selectedSpeakerFilter = nil
                } label: {
                    Text("全部（\(transcript.segments.count)）")
                        .font(.system(size: 11.5, weight: selectedSpeakerFilter == nil ? .semibold : .medium))
                        .foregroundStyle(selectedSpeakerFilter == nil ? theme.accent : theme.foregroundSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(selectedSpeakerFilter == nil ? theme.selection : theme.chip)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)

                ForEach(transcript.speakers) { speaker in
                    let isFiltered = selectedSpeakerFilter == speaker.id
                    let count = transcript.segments.filter { $0.speakerID == speaker.id }.count
                    let dotColor = speakerColor(index: speaker.colorIndex, theme: theme)

                    HStack(spacing: 4) {
                        Button {
                            selectedSpeakerFilter = isFiltered ? nil : speaker.id
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(dotColor)
                                    .frame(width: 7, height: 7)
                                Text(speaker.name)
                                    .font(.system(size: 11.5, weight: isFiltered ? .semibold : .medium))
                                Text("\(count)")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(theme.muted)
                            }
                        }
                        .buttonStyle(.plain)

                        Button {
                            editingSpeaker = speaker
                            editingSpeakerName = speaker.name
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 10))
                                .foregroundStyle(theme.muted)
                        }
                        .buttonStyle(.plain)
                        .help("重命名演讲人")
                        .accessibilityLabel("重命名\(speaker.name)")
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(isFiltered ? theme.selection : theme.chip)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(isFiltered ? theme.accent.opacity(0.45) : .clear, lineWidth: 0.8)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }

                Button {
                    if let created = transcription.addSpeaker(in: url) {
                        editingSpeaker = created
                        editingSpeakerName = created.name
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text("添加演讲人")
                            .font(.system(size: 11.5))
                    }
                    .foregroundStyle(theme.muted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(theme.chip.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
        .popover(item: $editingSpeaker) { speaker in
            VStack(alignment: .leading, spacing: 10) {
                Text("重命名演讲人")
                    .font(.system(size: 12.5, weight: .semibold))
                TextField("输入姓名或角色", text: $editingSpeakerName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)
                    .onSubmit {
                        transcription.renameSpeaker(in: url, speakerID: speaker.id, newName: editingSpeakerName)
                        editingSpeaker = nil
                    }
                HStack {
                    Spacer()
                    Button("取消") { editingSpeaker = nil }
                        .buttonStyle(GlassButtonStyle(kind: .quiet))
                        .fixedSize()
                    Button("保存") {
                        transcription.renameSpeaker(in: url, speakerID: speaker.id, newName: editingSpeakerName)
                        editingSpeaker = nil
                    }
                    .buttonStyle(GlassButtonStyle(kind: .primary))
                    .fixedSize()
                }
            }
            .padding(14)
        }
    }

    // MARK: - Helpers

    private func commitSegmentEditIfNeeded() {
        guard let segmentID = editingSegmentID,
              let url = transcription.selectedRecording?.url else {
            editingSegmentID = nil
            editingSegmentText = ""
            return
        }
        transcription.updateSegmentText(in: url, segmentID: segmentID, text: editingSegmentText)
        editingSegmentID = nil
        editingSegmentText = ""
    }

    private func copyToPasteboard(_ text: String, notice: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedNotice = notice
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if copiedNotice == notice { copiedNotice = nil }
        }
    }

    private func speakerColor(index: Int, theme: ClipFlowTheme) -> Color {
        Self.speakerColor(index: index, theme: theme)
    }

    static func speakerColor(index: Int, theme: ClipFlowTheme) -> Color {
        let palette: [Color] = [
            theme.accent,
            theme.star,
            Color(red: 0.32, green: 0.72, blue: 0.56),
            Color(red: 0.65, green: 0.50, blue: 0.86),
            theme.danger,
            Color(red: 0.42, green: 0.62, blue: 0.90)
        ]
        return palette[abs(index) % palette.count]
    }
}
