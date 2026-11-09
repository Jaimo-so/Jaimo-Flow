import SwiftUI
import Carbon

@MainActor
final class ScreenshotShortcutRecorder: ObservableObject {
    static var isRecording = false
    @Published var action: ScreenshotExtension.ShortcutAction?
    @Published var hint = "请按下 Control、Option 或 Command 与其他按键的组合；按 Esc 取消。"
    private var monitor: Any?
    private weak var screenshotExtension: ScreenshotExtension?

    func start(_ action: ScreenshotExtension.ShortcutAction, extension screenshotExtension: ScreenshotExtension) {
        cancel()
        self.action = action
        self.screenshotExtension = screenshotExtension
        hint = "请按下 Control、Option 或 Command 与其他按键的组合；按 Esc 取消。"
        Self.isRecording = true
        screenshotExtension.beginShortcutRecording()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.receive(event) }
            return nil
        }
    }

    private func receive(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { cancel(); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.control, .option, .command]).isEmpty else {
            hint = "请至少使用 Control、Option 或 Command 中的一个修饰键。"
            return
        }
        let special: [UInt16: String] = [UInt16(kVK_Space): "Space", UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥", UInt16(kVK_Delete): "⌫", UInt16(kVK_ForwardDelete): "⌦", UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→", UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓"]
        let character = event.charactersIgnoringModifiers ?? ""
        guard let label = special[event.keyCode] ?? (character.count == 1 && character.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && !(0xE000...0xF8FF).contains($0.value) } ? character.uppercased() : nil) else {
            hint = "请使用字母、数字、符号或常用按键。"
            return
        }
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        let shortcut = ScreenshotExtension.Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: label)
        guard let action, let screenshotExtension else { cancel(); return }
        cancel()
        screenshotExtension.setShortcut(shortcut, for: action)
    }

    func cancel() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        Self.isRecording = false
        action = nil
        screenshotExtension?.endShortcutRecording()
        screenshotExtension = nil
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    private let homeModel: HomeDashboardModel?
    @ObservedObject private var preferences: PreferencesStore
    @ObservedObject private var updater: UpdateManager
    @ObservedObject private var screenshotExtension: ScreenshotExtension
    @ObservedObject private var translationExtension: TranslationExtension
    @Environment(\.colorScheme) private var colorScheme
    @State private var clearArmed = false
    @State private var disarmWork: DispatchWorkItem?
    @State private var hoveredExcludedID: String?
    @State private var clearHover = false
    @StateObject private var shortcutRecorder = ScreenshotShortcutRecorder()
    @FocusState private var launchToggleFocused: Bool

    init(model: AppModel, homeModel: HomeDashboardModel? = nil) {
        self.model = model
        self.homeModel = homeModel
        preferences = model.preferences
        updater = model.updateManager
        screenshotExtension = model.screenshotExtension
        translationExtension = model.translationExtension
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
                                Picker("外观", selection: $preferences.appearance) {
                                    ForEach(FlowAppearance.allCases) { appearance in
                                        Text(appearance.title).tag(appearance)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 120)
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

                        if let homeModel {
                            settingsGroup(title: "首页照片", theme: theme) {
                                MirrorPhotoSettingsView(model: homeModel)
                            }
                        }

                        settingsGroup(title: "扩展", theme: theme) {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("截图与贴图").font(.system(size: 13, weight: .semibold))
                                    Text(screenshotExtension.installed ? (screenshotExtension.running ? "运行中" : "已停止") : "未安装")
                                        .font(.system(size: 11.5)).foregroundStyle(theme.muted)
                                }
                                Spacer()
                                if !screenshotExtension.installed {
                                    Button("安装并启动") { screenshotExtension.install() }
                                        .buttonStyle(GlassButtonStyle(kind: .primary))
                                } else {
                                    Button(screenshotExtension.running ? "停止" : "启动") {
                                        if screenshotExtension.running { screenshotExtension.stop() } else { screenshotExtension.start() }
                                    }.buttonStyle(GlassButtonStyle(kind: .normal))
                                    Button("卸载") { screenshotExtension.uninstall() }
                                        .buttonStyle(GlassButtonStyle(kind: .normal))
                                }
                            }.padding(.vertical, 7)
                            if screenshotExtension.installed {
                                Text("使用下方快捷键进行区域截图或将剪贴板图片贴到屏幕。拖动贴图可移动，双击关闭，右键可复制或关闭。")
                                    .font(.system(size: 11.5)).foregroundStyle(theme.muted)
                                    .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                                HStack {
                                    Button(shortcutRecorder.action == .capture ? "请按快捷键…" : "截图快捷键  \(screenshotExtension.captureShortcut.label)") {
                                        shortcutRecorder.start(.capture, extension: screenshotExtension)
                                    }
                                    Button(shortcutRecorder.action == .pin ? "请按快捷键…" : "贴图快捷键  \(screenshotExtension.pinShortcut.label)") {
                                        shortcutRecorder.start(.pin, extension: screenshotExtension)
                                    }
                                }
                                .buttonStyle(GlassButtonStyle(kind: .normal))
                                .padding(.top, 8)
                                if shortcutRecorder.action != nil {
                                    Text(shortcutRecorder.hint).font(.system(size: 11.5)).foregroundStyle(theme.muted)
                                }
                                Text("截图后可标注、复制、另存为 PNG 或直接贴图。首次使用请在系统设置中允许屏幕录制。")
                                    .font(.system(size: 11.5)).foregroundStyle(theme.muted)
                                    .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                            }
                            if let error = screenshotExtension.error {
                                Text(error).font(.system(size: 11.5)).foregroundStyle(theme.danger)
                                    .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                            }
                        }

                        settingsGroup(title: "识别与翻译", theme: theme) {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("截图识别与翻译").font(.system(size: 13, weight: .semibold))
                                    Text(translationExtension.installed ? (translationExtension.running ? "运行中" : "已停止") : "未安装")
                                        .font(.system(size: 11.5)).foregroundStyle(theme.muted)
                                }
                                Spacer()
                                if !translationExtension.installed {
                                    Button("安装并启动") { translationExtension.install() }.buttonStyle(GlassButtonStyle(kind: .primary))
                                } else {
                                    if translationExtension.running { Button("打开") { translationExtension.show() }.buttonStyle(GlassButtonStyle(kind: .normal)) }
                                    Button(translationExtension.running ? "停止" : "启动") {
                                        if translationExtension.running { translationExtension.stop() } else { translationExtension.start() }
                                    }.buttonStyle(GlassButtonStyle(kind: .normal))
                                    Button("卸载") { translationExtension.uninstall() }.buttonStyle(GlassButtonStyle(kind: .normal))
                                }
                            }.padding(.vertical, 7)
                            Text("⌃⌥S 截图识别并翻译，也可输入文字或读取图片。需要 macOS 15 及以上版本。")
                                .font(.system(size: 11.5)).foregroundStyle(theme.muted).fixedSize(horizontal: false, vertical: true)
                            if let error = translationExtension.error {
                                Text(error).font(.system(size: 11.5)).foregroundStyle(theme.danger).fixedSize(horizontal: false, vertical: true)
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
        .onDisappear { shortcutRecorder.cancel() }
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

private struct MirrorPhotoSettingsView: View {
    @ObservedObject var model: HomeDashboardModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        VStack(alignment: .leading, spacing: 10) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    if let url = model.mirrorPhotoURL {
                        CachedDiskImage(url: url, maxPixelSize: 900, contentMode: .fill)
                            .id(url)
                    } else {
                        Rectangle().fill(theme.chip)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay {
                    if model.isLoadingMirrorPhoto {
                        ProgressView().padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .accessibilityLabel("首页照片预览，横向 16 比 9")

            HStack(spacing: 8) {
                Button("随机换一张") {
                    Task { await model.randomizeMirrorPhoto() }
                }
                .buttonStyle(GlassButtonStyle(kind: .normal))
                Button("选择本地照片") { model.chooseMirrorPhoto() }
                    .buttonStyle(GlassButtonStyle(kind: .normal))
            }
            .disabled(model.isLoadingMirrorPhoto)

            Text("照片以 16:9 居中裁剪。随机照片需联网获取，选好后保存在本机。")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.mirrorPhotoError {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
