import Foundation

// MARK: - 商家自助（自建商家）

// GET /api/v1/merchants/self —— 我的店铺。
public struct MyStore: Decodable, Sendable {
    public let id: Int
    public let name: String
    public let type: String          // registered（自建）；爬虫店铺不会出现在这里
    public let logoUrl: String?
    public let areaCode: String?     // 发货地区县（驱动距离定价）
    public let minOrderAmount: Decimal?   // 起送金额（NULL 回退全局）
    public let isActive: Bool
}

// 商家订单只读视图：不含买家地址/联系方式（隐私边界，服务端保证）。
public struct MerchantOrderSummary: Decodable, Identifiable, Sendable {
    public let id: Int
    public let orderNumber: String
    public let status: String
    public let itemsTotal: Decimal    // 货值（平台费/代购费与商家无关，不下发）
    public let itemCount: Int?
    public let createdAt: String
}

public struct MerchantOrderDetail: Decodable, Sendable {
    public struct Item: Decodable, Identifiable, Sendable {
        public let productCode: String
        public let name: String
        public let selectedSize: String?
        public let quantity: Int
        public let unitPrice: Decimal
        public let totalPrice: Decimal
        public var id: String { productCode + (selectedSize ?? "") }
    }
    public let id: Int
    public let orderNumber: String
    public let status: String
    public let itemsTotal: Decimal
    public let createdAt: String
    public let items: [Item]
}

public struct MerchantOrderPage: Decodable, Sendable {
    public let items: [MerchantOrderSummary]
}

// 自家商品（管理视图，含已下架 purchasable=FALSE）。
public struct MerchantProduct: Decodable, Identifiable, Sendable {
    public let code: String
    public let name: String
    public let description: String?
    public let price: Decimal?
    public let purchasable: Bool
    public let sizes: [String]?        // 尺码（M4，鞋服可选）
    public let stockStatus: String?    // inStock | outOfStock（M4 库存开关）
    public let thumbnail: String?
    public let gallery: [String]       // 相册 URL（M4 多图，[0] 为主图）
    public var id: String { code }
}

public struct MerchantProductPage: Decodable, Sendable {
    public let items: [MerchantProduct]
}

public struct UploadedImage: Decodable, Sendable {
    public let url: String
}

// 经营数据（纯读）。GMV 口径 = 非取消/退款订单货值。
public struct MerchantStats: Decodable, Sendable {
    public struct TopProduct: Decodable, Identifiable, Sendable {
        public let name: String
        public let qty: Int
        public var id: String { name }
    }
    public let totalOrders: Int
    public let gmv: Decimal
    public let last30dOrders: Int
    public let last30dGmv: Decimal
    public let topProducts: [TopProduct]
}

// 店铺动态：商家自发图文（进 feed_items，消费者在发现/关注流可见）。
public struct MerchantPost: Decodable, Identifiable, Sendable {
    public struct Media: Decodable, Sendable, Hashable {
        public let url: String
        public let kind: String
    }
    public let id: Int
    public let kind: String        // text | photo | album
    public let text: String?
    public let media: [Media]
    public let productCode: String?   // 挂载的商品（M4 可购卡）
    public let publishedAt: String
}

public struct MerchantPostPage: Decodable, Sendable {
    public let items: [MerchantPost]
}

// 动态配图上传返回：key 供发布引用，url 供本地预览
public struct PostImage: Decodable, Sendable {
    public let key: String
    public let url: String
}

// MARK: - 分类方案（lens）

// 「方案 = 观察商品的一个视角」，一店多方案。公开视图（进店）无 origin/isVisible。
public struct CategoryScheme: Decodable, Identifiable, Sendable, Hashable {
    public struct Cat: Decodable, Identifiable, Sendable, Hashable {
        public let id: Int
        public let name: String
        public let productCount: Int?    // 控制台视图带；公开视图无
        public let children: [Cat]?      // 两级：一级带二级列表（二级恒空数组；旧响应缺省 nil）
        public var subcategories: [Cat] { children ?? [] }
    }
    public let id: Int
    public let name: String
    public let origin: String?           // manual | ai | imported（控制台）
    public let isVisible: Bool?          // 控制台
    public let isDefault: Bool
    public let categories: [Cat]
}

public struct CategorySchemePage: Decodable, Sendable {
    public let items: [CategoryScheme]
}

public struct SchemeCategoryProducts: Decodable, Sendable {
    public let id: Int
    public let productCodes: [String]
}
