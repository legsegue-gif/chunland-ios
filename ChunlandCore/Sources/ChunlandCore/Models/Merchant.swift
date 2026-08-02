import Foundation

// GET /api/v1/merchants —— store picker 列表（公开展示数据）。
// platformFeeRate / agentFeeRate / minOrderAmount 为 nil 表示该商家走全局费率（ConfigStore getter 负责回退）。
public struct Merchant: Decodable, Identifiable, Sendable, Hashable {
    public let id: Int
    public let name: String
    public let type: String
    public let logoUrl: String?
    public let platformFeeRate: Decimal?
    public let agentFeeRate: Decimal?
    public let minOrderAmount: Decimal?
    /// 店铺咨询有接线人（「联系商家」入口门控，叠加 IMStore.enabled）
    public let contactable: Bool?
    /// 发货地区县（code/名/所属市）；nil = 商家未设发货地（距离费按 0，列表不显示距离）
    public let areaCode: String?
    public let areaName: String?
    public let cityCode: String?
    public let cityName: String?
    /// 与用户定位锚点中心的球面距离（server 计算，与下单报价同口径）；未选城市或店无发货地为 nil。
    /// ⚠️ 只作展示 —— 代购费仍以 POST /orders/quote 为准，iOS 绝不本地算费。
    public let distanceKm: Double?
}

/// GET /merchants 回显的定位锚点（anchor 参数解析结果）。
/// 可为省/市/区县任一级（level 1/2/3）：name 供顶栏显示，cityCode 供店铺卡「同市省略市名」分组判断。
public struct MerchantListAnchor: Decodable, Sendable {
    public let code: String
    public let name: String?
    public let level: Int?
    public let cityCode: String?   // 所属市 code；省级 anchor 为 nil
    public let cityName: String?
}
