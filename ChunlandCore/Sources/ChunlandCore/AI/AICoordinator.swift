import Foundation
import Combine

// MARK: - AICoordinator —— 各页面唤起 AI 的唯一接缝
//
// app 根部持有一个实例并经 environment 注入；任意页面经它 `ask(context)` 弹出共享 AI 面板。
// 全部入口汇流到这一个 coordinator + 一个 orchestrator —— 这是「核心单点 + 全局管控」的落点：
//   - 关掉 isEnabled → 所有页面的 ✨ 入口一起消失、sheet 不再弹（出事一处止血）。
//   - 页面只依赖本类 + AIContext（值），AI 内部怎么变都波及不到页面。
//
// 放在 ChunlandCore（非 app 层）：它只搬运 AIContext，不碰 UIKit，属于「核心」的一部分。
@MainActor
public final class AICoordinator: ObservableObject {
    /// 非 nil 即表示有页面请求弹出 AI 面板；根部 `.sheet(item:)` 据此呈现。
    @Published public var activeContext: AIContext?

    public init() {}

    /// 全局开关（kill switch）：false → 入口隐藏、面板不弹。当前由 AppSettings 驱动，
    /// 未来可换成服务端下发而入口/页面代码不动。
    public var isEnabled: Bool { AppSettings.shared.aiEntryEnabled }

    /// 页面调用：带上下文唤起 AI 面板。isEnabled=false 时静默忽略（双保险）。
    public func ask(_ context: AIContext) {
        guard isEnabled else { return }
        activeContext = context
    }

    /// 收起面板。
    public func dismiss() {
        activeContext = nil
    }
}
