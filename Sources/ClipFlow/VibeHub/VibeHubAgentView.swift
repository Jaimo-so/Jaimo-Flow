import SwiftUI

private struct VibeHubAgentPanel<Content: View>: View {
    let title: String
    let subtitle: String
    let onClose: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.35).onTapGesture(perform: onClose)
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title).font(.system(size: 16, weight: .semibold))
                            Text(subtitle).font(.system(size: 11)).foregroundStyle(theme.muted)
                        }
                        Spacer(minLength: 0)
                        Button(action: onClose) { Image(systemName: "xmark") }
                            .buttonStyle(FlowIconButtonStyle()).accessibilityLabel("关闭\(title)")
                    }.padding(16)
                    Divider().overlay(theme.hairline)
                    content
                }
                .frame(width: min(620, proxy.size.width - 24), height: min(530, proxy.size.height - 24))
                .background(theme.canvas)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.hairline, lineWidth: 0.7))
                .shadow(color: .black.opacity(0.25), radius: 25, y: 12)
                .contentShape(Rectangle()).onTapGesture { }
            }
        }
    }
}

struct VibeHubAgentComposer: View {
    @ObservedObject var agent: VibeHubAgentModel
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var inputFocused: Bool

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        VibeHubAgentPanel(title: "Agent 整理新话术", subtitle: "自动分类与补全，先预览再手动保存", onClose: agent.dismissPanel) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(agent.isConfigured ? "模型：\(agent.configuration.model)" : "先连接你的模型服务")
                            .font(.system(size: 12, weight: .medium)).lineLimit(1)
                        if agent.isConfigured {
                            Text("本次话术发送到 \(agent.serviceHost)，完成后先预览补全内容。")
                                .font(.system(size: 11)).foregroundStyle(theme.muted)
                        }
                    }
                    Spacer(minLength: 0)
                    Button(agent.isConfigured ? "设置" : "配置 API", action: agent.openSettings)
                        .buttonStyle(GlassButtonStyle(kind: .normal)).fixedSize().disabled(agent.isRunning)
                }
                Text("粘贴或输入你新学到的话术")
                    .font(.system(size: 12, weight: .medium))
                TextEditor(text: $agent.input)
                    .font(.system(size: 13)).lineSpacing(5)
                    .scrollContentBackground(.hidden).padding(8)
                    .background(theme.chip).clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(minHeight: 80, maxHeight: .infinity)
                    .focused($inputFocused).disabled(agent.isRunning)
                    .accessibilityLabel("待整理的新话术")
                if agent.isRunning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在分类并补全标题、标签、场景与含义…")
                            .font(.system(size: 11)).foregroundStyle(theme.muted)
                    }.accessibilityElement(children: .combine)
                } else if let message = agent.errorMessage {
                    Text(message).font(.system(size: 11)).foregroundStyle(theme.danger)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                } else {
                    Text("完整原文会原样保留；场景、定义和意义分别填写。")
                        .font(.system(size: 11)).foregroundStyle(theme.muted)
                }
                HStack(spacing: 10) {
                    if agent.reviewDraft != nil && !agent.isRunning {
                        Button("继续预览", action: agent.continuePreview)
                            .buttonStyle(GlassButtonStyle(kind: .quiet)).fixedSize()
                    }
                    Spacer(minLength: 0)
                    if agent.isRunning {
                        Button("取消整理", action: agent.cancel)
                            .buttonStyle(GlassButtonStyle(kind: .normal)).fixedSize()
                    } else {
                        Button("关闭", action: agent.dismissPanel)
                            .buttonStyle(GlassButtonStyle(kind: .quiet)).fixedSize()
                    }
                    Button(action: agent.organizeForPreview) {
                        Label("整理并预览", systemImage: "sparkles")
                    }
                    .buttonStyle(GlassButtonStyle(kind: .primary)).fixedSize()
                    .disabled(agent.isRunning || !agent.isConfigured || agent.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("整理并预览（⌘Return）")
                }
            }.padding(16)
        }
        .onAppear { inputFocused = true }
    }
}

