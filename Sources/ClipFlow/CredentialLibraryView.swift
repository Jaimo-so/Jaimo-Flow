import ClipFlowKit
import SwiftUI

struct CredentialLibraryView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        VStack(spacing: 0) {
            if let error = model.credentialError {
                Spacer()
                Image(systemName: "lock.trianglebadge.exclamationmark")
                    .font(.system(size: 28))
                Text("无法读取钥匙串").font(.headline)
                Text(error).font(.caption).foregroundStyle(theme.muted)
                Button("重试", action: model.loadCredentials)
                Spacer()
            } else if model.filteredCredentials.isEmpty {
                Spacer()
                Image(systemName: "key.horizontal")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(theme.muted)
                    .padding(.bottom, 10)
                Text(model.query.isEmpty ? "保存常用的 API Key 和密码" : "没有匹配的名称")
                    .font(.system(size: 16, weight: .medium))
                Text(model.query.isEmpty ? "为每条内容起个名称，使用时一键复制。" : "试试其他名称，或清空搜索。")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.muted)
                    .padding(.top, 6)
                if model.query.isEmpty {
                    Button("新建 API Key / 密码", action: model.beginCreateCredential)
                        .padding(.top, 16)
                }
                Spacer()
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(model.filteredCredentials) { entry in
                                HStack(spacing: 12) {
                                    Button {
                                        model.selectedCredentialID = entry.id
                                        model.focusArea = .other
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: "key.horizontal")
                                                .frame(width: 34, height: 34)
                                                .background(theme.chip)
                                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                            VStack(alignment: .leading, spacing: 5) {
                                                Text(entry.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                                Text("••••••••••••")
                                                    .font(.system(size: 12, design: .monospaced))
                                                    .foregroundStyle(theme.muted)
                                                    .accessibilityLabel("内容已隐藏")
                                            }
                                            Spacer(minLength: 0)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityAddTraits(model.selectedCredential?.id == entry.id ? [.isSelected] : [])
                                    Button {
                                        model.selectedCredentialID = entry.id
                                        model.copyCredential()
                                    } label: { Image(systemName: "doc.on.doc") }
                                    .help("复制 API Key / 密码")
                                    .accessibilityLabel("复制 \(entry.title)")
                                    Button {
                                        model.selectedCredentialID = entry.id
                                        model.beginEditCredential()
                                    } label: { Image(systemName: "pencil") }
                                    .help("编辑")
                                    .accessibilityLabel("编辑 \(entry.title)")
                                    Button {
                                        model.selectedCredentialID = entry.id
                                        model.deleteSelected()
                                    } label: { Image(systemName: "trash") }
                                    .help("删除")
                                    .accessibilityLabel("删除 \(entry.title)")
                                }
                                .buttonStyle(.borderless)
                                .padding(12)
                                .background(model.selectedCredential?.id == entry.id ? theme.selection : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .id(entry.id)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: model.selectedCredentialID) { id in
                        if let id { reader.scrollTo(id) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(theme.foreground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("API Key 分组")
    }
}

struct CredentialEditorView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var revealSecret = false
    @State private var generatorOpen = false
    @FocusState private var titleFocused: Bool
    @AppStorage("credentialGenerator.length") private var generatorLength = PasswordOptions.default.length
    @AppStorage("credentialGenerator.uppercase") private var generatorUppercase = true
    @AppStorage("credentialGenerator.lowercase") private var generatorLowercase = true
    @AppStorage("credentialGenerator.digits") private var generatorDigits = true
    @AppStorage("credentialGenerator.symbols") private var generatorSymbols = true
    @AppStorage("credentialGenerator.excludeAmbiguous") private var generatorExcludeAmbiguous = true

    private var generatorOptions: PasswordOptions {
        PasswordOptions(
            length: generatorLength,
            includeUppercase: generatorUppercase,
            includeLowercase: generatorLowercase,
            includeDigits: generatorDigits,
            includeSymbols: generatorSymbols,
            excludeAmbiguous: generatorExcludeAmbiguous
        )
    }

    private func fillGeneratedPassword() {
        model.credentialDraftSecret = PasswordGenerator.generate(generatorOptions)
        // Show the generated value so the user can see what will be saved.
        revealSecret = true
    }

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        ZStack {
            Color.black.opacity(0.3)
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "key.horizontal")
                    Text(model.editingCredentialID == nil ? "新建 API Key / 密码" : "编辑 API Key / 密码")
                        .font(.system(size: 17, weight: .semibold))
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("名称").font(.system(size: 12, weight: .medium))
                    TextField("例如：开发环境 API Key、邮箱密码", text: $model.credentialDraftTitle)
                        .textFieldStyle(.roundedBorder)
                        .focused($titleFocused)
                        .accessibilityLabel("名称")
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("API Key / 密码").font(.system(size: 12, weight: .medium))
                    HStack {
                        Group {
                            if revealSecret {
                                TextField("输入内容", text: $model.credentialDraftSecret)
                            } else {
                                SecureField("输入内容", text: $model.credentialDraftSecret)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("API Key / 密码")
                        Button { revealSecret.toggle() } label: {
                            Image(systemName: revealSecret ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                        .help(revealSecret ? "隐藏内容" : "显示内容")
                        .accessibilityLabel(revealSecret ? "隐藏内容" : "显示内容")
                        Button { generatorOpen.toggle() } label: {
                            Image(systemName: "wand.and.stars")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(generatorOpen ? theme.accent : theme.foreground)
                        .help("生成随机密码")
                        .accessibilityLabel("生成随机密码")
                    }
                    secretStatus(theme: theme)
                }
                if generatorOpen {
                    generatorPanel(theme: theme)
                }
                Text("保存在本机 macOS 钥匙串中。")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.muted)
                HStack {
                    Spacer()
                    Button("取消", action: model.cancelCredentialEditor)
                    Button("保存", action: model.saveCredentialDraft)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.credentialDraftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.credentialDraftSecret.isEmpty)
                }
            }
            .padding(24)
            .frame(maxWidth: 440)
            .background(theme.glass)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.hairline, lineWidth: 0.5))
            .padding(20)
        }
        .onAppear { titleFocused = true }
    }

