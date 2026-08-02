import Foundation

// POST /api/v1/payments/:orderId 的响应 data。
// paid=true 表示已完成（Mock 立即支付）；否则 orderStr 用于唤起支付宝 App 支付。
public struct PaymentInit: Decodable, Sendable {
    public let paid: Bool
    public let orderStr: String?
}
