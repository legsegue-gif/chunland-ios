import SwiftUI
import ChunlandCore

// 各功能页面统一的「✨ 问 AI」入口（放导航栏 ToolbarItem）。
// 页面与 AI 之间的唯一耦合面：只传一个 AIContext 值、调一次 coordinator.ask —— 页面不碰任何 AI 内部。
// coordinator.isEnabled=false（全局 kill switch）时渲染 EmptyView：所有页面入口一起消失，页面自身不受影响。
struct AskAIButton: View {
    let context: AIContext
    @EnvironmentObject var coordinator: AICoordinator
    @EnvironmentObject var login: LoginCoordinator

    var body: some View {
        if coordinator.isEnabled {
            Button {
                // 游客模式：AI 需登录，登录成功后自动续做（带上下文唤起面板）。
                login.requireLogin(reason: "登录后即可使用 AI 助手") {
                    coordinator.ask(context)
                }
            } label: {
                Image(systemName: "sparkles")
            }
            .accessibilityLabel("问 AI")
        }
    }
}
