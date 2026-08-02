import SwiftUI
import ChunlandCore

// 「AI 助手」tab：在可复用聊天主体（AIChatView）外包一层 ——
// 历史会话抽屉 + 导航栏（新对话 / AI 配置）+ 会话 bootstrap。
struct AIView: View {
    @EnvironmentObject var orchestrator: AIOrchestrator
    @EnvironmentObject var auth: AuthManager
    @State private var showSetup = false
    @State private var drawerOpen = false

    var body: some View {
        // 游客模式：AI 是账号类功能（配置/会话绑用户，系统 AI 凭据端点亦需鉴权），未登录显示 CTA。
        // 登录后 chatScreen 子树挂载，其 .task 触发 orchestrator.bootstrap()。
        if auth.isLoggedIn {
            ConversationDrawerContainer(isOpen: $drawerOpen) {
                chatScreen
            }
        } else {
            GuestGate(title: "登录后使用 AI 助手",
                      message: "AI 助手需登录后使用",
                      systemImage: "sparkles")
        }
    }

    private var chatScreen: some View {
        AIChatView(onConfigure: { showSetup = true })
            .navigationTitle("AI 助手")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { drawerOpen.toggle() } label: {
                        Image(systemName: "line.3.horizontal")
                    }
                    .accessibilityLabel("历史对话")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            orchestrator.startNewConversation()
                        } label: {
                            Label("新对话", systemImage: "square.and.pencil")
                        }
                        Button {
                            showSetup = true
                        } label: {
                            Label("AI 配置", systemImage: "slider.horizontal.3")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .task { orchestrator.bootstrap() }
            .sheet(isPresented: $showSetup) {
                AISetupSheet()
                    .environmentObject(orchestrator)
                    .environmentObject(auth)
            }
    }
}

// MARK: - AI Setup Sheet