struct VibeHubAgentPreview: View {
    @ObservedObject var agent: VibeHubAgentModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        VibeHubAgentPanel(title: "预览补全内容", subtitle: "逐项查看和修改，确认后手动保存到 Vibehub", onClose: agent.dismissPanel) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("标题").font(.system(size: 12, weight: .medium))
                            TextField("话术标题", text: binding(\.title, default: ""))
                                .textFieldStyle(.plain).font(.system(size: 14, weight: .medium))
                                .padding(10).background(theme.chip).clipShape(RoundedRectangle(cornerRadius: 8))
                                .accessibilityLabel("预览话术标题")
                        }
                        Picker("分类", selection: binding(\.category, default: .uncategorized)) {
                            ForEach(VibeHubCategory.allCases) { Text($0.rawValue).tag($0) }
                        }.accessibilityLabel("预览话术分类")
                        VStack(alignment: .leading, spacing: 6) {
                            Text("标签").font(.system(size: 12, weight: .medium))
                            TextField("用逗号或顿号分隔", text: binding(\.tags, default: ""))
                                .textFieldStyle(.plain).font(.system(size: 13))
                                .padding(10).background(theme.chip).clipShape(RoundedRectangle(cornerRadius: 8))
                                .accessibilityLabel("预览话术标签")
                        }
                        textSection("话术原文", keyPath: \.phrase, height: 130, theme: theme)
                        textSection("适用场景", keyPath: \.scenario, height: 130, theme: theme)
                        textSection("术语与含义", keyPath: \.meaning, height: 220, theme: theme)
                    }.padding(16)
                }
                Divider().overlay(theme.hairline)
                VStack(alignment: .leading, spacing: 10) {
                    if let error = agent.errorMessage {
                        Text(error).font(.system(size: 11)).foregroundStyle(theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("尚未加入话术库。关闭将清空本次内容，不保存草稿。")
                            .font(.system(size: 11)).foregroundStyle(theme.muted)
                    }
                    HStack(spacing: 10) {
                        Button("返回输入", action: agent.returnToInput)
                            .buttonStyle(GlassButtonStyle(kind: .quiet)).fixedSize()
                        Spacer(minLength: 0)
                        Button("关闭", action: agent.dismissPanel)
                            .buttonStyle(GlassButtonStyle(kind: .quiet)).fixedSize()
                        Button("保存到 Vibehub", action: agent.saveReviewedPhrase)
                            .buttonStyle(GlassButtonStyle(kind: .primary)).fixedSize()
                            .disabled(agent.reviewDraft == nil).help("保存预览内容（⌘Return）")
                    }
                }.padding(16)
            }
        }
    }

    private func textSection(_ title: String, keyPath: WritableKeyPath<VibeHubAgentDraft, String>, height: CGFloat, theme: ClipFlowTheme) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium))
            TextEditor(text: binding(keyPath, default: ""))
                .font(.system(size: 13)).lineSpacing(5).scrollContentBackground(.hidden)
                .padding(8).frame(height: height)
                .background(theme.chip).clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("预览\(title)")
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<VibeHubAgentDraft, Value>, default fallback: Value) -> Binding<Value> {
        Binding(get: { agent.reviewDraft?[keyPath: keyPath] ?? fallback },
                set: { value in
                    guard var draft = agent.reviewDraft else { return }
                    draft[keyPath: keyPath] = value
                    agent.reviewDraft = draft
                })
    }
}

struct VibeHubAgentSettingsView: View {
    @ObservedObject var agent: VibeHubAgentModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = ClipFlowTheme(scheme: colorScheme)
        VibeHubAgentPanel(title: "Agent 设置", subtitle: "连接支持 OpenAI 兼容接口的模型服务", onClose: agent.dismissPanel) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        inputField("接口地址", hint: "填写服务商的 Base URL，或完整的 /chat/completions 地址。", theme: theme) {
                            TextField("https://你的服务地址/v1", text: $agent.draftBaseURL)
                                .textFieldStyle(.plain).accessibilityLabel("Agent 接口地址")
                        }
                        inputField("模型名称", hint: "填写该服务中可调用的模型标识。", theme: theme) {
                            TextField("模型标识", text: $agent.draftModel)
                                .textFieldStyle(.plain).accessibilityLabel("Agent 模型名称")
                        }
                        inputField("API Key", hint: agent.hasAPIKey ? "已保存到钥匙串；留空沿用，填写新值可替换。" : "API Key 保存在本机 macOS 钥匙串中。", theme: theme) {
                            SecureField(agent.hasAPIKey ? "已保存，留空沿用" : "输入 API Key", text: $agent.draftAPIKey)
                                .textFieldStyle(.plain).accessibilityLabel("Agent API Key")
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Toggle("接口支持 JSON 模式", isOn: $agent.draftJSONMode)
                                .toggleStyle(.checkbox).font(.system(size: 12))
                            Text("如服务不支持 JSON 模式，可关闭；Agent 仍会按固定字段整理，应用会校验结果。")
                                .font(.system(size: 11)).foregroundStyle(theme.muted)
                        }
                        if let error = agent.settingsError {
                            Text(error).font(.system(size: 11)).foregroundStyle(theme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(16)
                }
                Divider().overlay(theme.hairline)
                HStack(spacing: 10) {
                    Spacer()
                    Button("取消", action: agent.dismissPanel)
                        .buttonStyle(GlassButtonStyle(kind: .quiet)).fixedSize()
                    Button("保存设置") { agent.saveSettings() }
                        .buttonStyle(GlassButtonStyle(kind: .primary)).fixedSize()
                        .help("保存设置（⌘Return）")
                }.padding(16)
            }
        }
    }

    private func inputField<Field: View>(_ title: String, hint: String, theme: ClipFlowTheme, @ViewBuilder field: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium))
            field().font(.system(size: 13)).padding(10)
                .background(theme.chip).clipShape(RoundedRectangle(cornerRadius: 8))
            Text(hint).font(.system(size: 11)).foregroundStyle(theme.muted)
        }
    }
}
