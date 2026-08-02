import Foundation
import Combine

// MARK: - LoginCoordinator —— 游客触发登录的唯一接缝（仿 AICoordinator）
//
// 游客模式（Apple 5.1.1）：浏览内容免登录，仅在「账号类动作」临门弹登录 ——
// 加购 / 关注 / 下单 / AI / 进入购物车·我的等。任意页面/动作经本类要求登录：
//   - 已登录 → 立即执行 action（直通）。
//   - 未登录 → 记下 action + reason 发出 `pending`；根部 `.sheet(item:)` 弹 AuthView。
//     登录成功后由根部 observe `isLoggedIn` 调 `didLogin()`：清 pending（sheet 自动收起）
//     并续做被拦动作（intent retry）。
//
// 放在 ChunlandCore（非 app 层）：与 AICoordinator 同款 —— 只搬运「待办动作」，不碰 UIKit/SwiftUI，
// 属于「核心单点」。app 根部持一实例经 environment 注入，sheet 的呈现在 app 层（MainTabView）。
@MainActor
public final class LoginCoordinator: ObservableObject {
    public struct Request: Identifiable {
        public let id = UUID()
        public let reason: String?          // 登录页顶部可选提示，如「登录后即可加入购物车」
        public let onSuccess: () -> Void
    }

    /// 非 nil 即有动作在等待登录；根部 `.sheet(item:)` 据此呈现 AuthView。
    @Published public var pending: Request?

    public init() {}

    /// 要求登录：已登录直接执行 action；未登录弹登录，成功后续做（intent retry）。
    /// action 默认空闭包 —— 用于「进入受限页」这类只需登录、登录后页面自身刷新的场景。
    public func requireLogin(reason: String? = nil, action: @escaping () -> Void = {}) {
        if AuthManager.shared.isLoggedIn {
            action()
            return
        }
        pending = Request(reason: reason, onSuccess: action)
    }

    /// 登录成功后由根部调用：续做被拦动作并清空 pending（清空触发 sheet 收起）。
    /// 无待办时安全 no-op（普通登录、热重入都会触发 isLoggedIn 变化）。
    public func didLogin() {
        guard let req = pending else { return }
        pending = nil
        req.onSuccess()
    }

    /// 用户主动取消（关闭登录 sheet）：丢弃待办动作。
    public func cancel() { pending = nil }
}
