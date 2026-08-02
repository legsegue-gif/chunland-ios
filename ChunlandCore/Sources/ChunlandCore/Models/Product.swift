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
}