    /// Character count, rough strength and a warning for stray leading/trailing whitespace.
    @ViewBuilder
    private func secretStatus(theme: ClipFlowTheme) -> some View {
        let secret = model.credentialDraftSecret
        if !secret.isEmpty {
            let inspection = SecretInspector.inspect(secret)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    HStack(spacing: 3) {
                        ForEach(SecretStrength.allCases, id: \.self) { level in
                            Capsule()
                                .fill(level <= inspection.strength ? strengthColor(inspection.strength, theme: theme) : theme.chipHigh)
                                .frame(width: 18, height: 4)
                        }
                    }
                    .accessibilityHidden(true)
                    Text("强度：\(inspection.strength.label) · \(inspection.characterCount) 个字符")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.muted)
                        .help("按长度和字符种类粗略估算，约 \(inspection.estimatedBits) 位熵；API Key 通常由服务方随机生成，可忽略强度提示。")
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                if let warning = inspection.whitespaceWarning {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(warning)
                        if inspection.hasEdgeWhitespace {
                            Button("去除首尾空白") {
                                model.credentialDraftSecret = SecretInspector.trimmedEdges(secret)
                            }
                            .buttonStyle(.link)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(theme.danger)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func strengthColor(_ strength: SecretStrength, theme: ClipFlowTheme) -> Color {
        switch strength {
        case .weak: return theme.danger
        case .fair: return theme.star
        case .strong, .veryStrong: return theme.accent
        }
    }

    private func generatorPanel(theme: ClipFlowTheme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("长度").font(.system(size: 12, weight: .medium))
                Slider(
                    value: Binding(
                        get: { Double(generatorLength) },
                        set: { generatorLength = PasswordOptions.clampLength(Int($0.rounded())) }
                    ),
                    in: Double(PasswordOptions.lengthRange.lowerBound)...Double(PasswordOptions.lengthRange.upperBound),
                    step: 1
                )
                .accessibilityLabel("密码长度")
                .accessibilityValue("\(generatorLength) 位")
                Text("\(generatorLength)")
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 24, alignment: .trailing)
            }
            HStack(spacing: 12) {
                Toggle("A-Z", isOn: $generatorUppercase)
                Toggle("a-z", isOn: $generatorLowercase)
                Toggle("0-9", isOn: $generatorDigits)
                Toggle("符号", isOn: $generatorSymbols)
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            Toggle("排除易混淆字符（0/O、1/l/I 等）", isOn: $generatorExcludeAmbiguous)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            HStack {
                if !generatorOptions.hasAnyCharacterSet {
                    Text("未选择字符类型，将使用小写字母和数字")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.muted)
                }
                Spacer()
                Button(model.credentialDraftSecret.isEmpty ? "生成并填入" : "重新生成并替换", action: fillGeneratedPassword)
                    .help("生成随机密码并填入上方输入框")
            }
        }
        .padding(12)
        .background(theme.chip)
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

struct CredentialDeleteConfirmationView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        ZStack {
            Color.black.opacity(0.3)
            VStack(alignment: .leading, spacing: 16) {
                Text("删除 API Key / 密码？").font(.headline)
                Text("将从钥匙串中删除「\(model.selectedCredential?.title ?? "")」，删除后无法恢复。")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.muted)
                HStack {
                    Spacer()
                    Button("取消") { model.credentialDeleteConfirmationOpen = false }
                    Button("删除", role: .destructive, action: model.confirmDeleteCredential)
                }
            }
            .padding(24)
            .frame(maxWidth: 400)
            .background(theme.glass)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(20)
        }
    }
}
