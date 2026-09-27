import AppKit
import SwiftUI

enum WindowMetrics {
    static let cornerRadius: CGFloat = 18
}

struct ClipFlowTheme {
    let scheme: ColorScheme

    var lightWindowBackground: LinearGradient {
        LinearGradient(
            stops: [
                .init(
                    color: Color(red: 229.0 / 255.0, green: 250.0 / 255.0, blue: 255.0 / 255.0),
                    location: 0
                ),
                .init(
                    color: Color(red: 243.0 / 255.0, green: 250.0 / 255.0, blue: 255.0 / 255.0),
                    location: 0.43
                ),
                .init(
                    color: Color(red: 249.0 / 255.0, green: 250.0 / 255.0, blue: 251.0 / 255.0),
                    location: 1
                )
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var foreground: Color { scheme == .dark ? oklch(0.95, 0.003, 90) : oklch(0.25, 0.003, 90) }
    var foregroundSecondary: Color { scheme == .dark ? oklch(0.82, 0.003, 90) : oklch(0.40, 0.003, 90) }
    var muted: Color { scheme == .dark ? oklch(0.68, 0.003, 90) : oklch(0.52, 0.003, 90) }
    var accent: Color { scheme == .dark ? oklch(0.74, 0.13, 218) : oklch(0.56, 0.14, 218) }
    var danger: Color { scheme == .dark ? oklch(0.73, 0.14, 25) : oklch(0.52, 0.17, 25) }
    var star: Color { scheme == .dark ? oklch(0.80, 0.12, 85) : oklch(0.58, 0.12, 85) }

    var canvas: Color { scheme == .dark ? oklch(0.22, 0.003, 90) : oklch(0.975, 0.004, 90) }
    var card: Color { scheme == .dark ? oklch(0.27, 0.003, 90) : .white }
    var primaryFill: Color { foreground }
    var onPrimary: Color { scheme == .dark ? oklch(0.22, 0.003, 90) : .white }
    var accentWash: Color { accent.opacity(scheme == .dark ? 0.13 : 0.07) }

    var glass: Color {
        canvas.opacity(0.96)
    }
    var glassSecondary: Color {
        scheme == .dark ? oklch(0.27, 0.003, 90, 0.90) : Color.white.opacity(0.90)
    }
    var chip: Color { foreground.opacity(scheme == .dark ? 0.055 : 0.035) }
    var chipHigh: Color { foreground.opacity(scheme == .dark ? 0.10 : 0.07) }
    var hairline: Color { foreground.opacity(scheme == .dark ? 0.09 : 0.07) }
    var weakHairline: Color { (scheme == .dark ? Color.white : Color.black).opacity(0.045) }
    var selection: Color { accentWash }
    var skeleton: Color { (scheme == .dark ? Color.white : Color.black).opacity(0.07) }
    var skeletonHigh: Color { (scheme == .dark ? Color.white : Color.black).opacity(0.13) }

    private func oklch(_ lightness: Double, _ chroma: Double, _ hue: Double, _ alpha: Double = 1) -> Color {
        Color(Self.nsColor(lightness: lightness, chroma: chroma, hue: hue, alpha: alpha))
    }

    private static func nsColor(lightness: Double, chroma: Double, hue: Double, alpha: Double) -> NSColor {
        let radians = hue * .pi / 180
        let a = chroma * cos(radians)
        let b = chroma * sin(radians)

        let lPrime = lightness + 0.3963377774 * a + 0.2158037573 * b
        let mPrime = lightness - 0.1055613458 * a - 0.0638541728 * b
        let sPrime = lightness - 0.0894841775 * a - 1.2914855480 * b

        let l = lPrime * lPrime * lPrime
        let m = mPrime * mPrime * mPrime
        let s = sPrime * sPrime * sPrime

        let linearRed = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let linearGreen = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let linearBlue = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s

        func gamma(_ value: Double) -> Double {
            let converted = value <= 0.0031308
                ? 12.92 * value
                : 1.055 * pow(value, 1 / 2.4) - 0.055
            return min(1, max(0, converted))
        }

        return NSColor(
            srgbRed: gamma(linearRed),
            green: gamma(linearGreen),
            blue: gamma(linearBlue),
            alpha: alpha
        )
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.state = .active
    }
}

struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowDragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) { }
}

private final class WindowDragView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

struct KeyCap: View {
    let text: String
    var muted = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        Text(text)
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(muted ? theme.muted : theme.foregroundSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(theme.chip)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.hairline, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct GlassButtonStyle: ButtonStyle {
    enum Kind { case normal, primary, quiet, danger }
    let kind: Kind
    let horizontalPadding: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    init(kind: Kind, horizontalPadding: CGFloat = 12) {
        self.kind = kind
        self.horizontalPadding = horizontalPadding
    }

    func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(
            configuration: configuration,
            kind: kind,
            horizontalPadding: horizontalPadding,
            colorScheme: colorScheme
        )
    }
}

private struct GlassButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: GlassButtonStyle.Kind
    let horizontalPadding: CGFloat
    let colorScheme: ColorScheme
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(foreground(theme: theme))
            .frame(maxWidth: .infinity, minHeight: 30)
            .padding(.horizontal, horizontalPadding)
            .background(background(theme: theme))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isFocused ? theme.foreground.opacity(0.28) : .clear, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .modifier(FlowControlFeedback(isPressed: configuration.isPressed, cornerRadius: 7))
            .opacity(isEnabled ? 1 : 0.38)
            .animation(reduceMotion ? nil : FlowMotion.hover, value: hovering)
            .onHover { hovering = $0 }
    }

    private func background(theme: ClipFlowTheme) -> Color {
        let highlighted = isEnabled && (hovering || configuration.isPressed)
        switch kind {
        case .normal: return highlighted ? theme.chipHigh : theme.chip
        case .primary: return theme.primaryFill.opacity(highlighted ? 0.82 : 1)
        case .quiet: return highlighted ? theme.chip : .clear
        case .danger: return theme.danger.opacity(highlighted ? 0.15 : 0.07)
        }
    }

    private func foreground(theme: ClipFlowTheme) -> Color {
        switch kind {
        case .primary: return theme.onPrimary
        case .danger: return theme.danger
        case .normal, .quiet: return theme.foregroundSecondary
        }
    }
}

/// Quiet toolbar controls share one hit area and the same hover/disabled states.
struct FlowIconButtonStyle: ButtonStyle {
    var danger = false
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        FlowIconButtonBody(configuration: configuration, danger: danger, colorScheme: colorScheme)
    }
}

private struct FlowIconButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let danger: Bool
    let colorScheme: ColorScheme
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        let highlighted = isEnabled && (hovering || configuration.isPressed)
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(danger ? theme.danger : highlighted ? theme.foreground : theme.muted)
            .frame(minWidth: 28, minHeight: 28)
            .background(highlighted ? (danger ? theme.danger.opacity(0.09) : theme.chipHigh) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(isFocused ? theme.foreground.opacity(0.28) : .clear, lineWidth: 1))
            .modifier(FlowControlFeedback(isPressed: configuration.isPressed, cornerRadius: 7))
            .opacity(isEnabled ? 1 : 0.38)
            .animation(reduceMotion ? nil : FlowMotion.hover, value: hovering)
            .onHover { hovering = $0 }
    }
}

extension Notification.Name {
    static let clipFlowFocusSearch = Notification.Name("clipFlow.focusSearch")
}
