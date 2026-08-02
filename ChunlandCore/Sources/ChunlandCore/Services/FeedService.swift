import Foundation

// 内容流服务。/feed 是公开端点，无需 token。keyset 分页：nextCursor 原样回传。
public actor FeedService {
    public static let shared = FeedService()
    private let api = APIClient.shared

    public struct Page: Decodable, Sendable {
        public let items: [FeedItem]
        public let nextCursor: String?
    }

    // cursor 为 base64url（URL 安全），可直接拼到 query。mode=following 需登录（APIClient 自动带 token）。
    public func list(mode: FeedMode = .forYou, cursor: String? = nil, limit: Int = 20,
                     merchant: Int? = nil) async throws -> Page {
        var path = "/feed?mode=\(mode.rawValue)&limit=\(limit)"
        if let cursor, !cursor.isEmpty { path += "&cursor=\(cursor)" }
        if let merchant { path += "&merchant=\(merchant)" }   // M4 店铺主页动态面（单商家公开流）
        return try await api.get(path)
    }

    // MARK: - 关注（needs login）

    public func follows() async throws -> [FeedFollow] {
        struct Resp: Decodable { let follows: [FeedFollow] }
        let resp: Resp = try await api.get("/feed/follows")
        return resp.follows
    }

    /// 「收藏与关注」管理页：关注关系 + 展示数据（名/图/价/有效态），按关注时间倒序
    public func followsDetail() async throws -> [FollowDetailItem] {
        let list: FollowDetailList = try await api.get("/feed/follows/detail")
        return list.items
    }

    public func follow(type: FollowTargetType, key: String) async throws {
        struct Body: Encodable { let targetType: String; let targetKey: String }
        struct Ack: Decodable { let ok: Bool }
        let _: Ack = try await api.post("/feed/follows", body: Body(targetType: type.rawValue, targetKey: key))
    }

    public func unfollow(type: FollowTargetType, key: String) async throws {
        struct Body: Encodable { let targetType: String; let targetKey: String }
        // DELETE 带 body：用 requestVoid（服务端 data 非 null 但忽略即可，用 EmptyEnvelope 解）
        try await api.requestVoid("DELETE", path: "/feed/follows",
                                  body: Body(targetType: type.rawValue, targetKey: key))
    }

    // 0.5 埋点上报（曝光/点击/停留）。失败静默，不影响浏览。
    public func reportEvents(_ events: [FeedEvent]) async {
        guard !events.isEmpty else { return }
        struct Body: Encodable { let events: [FeedEvent] }
        struct Ack: Decodable { let accepted: Int }
        do {
            let _: Ack = try await api.post("/feed/events", body: Body(events: events))
        } catch {
            // 埋点失败不抛错
        }
    }
}
