import AppKit
import SwiftUI

/// Keep AppKit's live editing buffer (selection and IME marked text) intact
/// while SwiftUI refreshes the surrounding dashboard or memo list.
struct NoteTextEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    var foreground: Color
    var identifier: String
    var focusRequest: Int = 0

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = NSTextView(frame: .zero)
        textView.identifier = NSUserInterfaceItemIdentifier(identifier)
        textView.setAccessibilityLabel(identifier == "jaimo.memo.editor" ? "备忘录正文" : "快速便签")
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 5, height: 4)
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = NSColor(foreground)
        textView.string = text
        textView.delegate = context.coordinator
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if focusRequest != context.coordinator.focusRequest, let window = textView.window {
            window.makeFirstResponder(textView)
            context.coordinator.focusRequest = focusRequest
        }
        textView.textColor = NSColor(foreground)
        // A parent refresh must not replace an active input method's buffer.
        // Once focus leaves, the binding is the source for external changes.
        guard !textView.hasMarkedText(), textView.window?.firstResponder !== textView,
              textView.string != text else { return }
        textView.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var focusRequest = 0

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if text.wrappedValue != textView.string {
                text.wrappedValue = textView.string
            }
        }
    }
}
