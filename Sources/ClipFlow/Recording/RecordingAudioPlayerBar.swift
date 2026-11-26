import SwiftUI

struct RecordingAudioPlayerBar: View {
    let recording: RecordingItem
    @ObservedObject var playback: RecordingPlaybackController
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        let isCurrent = playback.currentURL == recording.url
        let displayDuration = isCurrent && playback.duration > 0 ? playback.duration : max(recording.duration, 0.1)
        let displayTime = isCurrent ? playback.currentTime : 0

        HStack(spacing: 12) {
            Button {
                playback.togglePlayPause(for: recording.url)
            } label: {
                Image(systemName: isCurrent && playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 14)
            }
            .buttonStyle(GlassButtonStyle(kind: .primary, horizontalPadding: 10))
            .fixedSize()
            .accessibilityLabel(isCurrent && playback.isPlaying ? "暂停播放" : "播放录音")

            Text(RecordingTranscript.formatTimestamp(displayTime))
                .font(.system(size: 11.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(theme.foregroundSecondary)
                .frame(width: 44, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { min(displayTime, displayDuration) },
                    set: { newValue in
                        playback.seek(to: newValue, for: recording.url, autoPlay: false)
                    }
                ),
                in: 0...max(displayDuration, 0.1)
            )
            .tint(theme.accent)

            Text(RecordingTranscript.formatTimestamp(displayDuration))
                .font(.system(size: 11.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(theme.muted)
                .frame(width: 44, alignment: .leading)

            Menu {
                ForEach(RecordingPlaybackController.supportedRates, id: \.self) { rate in
                    Button {
                        playback.setRate(rate)
                    } label: {
                        if playback.playbackRate == rate {
                            Label(rateLabel(rate), systemImage: "checkmark")
                        } else {
                            Text(rateLabel(rate))
                        }
                    }
                }
            } label: {
                Text(rateLabel(playback.playbackRate))
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.foregroundSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(theme.chip)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("播放倍速")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.card.opacity(0.6))
    }

    private func rateLabel(_ rate: Float) -> String {
        rate == floor(rate) ? String(format: "%.1fx", rate) : String(format: "%.2gx", rate)
    }
}
