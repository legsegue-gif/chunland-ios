import Foundation

// 支付宝 SDK 桥接。
// ChunlandCore 是 SwiftPM 包，不能直接 import AlipaySDK（二进制 framework 属 App target），
// 故在此定义协议，由 App target 侧的实现类在启动时 register。
//
// 全程 @MainActor（支付操作在主线程）；callback 简化为 (success, resultStatus)，
// 不外泄 SDK 的 [AnyHashable: Any]。⚠️ success 仅表示 App 内支付返回成功，
// 真正订单状态以服务端 notify 为准 —— 调用方拿到回调只用于触发 reload。

@MainActor
public protocol AlipayBridge: AnyObject {
    func pay(orderString: String, scheme: String, completion: @escaping @Sendable (Bool, String?) -> Void)
    func handleOpenURL(_ url: URL)
}

@MainActor
public final class AlipayBridgeManager {
    public static let shared = AlipayBridgeManager()
    private var bridge: AlipayBridge?
    private init() {}

    public var isRegistered: Bool { bridge != nil }

    public func register(_ b: AlipayBridge) { bridge = b }

    /// 返回 false 表示桥接未注册（如 App target 未集成 SDK / 未调 register）。
    @discardableResult
    public func pay(orderString: String, scheme: String,
                    completion: @escaping @Sendable (Bool, String?) -> Void) -> Bool {
        guard let bridge else { return false }
        bridge.pay(orderString: orderString, scheme: scheme, completion: completion)
        return true
    }

    public func handleOpenURL(_ url: URL) {
        bridge?.handleOpenURL(url)
    }
}
