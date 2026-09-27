import SwiftUI

/// Shared timing for the native workspace. No perpetual animations or animated blur.
enum FlowMotion {
    static let hover = Animation.easeOut(duration: 0.12)
    static let press = Animation.easeOut(duration: 0.09)
    static let release = Animation.interactiveSpring(response: 0.24, dampingFraction: 0.86)
    static let layout = Animation.interactiveSpring(response: 0.34, dampingFraction: 0.90)
    static let content = Animation.easeOut(duration: 0.18)
    static let reduced = Animation.easeOut(duration: 0.10)
    static let windowIn: TimeInterval = 0.18
    static let windowOut: TimeInterval = 0.12

    static func reveal(reduceMotion: Bool, distance: CGFloat = 8) -> AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .offset(y: distance)),
            removal: .opacity.combined(with: .offset(y: -distance / 2))
        )
    }
}

/// Applied to the visual label so the button's hit area never moves on hover.
struct FlowControlFeedback: ViewModifier {
    let isPressed: Bool
    var cornerRadius: CGFloat = 8
    var hoverFill: Color = .clear
    var pressedScale: CGFloat = 0.97
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(hovering && isEnabled ? hoverFill : .clear)
            )
            .scaleEffect(isPressed && isEnabled && !reduceMotion ? pressedScale : 1)
            .animation(reduceMotion ? nil : (isPressed ? FlowMotion.press : FlowMotion.release), value: isPressed)
            .animation(reduceMotion ? nil : FlowMotion.hover, value: hovering)
            .onHover { hovering = $0 }
    }
}
