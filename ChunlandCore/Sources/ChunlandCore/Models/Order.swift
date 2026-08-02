import Foundation

// 服务端状态机返回的可执行动作。
// iOS ForEach 渲染按钮 —— 不再硬编码状态转换。
public struct OrderAction: Decodable, Identifiable, Sendable, Hashable {
    public let action: String     // claim / cancel / startPurchase / startDeliver / confirmDelivery / complete
    public let toStatus: String   // 配合现有 PATCH /orders/:id/status 接口
    public let label: String      // 按钮文案（中文）
    public let style: String      // primary / destructive / secondary

    public var id: String { action }
}

public struct OrderSummary: Decodable, Identifiable, Sendable {
    public let id: Int
    public let orderNumber: String
    public let status: String
    public let merchantId: Int?
    public let merchantName: String?
    public let itemsTotal: Decimal
    public let platformFee: Decimal
    public let agentFee: Decimal
    public let totalAmount: Decimal
    public let tipAmount: Decimal?
    public let itemCount: Int?
    public let createdAt: String
    public let availableActions: [OrderAction]?
    // 大厅增强（仅 scope=hall 下发）：距离 = 商家发货区县 ↔ 我方锚点最近者（服务端算）
    public let distanceKm: Double?
    public let onTheWay: Bool?    // 顺路（D4 真距离判定：绕路 ≤5km；坐标缺失回退同商家/同区县）
    public let detourKm: Double?  // 绕路公里数（同商家=0；无进行中订单/缺坐标=nil）
    // 卡片信息：首商品名/缩略图（代购人扫一眼知道买什么）
    public let firstProductName: String?
    public let firstThumbnail: String?
    public let hasReceipt: Bool?  // 已传采购小票（D3 工作台决定「传小票 vs 开始配送」）
}

// POST /api/v1/orders —— 合并购物车结算，按商家拆单后的批次。
// 单商家时 orders.count == 1，等价旧的单笔下单。
public struct CheckoutBatch: Decodable, Sendable {
    public let orders: [OrderSummary]
    public let orderCount: Int
    public let grandTotal: String
}

// 下单报价（dry-run）—— POST /orders/quote 返回，含距离驱动的代购费。结算页选地址后预览精确总额。
public struct OrderQuote: Decodable, Sendable {
    public let groups: [QuoteGroup]
    public let grandTotal: Decimal
}

public struct QuoteGroup: Decodable, Identifiable, Sendable {
    public let merchantId: Int
    public let merchantName: String
    public let itemsTotal: Decimal
    public let platformFee: Decimal
    public let agentFee: Decimal       // 距离驱动：base + 每公里 × 区县中心距离
    public let totalAmount: Decimal
    public let meetsMinOrder: Bool
    public let minOrderAmount: Decimal
    public let platformFeeRate: Decimal     // 平台费率（quote 同源，结算页百分比标签实时显示）
    public var id: Int { merchantId }
}

public struct OrderDetail: Decodable, Identifiable, Sendable {
    public let id: Int
    public let orderNumber: String
    public let status: String
    public let consumerId: Int
    public let agentId: Int?
    public let merchantId: Int?         // F3 改单本地预览用当前 per-merchant 费率
    public let itemsTotal: Decimal
    public let platformFee: Decimal
    public let agentFee: Decimal
    public let totalAmount: Decimal
    public let deliveryAddress: DeliveryAddress
    public let deliveryNote: String?
    public let items: [OrderItem]
    public let createdAt: String
    public let claimedAt: String?
    public let completedAt: String?
    public let availableActions: [OrderAction]?
}

public struct OrderItem: Decodable, Identifiable, Sendable {
    public let id: Int
    public let productCode: String
    public let selectedSize: String?
    public let quantity: Int
    public let unitPrice: Decimal
    public let totalPrice: Decimal
    public let productSnapshot: ProductSnapshot
}

// MARK: - 缺货改单

// 单条改动（对应一个 order_item）。kind 决定语义；action 决定字段。
public struct AdjustmentItem: Codable, Identifiable, Sendable {
    public let orderItemId: Int
    public let action: String          // remove / reduce_qty / change_price / change_spec
    public let newQuantity: Int?
    public let newUnitPrice: Decimal?
    public let newSize: String?
    public let note: String?

    public var id: Int { orderItemId }

    public init(orderItemId: Int, action: String,
                newQuantity: Int? = nil, newUnitPrice: Decimal? = nil,
                newSize: String? = nil, note: String? = nil) {
        self.orderItemId = orderItemId
        self.action = action
        self.newQuantity = newQuantity
        self.newUnitPrice = newUnitPrice
        self.newSize = newSize
        self.note = note
    }
}

public struct AdjustmentDetail: Codable, Sendable {
    public let items: [AdjustmentItem]
    public init(items: [AdjustmentItem]) { self.items = items }
}

// GET /api/v1/orders/:id/adjustments —— 改单协商记录。
public struct OrderAdjustment: Decodable, Identifiable, Sendable {
    public let id: Int
    public let orderId: Int
    public let proposedBy: Int
    public let kind: String            // out_of_stock / spec_change / price_change
    public let detail: AdjustmentDetail
    public let amountDelta: Decimal    // 对 total_amount 的增减（负=下调，触发部分退）
    public let status: String          // PENDING / ACCEPTED / REJECTED / EXPIRED
    public let decidedBy: Int?
    public let decidedAt: String?
    public let note: String?
    public let createdAt: String

    public var isPending: Bool { status == "PENDING" }
    public var refundAmount: Decimal { amountDelta < 0 ? -amountDelta : 0 }
}

// GET /api/v1/orders/:id/evidence —— 采购凭证。
// 凭证桶非公开：图片经鉴权代理读取（`APIClient.getData`），不用裸 URL。
public struct OrderEvidence: Decodable, Identifiable, Sendable {
    public let id: Int
    public let orderId: Int
    public let kind: String        // receipt(小票) / product_photo(实物) / dispute(纠纷举证)
    public let uploadedBy: Int
    public let createdAt: String
    public let url: String         // 鉴权图片代理相对路径（含 /api/v1），仅参考；iOS 用 id 拉图
}

// 下单时随 order_items 冻结的商品快照（防止后续商品改价影响历史订单展示）
public struct ProductSnapshot: Decodable, Sendable {
    public let code: String
    public let name: String
    public let price: Decimal?
    public let randomWeight: Bool?
}
