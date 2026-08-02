import Foundation

public struct Cart: Decodable, Sendable {
    public let cartId: Int
    public var items: [CartItem]
    public let itemsTotal: String
}

public struct CartItem: Decodable, Identifiable, Sendable {
    public let id: Int
    public let productCode: String
    public let selectedSize: String?
    public var quantity: Int
    public let name: String
    public let merchantId: Int
    public let merchantName: String
    public let unitType: String?
    public let randomWeight: Bool
    public let minOrderQuantity: Int?
    public let maxOrderQuantity: Int?
    public let currentPrice: Decimal?
    public let stockStatus: String?
    public let thumbnail: String?
}
