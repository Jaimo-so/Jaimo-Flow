import SwiftUI

struct RecordingASRSettingsView: View {
    @ObservedObject var transcription: RecordingTranscriptionManager
    let theme: ClipFlowTheme

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("录音完成后自动转写", isOn: $transcription.autoTranscribe)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .tint(theme.accent)
                            .font(.system(size: 13, weight: .medium))
                        Text("开启后，每次结束录音会自动将音频发送到下方配置的服务商，并生成演讲人与时间轴字幕。")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.muted)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 6) {
                        Text("转写服务商")
                            .font(.system(size: 12, weight: .medium))
                        Picker("转写服务商", selection: $transcription.provider) {
                            ForEach(RecordingASRProvider.allCases) { provider in
                                Text(provider.title).tag(provider)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .onChange(of: transcription.provider) { _ in
                            transcription.loadSettings()
                        }
                        Text(transcription.provider.modelHint)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.muted)
                    }

                    settingsField(
                        title: "接口 Base URL",
                        hint: "支持填写 Base URL 或完整接口地址；远程地址须为 HTTPS，本机服务可用 HTTP。",
                        theme: theme
                    ) {
                        TextField(transcription.provider.defaultURL, text: $transcription.baseURL)
                            .textFieldStyle(.plain)
                    }

                    settingsField(
                        title: "模型名称",
                        hint: transcription.provider == .openAI
                            ? "使用 gpt-4o-transcribe-diarize 可自动识别多位演讲人与时间戳；whisper-1 支持时间戳字幕。"
                            : "例如 qwen3-asr-flash。",
                        theme: theme
                    ) {
                        TextField(transcription.provider.defaultModel, text: $transcription.model)
                            .textFieldStyle(.plain)
                    }

                    settingsField(
                        title: "API Key",
                        hint: transcription.hasKey
                            ? "已保存在 macOS 钥匙串；留空沿用当前密钥，填写新值可替换。"
                            : "各服务的 API Key 分别保存在本机 macOS 钥匙串中，不写入明文配置。",
                        theme: theme
                    ) {
                        SecureField(
                            transcription.hasKey ? "已保存，留空沿用" : "输入当前服务的 API Key",
                            text: $transcription.key
                        )
                        .textFieldStyle(.plain)
                    }

                    if let error = transcription.settingsError {
                        Text(error)
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let message = transcription.settingsMessage {
                        Text(message)
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.accent)
                    }
                }
                .padding(18)
            }

            Divider().overlay(theme.hairline)

            HStack(spacing: 10) {
                Spacer()
                Button("返回") {
                    transcription.showingSettings = false
                }
                .buttonStyle(GlassButtonStyle(kind: .quiet))
                .fixedSize()

                Button("保存设置") {
                    if transcription.saveSettings() {
                        transcription.showingSettings = false
                    }
                }
                .buttonStyle(GlassButtonStyle(kind: .primary))
                .fixedSize()
            }
            .padding(14)
        }
    }

    private func settingsField<Field: View>(
        title: String,
        hint: String,
        theme: ClipFlowTheme,
        @ViewBuilder field: () -> Field
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium))
            field()
                .font(.system(size: 13))
                .padding(10)
                .background(theme.chip)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(theme.muted)
        }
    }
}
