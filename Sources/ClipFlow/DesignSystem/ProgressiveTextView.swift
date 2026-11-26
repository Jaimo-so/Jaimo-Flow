import ClipFlowKit
import SwiftUI

/// Renders large, selectable text without blocking the first frame on layout.
struct ProgressiveTextView: View {
    let text: String
    let foreground: Color

    @State private var chunks: [TextChunker.Chunk] = []
    @State private var renderedChunkCount = 0
    @State private var revealScheduled = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8.5) {
                if chunks.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .accessibilityLabel("正在准备文本预览")
                } else {
                    ForEach(chunks.indices.prefix(renderedChunkCount), id: \.self) { index in
                        Text(chunks[index].text)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(foreground)
                            .lineSpacing(8.5)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .textSelection(.enabled)
                    }

                    if renderedChunkCount < chunks.count {
                        Color.clear
                            .frame(height: 1)
                            .id(renderedChunkCount)
                            .onAppear(perform: scheduleNextChunk)
                            .accessibilityHidden(true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task(id: text, prepareChunks)
    }

    private func prepareChunks() async {
        chunks = []
        renderedChunkCount = 0
        revealScheduled = false

        let source = text
        let prepared = await Task.detached(priority: .userInitiated) {
            TextChunker.chunks(from: source)
        }.value

        guard !Task.isCancelled else { return }
        chunks = prepared
        renderedChunkCount = min(1, prepared.count)
    }

    private func scheduleNextChunk() {
        guard !revealScheduled, renderedChunkCount < chunks.count else { return }
        revealScheduled = true

        Task { @MainActor in
            // Give AppKit a run-loop turn between chunks so switching tabs stays responsive.
            await Task.yield()
            guard renderedChunkCount < chunks.count else {
                revealScheduled = false
                return
            }
            renderedChunkCount += 1
            revealScheduled = false
        }
    }
}
