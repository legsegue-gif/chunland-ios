import Foundation

/// 用户拉黑（App Store 1.2 ③）。生效面在服务端：订单会话冻结 + 接单匹配拦截。
public actor BlockService {
    public static let shared = BlockService()
    private let api = APIClient.shared

    private struct Empty: Decodable {}

    public func block(userId: Int) async throws {
        struct Body: Encodable { let blockedUserId: Int }
        let _: Empty = try await api.post("/blocks", body: Body(blockedUserId: userId))
    }

    public func unblock(userId: Int) async throws {
        struct Body: Encodable { let blockedUserId: Int }
        let _: Empty = try await api.post("/blocks/delete", body: Body(blockedUserId: userId))
    }

    public func list() async throws -> [BlockedUser] {
        let list: BlockedUserList = try await api.get("/blocks")
        return list.items
    }
}
