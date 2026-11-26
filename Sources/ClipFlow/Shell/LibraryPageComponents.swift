import SwiftUI

struct LibrarySearchBar: View {
    @Binding var query: String
    let label: String
    let hint: String
    let onFocusChange: (Bool) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var searchFocused: Bool

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        HStack(spacing: 11) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(theme.muted)
                .accessibilityHidden(true)
            TextField(label + "…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(theme.foreground)
                .focused($searchFocused)
                .accessibilityLabel(label)
                .accessibilityHint(hint)
            KeyCap(text: "⌘F", muted: true)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .flowSearchField(theme, focused: searchFocused)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .onReceive(NotificationCenter.default.publisher(for: .clipFlowFocusSearch)) { _ in
            searchFocused = true
            onFocusChange(true)
        }
        .onChange(of: searchFocused, perform: onFocusChange)
    }
}

struct LibraryCategoryBar<Filters: View, Action: View>: View {
    let label: String
    @ViewBuilder let filters: () -> Filters
    @ViewBuilder let action: () -> Action
    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3, content: filters)
                    .padding(.leading, 13)
                    .padding(.trailing, 8)
                    .padding(.vertical, 8)
            }
            action()
        }
        .frame(height: 43)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

struct LibraryCreateButton: View {
    let label: String
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Divider()
            .overlay(ClipFlowTheme(scheme: colorScheme).hairline)
            .frame(height: 25)
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 10.5, weight: .semibold))
                Text("新建")
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .buttonStyle(GlassButtonStyle(kind: .primary))
        .fixedSize()
        .padding(.horizontal, 10)
        .help(label + "（⌘N）")
        .accessibilityLabel(label)
    }
}

struct LibraryBodyLayout<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        GeometryReader { proxy in
            content(proxy.size.width <= 720)
        }
        .frame(minHeight: 216, idealHeight: 412)
        .padding(.horizontal, 14)
        .padding(.bottom, 5)
    }
}

struct LibraryFooter: View {
    let returnLabel: String
    let secondaryHint: (String, String)
    let wideHint: (String, String)
    let count: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        GeometryReader { proxy in
            HStack(spacing: 12) {
                HStack(spacing: 13) {
                    footerHint("↑↓", "导航", theme: theme)
                    footerHint("↵", returnLabel, theme: theme)
                    if proxy.size.width > 520 {
                        footerHint(secondaryHint.0, secondaryHint.1, theme: theme)
                    }
                    if proxy.size.width > 720 {
                        footerHint(wideHint.0, wideHint.1, theme: theme)
                        footerHint("⌘,", "设置", theme: theme)
                    }
                }
                Spacer(minLength: 4)
                Text(count)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(maxHeight: .infinity)
            .background((colorScheme == .dark ? Color.white : Color.black).opacity(0.035))
        }
        .frame(height: 41)
    }

    private func footerHint(_ key: String, _ label: String, theme: ClipFlowTheme) -> some View {
        HStack(spacing: 5) {
            KeyCap(text: key)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(theme.muted)
        }
        .fixedSize()
        .accessibilityHidden(true)
    }
}

struct PromptLibraryDialogs: View {
    @ObservedObject var model: PromptLibraryModel
    let onSave: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if model.promptEditorOpen {
                PromptEditorView(model: model, onSave: onSave)
                    .transition(FlowMotion.reveal(reduceMotion: reduceMotion))
                    .zIndex(22)
            }
            if model.promptRunnerOpen {
                PromptRunnerView(model: model)
                    .transition(FlowMotion.reveal(reduceMotion: reduceMotion))
                    .zIndex(24)
            }
            if model.promptDeleteConfirmationOpen {
                PromptDeleteConfirmationView(model: model)
                    .transition(FlowMotion.reveal(reduceMotion: reduceMotion))
                    .zIndex(26)
            }
        }
        .animation(reduceMotion ? FlowMotion.reduced : FlowMotion.content, value: model.promptEditorOpen)
        .animation(reduceMotion ? FlowMotion.reduced : FlowMotion.content, value: model.promptRunnerOpen)
        .animation(reduceMotion ? FlowMotion.reduced : FlowMotion.content, value: model.promptDeleteConfirmationOpen)
    }
}

struct CredentialLibraryDialogs: View {
    @ObservedObject var model: CredentialLibraryModel

    var body: some View {
        ZStack {
            if model.credentialEditorOpen {
                CredentialEditorView(model: model).zIndex(28)
            }
            if model.credentialDeleteConfirmationOpen {
                CredentialDeleteConfirmationView(model: model).zIndex(30)
            }
        }
    }
}
