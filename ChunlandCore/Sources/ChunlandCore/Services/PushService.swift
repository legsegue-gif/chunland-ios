import Foundation

/// 推送 device token 注册/解绑（APNs）。两端点均需登录（APIClient 自动带 token）。
/// 上报时机：通知授权成功 + 登录态下（App 层 PushRegistrar 编排）；显式退出登录前解绑。
public actor PushService {
    public static let shared = PushService()
    private let api = APIClient.shared

    private struct Empty: Decodable {}

    public func register(token: String) async throws {
        struct Body: Encodable {
            let token: String
            let platform: String
        }
        let _: Empty = try await api.post("/push/token", body: Body(token: token, platform: "ios"))
    }

    /// 尽力而为：显式登出前调用，失败不阻塞登出（换账号登录时服务端会自动改绑 token 归属）
    public func unregister(token: String) async {
        struct Body: Encodable { let token: String }
        let _: Empty? = try? await api.post("/push/token/delete", body: Body(token: token))
    }
}
