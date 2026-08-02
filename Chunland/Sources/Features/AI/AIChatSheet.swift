import SwiftUI
import ChunlandCore

// 从任意功能页面唤起的「带上下文」AI 对话面板（底部半屏，可拖拽到全屏）。
// 由根部 MainTabView 的 `.sheet(item:)` 呈现，背后仍见当前页 —— 不跳转、不离开。
// 复用 AIChatView（与 AI tab 同一套聊天 UI + HITL 确认），onAppear 起一条 scoped 会话。
struct AIChatSheet: View {
    let context: AIContext

    @EnvironmentObject var orchestrator: AIOrchestrator
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var coordinator: AICoordinator

    @State private var showSetup = false
    @State private var started = false   // 防 onAppear 重入二次重置会话

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            AIChatView(onConfigure: { showSetup = true })
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            // 唤起 scoped 会话（方案 B）：注入页面上下文 + 工具子集，标题「关于 X」存入历史，
            // 不污染 AI tab 的持久会话；24h 内同 contextKey 续聊。started 防重入。
            guard !started else { return }
            started = true
            orchestrator.startScopedConversation(context)
        }
        .onDisappear {
            // 关闭（点 X / 下滑）→ 存好 scoped 会话、恢复 tab 原会话；空会话直接删除防堆积
            orchestrator.endScopedConversation()
        }
        .sheet(isPresented: $showSetup) {
            AISetupSheet()
                .environmentObject(orchestrator)
                .environmentObject(auth)
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
            // 另起一条新对话（旧对话归档留在历史抽屉，不再被续聊命中）
            Button {
                orchestrator.restartScopedConversation(context)
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("新对话")
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
}
