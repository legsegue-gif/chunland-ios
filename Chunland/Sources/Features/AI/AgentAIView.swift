import SwiftUI
import ChunlandCore

// MARK: - AI 助手 tab
//
// tab 的主对话 = 一条没有 contextKey 的会话（全局作用域、全量工具）。
// 与页面 ✨ 的会话是**平级的两个实例**，不存在谁挂起谁的关系 ——
// 这正是多实例模型消掉的那类状态。

struct AgentAIView: View {

    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var login: LoginCoordinator
    @Environment(AIRuntime.self) private var runtime

    @State private var session: AIChatSession?
    @State private var showDrawer = false
    @State private var showSettings = false

    /// tab 主对话的上下文：无作用域限定、无页面建议子集 —— 当前身份的全量工具。
    ///
    /// contextKey 固定为 `main` 且**不限续聊时间**：它就是「你正在进行的那个对话」，
    /// 冷启动接着上次聊。没有这个 key 的话每次启动都会新建一条，用户只要开过
    /// tab 又没说话，历史抽屉里就多一条空会话，且没有任何路径会删它。
    /// 换新的是用户按「新对话」的显式动作（旧的摘掉 key 留在抽屉当历史）。
    ///
    /// 标题用占位而不是「AI 助手」：首条用户消息发出后会据此改名，
    /// 写死一个名字会让所有主对话在抽屉里长得一模一样。
    private var mainContext: AIContext {
        AIContext(
            title: SessionRepo.untitled,
            welcome: "你好！我可以帮你挑东西、下单、跟进订单。",
            contextKey: Self.mainContextKey
        )
    }

    private static let mainContextKey = "main"

    var body: some View {
        // 抽屉包在最外层：手势要覆盖整页（含 toolbar 下方区域），
        // 包在 content 里的话左边缘起手区会被 navigationTitle 那条挡掉一截。
        SideDrawer(isOpen: $showDrawer) {
            chatBody
        } drawer: {
            AgentConversationDrawer(
                db: runtime.database,
                ownerUserId: auth.currentUserId
            ) { sessionId in
                // 装载到当前实例：先存好正在聊的那条，再换过去
                Task { await session?.load(sessionId: sessionId) }
                closeDrawer()
            } onClose: {
                closeDrawer()
            }
        }
    }

    private func closeDrawer() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showDrawer = false }
    }

    private var chatBody: some View {
        content
            .navigationTitle("AI 助手")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // 按钮入口保留 —— 手势是快捷方式，不该是唯一入口（不可发现，
                    // 且辅助功能用户用不了）
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            showDrawer = true
                        }
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityLabel("历史对话")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        Task { await session?.restart() }
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("新对话")
                    .disabled(session == nil)

                    Button { showSettings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("AI 配置")
                }
            }
            .task { await prepare() }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                AIProviderSettingsView(config: runtime.config)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !auth.isLoggedIn {
            GuestGate(
                title: "登录后使用 AI 助手",
                message: "登录后即可让 AI 帮你挑东西、下单、跟进订单。",
                systemImage: "sparkles"
            )
        } else if let session {
            AgentChatView(session: session, onConfigure: { showSettings = true })
        } else if let error = runtime.bootstrapError {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2).foregroundStyle(.secondary)
                Text("AI 暂时不可用").font(.headline)
                Text(error).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func prepare() async {
        guard auth.isLoggedIn else { return }
        await runtime.bootstrap()
        guard runtime.isReady, session == nil else { return }
        let target = runtime.sessions.session(for: mainContext)
        await target.open(resumeWithin: nil)
        session = target
    }
}
