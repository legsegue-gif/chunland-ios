import Foundation
import Observation

// 订单会话（IM）功能开关缓存：只回答「聊天功能是否开通」，给入口按钮做可见性门控。
// 连接用的一次性 token 不在这里缓存（每次打开会话现取，见 IMService.config() 注释）。
@MainActor
@Observable
public final class IMStore {
    public static let shared = IMStore()

    public private(set) var enabled = false
    private var loaded = false

    private init() {}

    public func loadIfNeeded() async {
        if loaded { return }
        do {
            enabled = try await IMService.shared.config().enabled
            loaded = true
        } catch {
            AppLogger.app.warn("IMStore.loadIfNeeded failed", metadata: ["error": String(describing: error)])
        }
    }

    public func reset() {
        enabled = false
        loaded = false
    }
}