struct AISetupSheet: View {
    @EnvironmentObject var orchestrator: AIOrchestrator
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) var dismiss

    private enum AISource { case system, custom }

    @State private var baseUrl = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var showKey = false
    @State private var selection: AISource?    // 当前生效来源（nil = 尚未配置）；选择态即生效态
    @State private var customExpanded = false  // 自定义未配置时点击其行 → 仅展开表单引导填写

    // 已保存快照：保存按钮只在「字段被编辑过」时可点，未编辑时显示「已保存」禁用（即保存反馈）
    @State private var persistedBaseUrl = ""
    @State private var persistedModel = ""
    @State private var persistedApiKey = ""

    private var customFieldsComplete: Bool {
        !baseUrl.isEmpty && !model.isEmpty && !apiKey.isEmpty
    }

    private var customDirty: Bool {
        baseUrl != persistedBaseUrl || model != persistedModel || apiKey != persistedApiKey
    }

    private var showCustomFields: Bool {
        !SystemAIProvider.isIntegrated || selection == .custom || customExpanded
    }

    var body: some View {
        NavigationStack {
            Form {
                // 来源勾选列表（iOS 设置惯用形态）：勾在哪、哪个生效，点击立即生效。
                // 仅当本机 AI 服务接入时显示；未接入时整页退化为纯自定义表单。
                if SystemAIProvider.isIntegrated {
                    Section {
                        Button {
                            selectSystem()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("系统提供")
                                    ServiceStatusLabel()
                                }
                                Spacer()
                                if selection == .system { checkmark }
                            }
                        }
                        .foregroundStyle(.primary)
                        Button {
                            selectCustom()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("自定义")
                                    Text(customFieldsComplete ? "OpenAI 兼容服务 · \(model)" : "OpenAI 兼容服务，需自行配置")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selection == .custom { checkmark }
                            }
                        }
                        .foregroundStyle(.primary)
                    } header: {
                        Text("AI 来源")
                    } footer: {
                        Text("系统 AI 由平台统一提供和维护，无需任何配置。")
                    }
                }

                if showCustomFields {
                    Section("自定义配置") {
                        TextField("Base URL", text: $baseUrl)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        TextField("模型名称", text: $model)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                    }

                    Section {
                        HStack {
                            Group {
                                if showKey {
                                    TextField("API Key", text: $apiKey)
                                        .autocapitalization(.none)
                                        .autocorrectionDisabled()
                                } else {
                                    SecureField("API Key", text: $apiKey)
                                        .autocorrectionDisabled()
                                }
                            }
                            Button {
                                showKey.toggle()
                            } label: {
                                Image(systemName: showKey ? "eye.slash" : "eye")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("API Key（仅存本机 Keychain，不上传服务器）")
                    }

                    Section {
                        Button {
                            saveCustom()
                        } label: {
                            Text(customSaved ? "已保存" : "保存自定义配置").frame(maxWidth: .infinity)
                        }
                        .disabled(!customFieldsComplete || customSaved)
                    } footer: {
                        if selection != .custom {
                            Text("填写并保存后生效。")
                        }
                    }
                }
            }
            .navigationTitle("AI 助手配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task { loadExisting() }
        }
    }

    private var checkmark: some View {
        Image(systemName: "checkmark")
            .fontWeight(.semibold)
            .foregroundStyle(Color.accentColor)
    }

    /// 字段与已保存值一致且自定义已生效 → 没有可保存的内容（按钮显示「已保存」并禁用）
    private var customSaved: Bool {
        customFieldsComplete && !customDirty && selection == .custom
    }

    private func loadExisting() {
        if UserDefaults.standard.bool(forKey: "ai_use_system"), SystemAIProvider.isIntegrated {
            selection = .system
        } else if let key = auth.aiApiKey, !key.isEmpty {
            selection = .custom
        } else {
            selection = nil   // 从未保存过任何配置
        }
        customExpanded = (selection == .custom)
        baseUrl = UserDefaults.standard.string(forKey: "ai_base_url") ?? "https://api.openai.com/v1"
        model   = UserDefaults.standard.string(forKey: "ai_model") ?? "gpt-4o-mini"
        apiKey  = auth.aiApiKey ?? ""
        persistedBaseUrl = baseUrl
        persistedModel = model
        persistedApiKey = apiKey
    }

    /// 点击「系统提供」：立即生效，无需保存（零配置预设，没有可保存的字段）。
    private func selectSystem() {
        selection = .system
        customExpanded = false
        UserDefaults.standard.set(true, forKey: "ai_use_system")
        // 系统 AI：baseUrl 留空，streamCallAI 实时取本机 endpoint。
        let config = AIConfig(provider: "system", baseUrl: "", model: SystemAIProvider.defaultModel)
        orchestrator.configure(config: config, apiKey: SystemAIProvider.internalKey)
    }

    /// 点击「自定义」：配置完整 → 立即生效（等同保存）；未配置 → 展开表单引导填写。
    private func selectCustom() {
        customExpanded = true
        if customFieldsComplete { saveCustom() }
    }

    private func saveCustom() {
        guard customFieldsComplete else { return }
        UserDefaults.standard.set(false, forKey: "ai_use_system")
        UserDefaults.standard.set(baseUrl, forKey: "ai_base_url")
        UserDefaults.standard.set(model, forKey: "ai_model")
        auth.aiApiKey = apiKey
        let config = AIConfig(provider: "openai", baseUrl: baseUrl, model: model)
        orchestrator.configure(config: config, apiKey: apiKey)
        selection = .custom
        persistedBaseUrl = baseUrl
        persistedModel = model
        persistedApiKey = apiKey
        // 模块未接入时页面没有来源列表（保存后无勾选移动可作反馈），直接关闭
        if !SystemAIProvider.isIntegrated { dismiss() }
    }
}

/// 系统 AI 的服务状态标签：只显示状态、不暴露端口/本机实现 ——
/// 用户感知为「平台服务」的状态，而非手机上跑着什么。
private struct ServiceStatusLabel: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let s = display(SystemAIProvider.status)
            HStack(spacing: 5) {
                Circle().fill(s.color).frame(width: 6, height: 6)
                Text(s.text)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func display(_ status: SystemAIStatus?) -> (color: Color, text: String) {
        switch status {
        case .running: return (.green, "服务正常")
        case .starting, .waitingAuth, .stopped, nil: return (.orange, "连接服务中…")
        case .disabled: return (Color(.systemGray3), "服务维护中")
        case .unreachable, .failed: return (.red, "服务暂不可用")
        }
    }
}
