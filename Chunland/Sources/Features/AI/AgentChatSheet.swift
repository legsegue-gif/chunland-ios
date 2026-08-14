import SwiftUI
import ChunlandCore

// MARK: - 页面 ✨ 唤起的对话面板
//
// 与旧 AIChatSheet 的关键差别：**不再有「切进切出」**。
//
// 旧的是一个全局 orchestrator 被反复改用途 —— 进来时记住 tab 会话、装载新上下文、
// 出去时恢复；还要 `started` 标志防 onAppear 重入。新的每个 contextKey 一个实例，
// 打开就是打开、关闭就是关闭，没有需要「恢复」的东西。

struct AgentChatSheet: View {

    let context: AIContext

    @EnvironmentObject var coordinator: AICoordinator
    @Environment(AIRuntime.self) private var runtime

    @State private var session: AIChatSession?
    @State private var showSettings = false
    /// 当前档位。**必须受控** —— 不带 selection 的 `presentationDetents` 只把档位存在
    /// SwiftUI 内部，视图一重建就丢，回落到集合里的第一档。表现是：用户拉到全屏后
    /// 一发消息（消息数变化触发重建）面板自己缩回半屏。
    @State private var detent: PresentationDetent = .medium

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .task { await prepare() }
        .onDisappear {
            // 没聊过的空会话直接删掉，不让抽屉堆一次性死会话
            Task { await session?.close() }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                AIProviderSettingsView(config: runtime.config)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let session {
            AgentChatView(session: session, onConfigure: { showSettings = true })
        } else if let error = runtime.bootstrapError {
            unavailable(error)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.accentColor)
            Text("关于 \(context.title)")
                .font(.headline)
                .lineLimit(1)
            Spacer()
            // 「新对话」= 归档语义：旧会话留在抽屉里当历史，只是不再被续聊命中
            Button {
                Task { await session?.restart() }
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("新对话")
            .disabled(session == nil)

            Button {
                coordinator.dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func unavailable(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("AI 暂时不可用")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func prepare() async {
        // 冷启动直接点 ✨（没先进过 AI tab）也要能用 —— 不能假设 tab 一定先被访问过
        await runtime.bootstrap()
        guard runtime.isReady else { return }
        let target = runtime.sessions.session(for: context)
        await target.open()
        session = target
    }
}
