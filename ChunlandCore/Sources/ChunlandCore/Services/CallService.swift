import Foundation

/// 音视频通话服务（买家 ↔ 代购人）。两端点均需登录（APIClient 自动带 token）。
/// 服务端只做两件事：签发 UserSig、发起邀请（拉黑守卫 + 频道信令 + 离线推送）。
/// 接听/挂断由通话引擎的 TRTC 房间事件驱动，不经本服务 —— 故这里只有 sig / invite 两个方法。
public actor CallService {
    public static let shared = CallService()
    private let api = APIClient.shared

    /// 签发当前用户 TRTC UserSig（进房鉴权，与房间无关）
    public func sig() async throws -> CallSigInfo {
        struct Empty: Encodable {}
        return try await api.post("/calls/sig", body: Empty())
    }

    /// 发起通话：拉黑守卫 → 频道 INVITE 信令 + 离线推送 → 返回主叫进房凭证（房号 = 订单号）
    public func invite(orderId: Int, media: CallMedia = .audio) async throws -> CallInviteResult {
        struct Body: Encodable {
            let orderId: Int
            let media: String
        }
        return try await api.post("/calls/invite", body: Body(orderId: orderId, media: media.rawValue))
    }

    /// 主叫接通前取消：通知被叫撤下来电（尽力而为，失败无碍）
    public func cancel(orderId: Int) async {
        struct Body: Encodable { let orderId: Int }
        struct Empty: Decodable {}
        let _: Empty? = try? await api.post("/calls/cancel", body: Body(orderId: orderId))
    }

    /// 被叫拒接：通知主叫立即结束（尽力而为，失败无碍）
    public func reject(orderId: Int) async {
        struct Body: Encodable { let orderId: Int }
        struct Empty: Decodable {}
        let _: Empty? = try? await api.post("/calls/reject", body: Body(orderId: orderId))
    }

    /// 主叫上报通话结果 → 会话系统消息记录（尽力而为）。outcome: ended | no_answer | cancelled | rejected
    public func reportResult(orderId: Int, outcome: String, duration: Int, media: CallMedia) async {
        struct Body: Encodable {
            let orderId: Int
            let outcome: String
            let duration: Int
            let media: String
        }
        struct Empty: Decodable {}
        let _: Empty? = try? await api.post("/calls/result", body: Body(orderId: orderId, outcome: outcome, duration: duration, media: media.rawValue))
    }
}
