import Foundation

// 缺货改单。agent 发起 propose、consumer decide（accept/reject）。
public actor AdjustmentService {
    public static let shared = AdjustmentService()
    private let api = APIClient.shared

    public func list(orderId: Int) async throws -> [OrderAdjustment] {
        try await api.get("/orders/\(orderId)/adjustments")
    }

    public func propose(orderId: Int, kind: String,
                        detail: AdjustmentDetail, note: String?) async throws -> OrderAdjustment {
        struct Body: Encodable { let kind: String; let detail: AdjustmentDetail; let note: String? }
        return try await api.post("/orders/\(orderId)/adjustments",
                                  body: Body(kind: kind, detail: detail, note: note))
    }

    public func decide(orderId: Int, adjustmentId: Int,
                       accept: Bool, reason: String? = nil) async throws {
        struct Body: Encodable { let accept: Bool; let reason: String? }
        struct Resp: Decodable { let adjustment: OrderAdjustment }  // 忽略 order 字段，store 自行 reload
        let _: Resp = try await api.post(
            "/orders/\(orderId)/adjustments/\(adjustmentId)/decide",
            body: Body(accept: accept, reason: reason))
    }
}
