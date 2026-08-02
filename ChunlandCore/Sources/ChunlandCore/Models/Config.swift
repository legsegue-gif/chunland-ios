import Foundation

// GET /api/v1/config/checkout —— 下单页公开配置
public struct CheckoutConfig: Decodable, Sendable {
    public let platformFeeRate: Decimal
    public let agentFeeRate: Decimal      // F1：代购费率（平台统一定价，下单即算）
    public let minOrderAmount: Decimal
}
