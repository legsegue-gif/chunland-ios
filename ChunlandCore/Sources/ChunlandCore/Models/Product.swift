import Foundation

public enum StockTier: Sendable {
    case inStock
    case lowStock
    case outOfStock
    case unknown

    public init(rawValue: String?) {
        switch rawValue {
        case "inStock":    self = .inStock
        case "lowStock":   self = .lowStock
        case "outOfStock": self = .outOfStock
        default:           self = .unknown
        }
    }
}

public struct ProductSummary: Decodable, Identifiable, Hashable, Sendable {
    public let code: String
    public let name: String
    public let englishName: String?
    public let unitType: String?
    public let weight: Double?
    public let randomWeight: Bool
    public let minOrderQuantity: Int
    public let maxOrderQuantity: Int
    public let currentPrice: Decimal?
    public let originalPrice: Decimal?
    public let pricePerUnit: Decimal?
    public let discountAmount: Decimal?
    public let stockStatus: String?
    public let thumbnail: String?

    public var id: String { code }
    public var stockTier: StockTier { StockTier(rawValue: stockStatus) }
    public var isInStock: Bool { stockStatus != "outOfStock" }

    public static func == (lhs: ProductSummary, rhs: ProductSummary) -> Bool { lhs.code == rhs.code }
    public func hash(into hasher: inout Hasher) { hasher.combine(code) }

    // MARK: - Decodable
    //
    // 手写而不是靠合成：`fields=compact`（AI 搜索用，只回 code/名称/价格/库存）
    // 不含下面三个字段，而 Swift 合成的解码器**不会**套用属性默认值 ——
    // 缺键即抛 keyNotFound，整个搜索结果解析失败。
    //
    // 这也是一处双端分歧的根源：Kotlin 的 @Serializable 会套用默认值，
    // 所以同一份 compact 响应在 Android 正常、在 iOS 全线报「数据解析失败」。
    // 自定义 init(from:) 会让编译器停止合成 CodingKeys，必须显式声明。
    // 键名保持属性名 —— APIClient 的解码器开了 convertFromSnakeCase。
    private enum CodingKeys: String, CodingKey {
        case code, name, englishName, unitType, weight, randomWeight
        case minOrderQuantity, maxOrderQuantity
        case currentPrice, originalPrice, pricePerUnit, discountAmount
        case stockStatus, thumbnail
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(String.self, forKey: .code)
        name = try c.decode(String.self, forKey: .name)
        englishName = try c.decodeIfPresent(String.self, forKey: .englishName)
        unitType = try c.decodeIfPresent(String.self, forKey: .unitType)
        weight = try c.decodeIfPresent(Double.self, forKey: .weight)
        randomWeight = try c.decodeIfPresent(Bool.self, forKey: .randomWeight) ?? false
        minOrderQuantity = try c.decodeIfPresent(Int.self, forKey: .minOrderQuantity) ?? 1
        maxOrderQuantity = try c.decodeIfPresent(Int.self, forKey: .maxOrderQuantity) ?? 99
        currentPrice = try c.decodeIfPresent(Decimal.self, forKey: .currentPrice)
        originalPrice = try c.decodeIfPresent(Decimal.self, forKey: .originalPrice)
        pricePerUnit = try c.decodeIfPresent(Decimal.self, forKey: .pricePerUnit)
        discountAmount = try c.decodeIfPresent(Decimal.self, forKey: .discountAmount)
        stockStatus = try c.decodeIfPresent(String.self, forKey: .stockStatus)
        thumbnail = try c.decodeIfPresent(String.self, forKey: .thumbnail)
    }
}

public struct ProductImage: Decodable, Sendable {
    public let format: String
    public let galleryIndex: Int
    public let url: String
    public let isPrimary: Bool
}

public struct ProductDetail: Decodable, Identifiable, Sendable {
    public let code: String
    public let name: String
    public let englishName: String?
    public let description: String?
    public let unitType: String?
    public let weight: Double?
    public let randomWeight: Bool
    public let purchasable: Bool
    public let minOrderQuantity: Int
    public let maxOrderQuantity: Int
    /// 所属店铺（商品页「联系商家」入口用；contactable = 该店有咨询接线人）
    public let merchantId: Int?
    public let merchantName: String?
    public let merchantContactable: Bool?
    public let currentPrice: Decimal?
    public let originalPrice: Decimal?
    public let pricePerUnit: Decimal?
    public let discountAmount: Decimal?
    public let stockLevel: Int?
    public let stockStatus: String?
    public let sizes: [String]?
    public let images: [ProductImage]
    public let categories: [Category]

    public var id: String { code }
    public var stockTier: StockTier { StockTier(rawValue: stockStatus) }
    public var isInStock: Bool { stockStatus != "outOfStock" }
    public var primaryThumbnail: String? {
        images.first { $0.format == "thumbnail" && $0.isPrimary }?.url
    }
}

public struct ProductListResponse: Decodable, Sendable {
    public let items: [ProductSummary]
    public let pagination: Pagination
    /// 价格区间统计（`withStats=true` 时才有）。
    /// 给 AI 用：一次知道「这批商品什么价位、多少有货」，省一轮翻页试探。
    public let stats: ProductStats?
}

public struct ProductStats: Decodable, Sendable {
    public let minPrice: Decimal?
    public let maxPrice: Decimal?
    public let avgPrice: Decimal?
    public let inStockCount: Int
}
