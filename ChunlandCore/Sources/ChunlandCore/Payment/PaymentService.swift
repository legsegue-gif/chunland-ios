import Foundation

// 支付 / 退款对接 server。唤起支付宝由 AlipayBridgeManager 负责。
public actor PaymentService {
    public static let shared = PaymentService()
    private let api = APIClient.shared

    /// 发起支付。返回 { paid, orderStr }：
    /// - paid == true（Mock 模式）：服务端已置 PAID，调用方 reload 即可；
    /// - 否则用 orderStr 唤起支付宝，订单状态等服务端 notify。
    public func createPayment(orderId: Int) async throws -> PaymentInit {
        struct Empty: Encodable {}
        return try await api.post("/payments/\(orderId)", body: Empty())
    }

    /// 退款（agent 对 PAID / PURCHASING 订单，首期全额）。
    public func refund(orderId: Int, reason: String? = nil) async throws {
        struct Body: Encodable { let reason: String? }
        struct Resp: Decodable { let id: Int; let status: String }
        let _: Resp = try await api.post("/payments/\(orderId)/refund", body: Body(reason: reason))
    }
}
