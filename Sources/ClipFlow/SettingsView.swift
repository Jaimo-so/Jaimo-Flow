import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var preferences: PreferencesStore
    @ObservedObject private var updater: UpdateManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var clearArmed = false
    @State private var disarmWork: DispatchWorkItem?
    @State private var hoveredExcludedID: String?
    @State private var clearHover = false
    @FocusState private var launchToggleFocused: Bool

    init(model: AppModel) {
        self.model = model
        preferences = model.preferences
        updater = model.updateManager
    }

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack {
                    Text("偏好设置")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    KeyCap(text: "ESC 关闭", muted: true)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 16)
                .frame(height: 51)
                Divider().overlay(theme.hairline)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        settingsGroup(title: "通用", theme: theme) {
                            settingRow("开机自动启动", theme: theme) {
                                Toggle("开机自动启动", isOn: launchAtLoginBinding)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                    .tint(theme.accent)
                                    .focused($launchToggleFocused)
                            }
                            rowDivider(theme)
                            settingRow("唤起快捷键", theme: theme) {
                                HStack(spacing: 4) { KeyCap(text: "⌥"); KeyCap(text: "Space") }
                            }
                            rowDivider(theme)
                            settingRow("历史记录上限", theme: theme) {
                                valueText("\(AppModel.historyLimit) 条", theme: theme)
                            }
                            rowDivider(theme)
                            settingRow("外观", theme: theme) {
                                valueText("跟随系统", theme: theme)
                            }
                            rowDivider(theme)
                            settingRow("复制后关闭窗口", theme: theme) {
                                Toggle("复制后关闭窗口", isOn: $preferences.closeAfterCopy)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                    .tint(theme.accent)
                            }
                        }

                        settingsGroup(title: "软件更新", theme: theme) {
                            settingRow("当前版本", theme: theme) {
                                Text("\(updater.currentVersion)（\(updater.currentBuild)）")
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .foregroundStyle(theme.muted)
                            }
                            rowDivider(theme)

                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(updater.statusText)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(
                                            updater.errorMessage == nil
                                                ? theme.foregroundSecondary
                                                : theme.danger.opacity(0.95)
                                        )
                                    Text("更新源：\(updater.repositoryLabel)")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(theme.muted)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                if updater.isBusy {
                                    ProgressView()
                                        .controlSize(.small)
                                        .accessibilityLabel(updater.statusText)
                                }
                                Button(updater.actionTitle) {
                                    updater.performPrimaryAction()
                                }
                                .buttonStyle(
                                    GlassButtonStyle(
                                        kind: updater.hasAvailableUpdate ? .primary : .normal
                                    )
                                )
                                .fixedSize()
                                .disabled(updater.isBusy)
                            }
                            .padding(.vertical, 8)

                            if let error = updater.errorMessage {
                                Text(error)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(theme.danger.opacity(0.95))
                                    .lineSpacing(5)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityLabel("更新错误：\(error)")
                            } else {
                                Text("新版本会先校验 SHA-256、应用标识、arm64 架构与代码签名，验证通过后才会安装并重新启动。")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(theme.muted)
                                    .lineSpacing(5)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        settingsGroup(title: "隐私", theme: theme) {
                            settingRow("仅保存在本机", theme: theme) {
                                valueText("已启用 · 无云同步", theme: theme)
                            }

                            Text("排除的应用")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.muted)
                                .padding(.top, 10)
                                .padding(.bottom, 1)

                            if preferences.excludedApps.isEmpty {
                                Text("当前没有排除的应用")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(theme.muted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 8)
                            } else {
                                ForEach(preferences.excludedApps) { app in
                                    HStack(spacing: 9) {
                                        Text(app.name)
                                            .font(.system(size: 12.5))
                                            .foregroundStyle(theme.foreground)
                                        Spacer()
                                        Button {
                                            preferences.removeExcludedApp(app)
                                            model.showToast("已将 \(app.name) 移出排除列表")
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 11, weight: .semibold))
                                                .frame(width: 24, height: 24)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(
                                            hoveredExcludedID == app.id ? theme.danger.opacity(0.95) : theme.muted
                                        )
                                        .background(
                                            hoveredExcludedID == app.id
                                                ? theme.danger.opacity(0.16)
                                                : Color.clear
                                        )
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                        .onHover { hovering in
                                            hoveredExcludedID = hovering ? app.id : nil
                                        }
                                        .accessibilityLabel("移除 \(app.name)")
                                    }
                                    .padding(.leading, 9)
                                    .padding(.trailing, 4)
                                    .padding(.vertical, 3)
                                    .background((colorScheme == .dark ? Color.white : Color.black).opacity(0.055))
                                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.weakHairline, lineWidth: 0.5))
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                                }
                            }

                            Button(action: handleClear) {
                                Text(clearArmed ? "确认清空？再次点击执行" : "清空所有历史记录")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(clearArmed ? theme.foreground : theme.danger.opacity(0.92))
                                    .padding(.horizontal, 13)
                                    .frame(minHeight: 30)
                                    .background(
                                        theme.danger.opacity(clearArmed ? 0.34 : clearHover ? 0.30 : 0.16)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7)
                                            .stroke(theme.danger.opacity(clearArmed ? 0.60 : 0.34), lineWidth: 0.5)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                            .onHover { clearHover = $0 }
                            .padding(.top, 7)
                            .accessibilityHint("点击后需要在八秒内再次确认")

                            Text(clearHint)
                                .font(.system(size: 11.5))
                                .foregroundStyle(theme.muted)
                                .lineSpacing(7.5)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
            }
            .frame(maxWidth: 472, maxHeight: 510)
            .background(VisualEffectBackground())
            .background(theme.glass.opacity(0.98))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke((colorScheme == .dark ? Color.white : Color.black).opacity(0.20), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.65), radius: 46, y: 24)
            .padding(32)
            .focusSection()
            .onTapGesture { }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("偏好设置")
        .onAppear {
            DispatchQueue.main.async { launchToggleFocused = true }
            if case .idle = updater.state { updater.checkForUpdates() }
        }
        .onDisappear(perform: disarmClear)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { preferences.launchAtLoginEnabled },
            set: { enabled in
                do {
                    try preferences.setLaunchAtLogin(enabled)
                } catch {
                    model.showToast("开机启动设置失败，请将 Jaimo Flow 移到应用程序文件夹后重试")
                }
            }
        )
    }

    private var clearHint: String {
        if clearArmed {
            return "将永久删除全部 \(model.items.count) 条历史记录（含收藏），不会删除提示词。8 秒内未确认将自动取消。"
        }
        return "此操作不可撤销，历史收藏也会一并删除，但提示词库会保留。点击后需再次确认。"
    }

    private func settingsGroup<Content: View>(
        title: String,
        theme: ClipFlowTheme,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.88)
                .foregroundStyle(theme.foregroundSecondary)
                .padding(.bottom, 8)
            content()
        }
    }

    private func settingRow<Trailing: View>(
        _ title: String,
        theme: ClipFlowTheme,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(theme.foreground)
            Spacer(minLength: 0)
            trailing()
        }
        .frame(minHeight: 35)
    }

    private func rowDivider(_ theme: ClipFlowTheme) -> some View {
        Rectangle().fill(theme.weakHairline).frame(height: 0.5)
    }

    private func valueText(_ text: String, theme: ClipFlowTheme) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(theme.muted)
    }

    private func handleClear() {
        if clearArmed {
            disarmClear()
            _ = model.clearHistory()
            return
        }

        clearArmed = true
        disarmWork?.cancel()
        let work = DispatchWorkItem { disarmClear() }
        disarmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func disarmClear() {
        disarmWork?.cancel()
        disarmWork = nil
        clearArmed = false
    }

    private func close() {
        disarmClear()
        model.settingsOpen = false
    }
}
