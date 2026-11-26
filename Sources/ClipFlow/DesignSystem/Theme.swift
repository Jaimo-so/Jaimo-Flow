import AppKit
import SwiftUI

enum WindowMetrics {
    static let cornerRadius: CGFloat = 30
    static let tileRadius: CGFloat = 24
}

private extension Color {
    init(rgb: UInt32) {
        self.init(.sRGB, red: Double(rgb >> 16) / 255,
                  green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}

struct ClipFlowTheme {
    let scheme: ColorScheme

    private func color(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(rgb: scheme == .dark ? dark : light)
    }

    var foreground: Color { color(0x192335, 0xF5F6FA) }
    var foregroundSecondary: Color { color(0x374256, 0xDBDDE5) }
    var muted: Color { color(0x536073, 0xB6B9C6) }
    var accent: Color { color(0x007AFF, 0x0A84FF) }
    var danger: Color { color(0xFF3B30, 0xFF453A) }
    var orange: Color { color(0xFF9500, 0xFF9F0A) }
    var star: Color { color(0xFFCC00, 0xFFD60A) }
    var green: Color { color(0x34C759, 0x30D158) }
    var purple: Color { color(0xAF52DE, 0xBF5AF2) }
    var cyan: Color { color(0x009EBC, 0x64D2FF) }

    var canvas: Color { color(0xF8FAFF, 0x101117) }
    var card: Color { color(0xFFFFFF, 0x262831) }
    var glass: Color { canvas.opacity(0.97) } // Floating dialogs must mask underlying text.
    var glassSecondary: Color { card.opacity(scheme == .dark ? 0.88 : 0.74) }
    var chip: Color { scheme == .dark ? .white.opacity(0.075) : .white.opacity(0.48) }
    var chipHigh: Color { scheme == .dark ? .white.opacity(0.15) : .white.opacity(0.84) }
    var inset: Color { scheme == .dark ? .black.opacity(0.19) : .white.opacity(0.46) }
    var hairline: Color { foreground.opacity(scheme == .dark ? 0.14 : 0.12) }
    var weakHairline: Color { foreground.opacity(0.08) }
    var accentWash: Color { accent.opacity(scheme == .dark ? 0.22 : 0.12) }
    var selection: Color { accentWash }
    var skeleton: Color { foreground.opacity(0.07) }
    var skeletonHigh: Color { foreground.opacity(0.13) }

    var highlight: LinearGradient {
        LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.22 : 0.98),
                                .white.opacity(scheme == .dark ? 0.07 : 0.34)],
                       startPoint: .top, endPoint: .bottom)
    }

    // Composite the light tints first, then set opacity once to preserve the desktop material.
    @ViewBuilder var windowWash: some View {
        if scheme == .dark {
            LinearGradient(colors: [Color(rgb: 0x10141E), canvas, Color(rgb: 0x18141D)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .opacity(0.84)
        } else {
            ZStack {
                LinearGradient(colors: [Color(rgb: 0xB4E9FF), Color(rgb: 0xE8F3FF), Color(rgb: 0xFFDDF6)],
                               startPoint: .topLeading, endPoint: .topTrailing)
                EllipticalGradient(colors: [Color(rgb: 0xC6F9ED), .clear], center: .bottom,
                                   startRadiusFraction: 0.04, endRadiusFraction: 0.80)
                LinearGradient(colors: [.white.opacity(0.06), .white.opacity(0.38)],
                               startPoint: .top, endPoint: .bottom)
            }
            .compositingGroup()
            .opacity(0.58)
        }
    }

    func tileFill(tint: Color) -> LinearGradient {
        LinearGradient(colors: scheme == .dark
                       ? [tint.opacity(0.17), tint.opacity(0.07)]
                       : [.white.opacity(0.74), .white.opacity(0.48)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension View {
    /// Draw the rim inside the surface so clipped or adjacent controls keep their edge.
    func flowGlass<S: InsettableShape, F: ShapeStyle>(_ shape: S, fill: F, theme: ClipFlowTheme) -> some View {
        self.background(shape.fill(fill))
            .clipShape(shape)
            .overlay { shape.strokeBorder(theme.highlight, lineWidth: 1).allowsHitTesting(false) }
    }

    func flowCard(_ theme: ClipFlowTheme) -> some View {
        flowGlass(RoundedRectangle(cornerRadius: 20, style: .continuous), fill: theme.glassSecondary, theme: theme)
    }

    func flowInset(_ theme: ClipFlowTheme) -> some View {
        flowGlass(RoundedRectangle(cornerRadius: 14, style: .continuous), fill: theme.inset, theme: theme)
    }

    func flowSearchField(_ theme: ClipFlowTheme, focused: Bool) -> some View {
        flowGlass(Capsule(), fill: theme.chip, theme: theme)
            .overlay { Capsule().strokeBorder(focused ? theme.accent : .clear).allowsHitTesting(false) }
    }

    func flowFilter(_ theme: ClipFlowTheme, selected: Bool) -> some View {
        flowGlass(Capsule(), fill: selected ? theme.selection : theme.chip, theme: theme)
    }
}

struct FlowWindowBackground: View {
    let theme: ClipFlowTheme

    var body: some View {
        ZStack {
            VisualEffectBackground()
            theme.windowWash
        }
        .allowsHitTesting(false)
        .transaction {
            $0.animation = nil
            $0.disablesAnimations = true
        }
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view, scheme: context.environment.colorScheme)
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        configure(nsView, scheme: context.environment.colorScheme)
    }

    private func configure(_ view: NSVisualEffectView, scheme: ColorScheme) {
        let name: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
        if view.appearance?.name != name { view.appearance = NSAppearance(named: name) }
        view.material = scheme == .dark ? .hudWindow : .popover
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
            .flowGlass(Capsule(), fill: theme.chip, theme: theme)
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
            .flowGlass(Capsule(), fill: background(theme: theme).gradient, theme: theme)
            .shadow(color: kind == .primary ? theme.accent.opacity(0.22) : .black.opacity(0.05),
                    radius: kind == .primary ? 4 : 2, y: 2)
            .overlay { Capsule().strokeBorder(isFocused ? theme.foregroundSecondary : .clear) }
            .contentShape(Capsule())
            .modifier(FlowControlFeedback(isPressed: configuration.isPressed))
            .opacity(isEnabled ? 1 : 0.38)
            .animation(reduceMotion ? nil : FlowMotion.hover, value: hovering)
            .onHover { hovering = $0 }
    }

    private func background(theme: ClipFlowTheme) -> Color {
        let highlighted = isEnabled && (hovering || configuration.isPressed)
        switch kind {
        case .normal: return highlighted ? theme.chipHigh : theme.chip
        case .primary: return theme.accent.opacity(highlighted ? 0.85 : 1)
        case .quiet: return highlighted ? theme.chip : theme.inset
        case .danger: return theme.danger.opacity(highlighted ? 0.15 : 0.07)
        }
    }

    private func foreground(theme: ClipFlowTheme) -> Color {
        switch kind {
        case .primary: return .white
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
            .flowGlass(Circle(), fill: highlighted ? theme.chipHigh : theme.chip, theme: theme)
            .overlay { Circle().strokeBorder(isFocused ? theme.foregroundSecondary : .clear) }
            .contentShape(Circle())
            .modifier(FlowControlFeedback(isPressed: configuration.isPressed))
            .opacity(isEnabled ? 1 : 0.38)
            .animation(reduceMotion ? nil : FlowMotion.hover, value: hovering)
            .onHover { hovering = $0 }
    }
}

extension Notification.Name {
    static let clipFlowFocusSearch = Notification.Name("clipFlow.focusSearch")
}
