import Foundation

public struct AgentProfile: Decodable, Sendable {
    public let userId: Int
    public let serviceFee: Decimal
    public let bio: String?
    public let isAvailable: Bool
    public let rating: Decimal
    public let totalOrders: Int
    public let serviceAreaCodes: [String]   // P1 服务区县 code 集合（空 = 接全部区域）
    public let lastLat: Double?             // 坐标地基（押后）
    public let lastLng: Double?
}

// MARK: - 工作台

// GET /api/v1/agent-profile/dashboard 聚合：待办计数 + 收入汇总。
// 分组是主状态机状态的展示聚合，状态转换仍由服务端 availableActions 驱动。
public struct AgentDashboard: Decodable, Sendable {
    public struct Counts: Decodable, Sendable {
        public let claimed: Int          // 待买家支付
        public let paid: Int             // 待采购
        public let purchasing: Int       // 采购中
        public let delivering: Int       // 配送中
        public let delivered: Int        // 待买家确认
        public let purchasingNoReceipt: Int          // 采购中·缺小票凭证
        public let purchasingPendingAdjustment: Int  // 采购中·改单待买家答复
    }
    public struct Earnings: Decodable, Sendable {
        public let today: Decimal             // 今日已记账收入（非 VOID）
        public let month: Decimal             // 本月已记账收入
        public let pendingSettlement: Decimal // 待结算余额（PENDING+PAYABLE）
    }
    public let counts: Counts
    public let earnings: Earnings
}

// MARK: - 合并采购清单

// GET /api/v1/agent-profile/purchase-list：待采购/采购中订单按商家分组，
// 同商品（code+尺码）跨单聚合数量。勾选进度是纯客户端状态，不落库。
public struct PurchaseList: Decodable, Sendable {
    public struct OrderRef: Decodable, Identifiable, Sendable {
        public let id: Int
        public let orderNumber: String
        public let status: String        // PAID / PURCHASING
        public let hasReceipt: Bool      // 是否已传小票凭证
    }
    public struct BreakdownEntry: Decodable, Sendable, Hashable {
        public let orderId: Int
        public let orderNumber: String
        public let quantity: Int
    }
    public struct Item: Decodable, Identifiable, Sendable {
        public let productCode: String
        public let name: String
        public let selectedSize: String?
        public let imageUrl: String?
        public let totalQuantity: Int
        public let breakdown: [BreakdownEntry]
        public var id: String { "\(productCode)|\(selectedSize ?? "")" }
    }
    public struct Group: Decodable, Identifiable, Sendable {
        public let merchantId: Int
        public let merchantName: String
        public let orders: [OrderRef]
        public let items: [Item]
        public var id: Int { merchantId }
    }
    public let groups: [Group]
}

// MARK: - 资金结算

// GET /api/v1/agent-profile/settlements 的一条结算账。
public struct Settlement: Decodable, Identifiable, Sendable {
    public let id: Int
    public let orderId: Int
    public let orderNumber: String
    public let itemsReimburse: Decimal     // 货款垫付返还
    public let agentFee: Decimal           // 代购劳务
    public let platformFee: Decimal        // 平台留存（不结给 agent，仅展示）
    public let netPayable: Decimal         // 应付 agent = itemsReimburse + agentFee
    public let status: String              // PENDING / PAYABLE / PAID / VOID
    public let paidAt: String?
    public let createdAt: String
}

public struct SettlementSummary: Decodable, Sendable {
    public let items: [Settlement]
    public let pendingTotal: Decimal       // 待结算总额（PENDING+PAYABLE）
    public let paidTotal: Decimal          // 已结算总额（PAID）
}
