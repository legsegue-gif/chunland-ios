import Foundation

// GET /api/v1/feed —— 类 Twitter 内容流。内容来自外部内容源归档（经 cland.feed_items）。
// 时间字段用 String（与项目其它 Model 一致；APIClient decoder 无 date 策略）。

public struct FeedMedia: Decodable, Sendable, Hashable {
    public let url: String          // 已是完整代理 URL（/api/v1/media/<source>/<key>）
    public let kind: String         // photo | video | animation | document ...
    public let width: Int?
    public let height: Int?
}

public struct FeedItem: Decodable, Identifiable, Sendable, Hashable {
    public let id: Int
    public let source: String       // 内容源标识
    public let kind: String         // text | photo | album | video | link
    public let authorName: String?  // 频道标题
    public let authorHandle: String? // 频道 @username
    public let text: String?
    public let media: [FeedMedia]
    public let meta: FeedMeta?      // 内容源:{links,coupons} / 商家:{productCode,merchantId,price}
    public let channelId: Int64?    // 内容源频道 id（关注频道用）；merchant 行为 nil
    public let publishedAt: String  // ISO8601（带时区）
}

// 卡片附加数据：两种源共用一个可选结构（字段按 source 填，缺失即 nil）
public struct FeedMeta: Decodable, Sendable, Hashable {
    public let links: [FeedLink]?      // 内容源：购买外链
    public let coupons: [String]?      // 内容源：淘口令/优惠码
    public let productCode: String?    // merchant：chunland 商品 code（→ ProductDetailView）
    public let merchantId: Int?
    public let price: Double?
}

public struct FeedLink: Decodable, Sendable, Hashable {
    public let url: String
    public let label: String?
}

// 内容流模式（feed tab）：为你推荐（全量混排）/ 正在关注（仅关注对象，需登录）
public enum FeedMode: String, Sendable {
    case forYou = "foryou"
    case following = "following"
}

// 关注对象类型。target_key：channel=频道 id 文本 / merchant=merchants.id 文本 / product=products.code
// （与 server 校验一致）。product = 商品收藏：进「收藏与关注」管理页，不进 following 流。
public enum FollowTargetType: String, Sendable, Codable {
    case channel
    case merchant
    case product
}

// 关注关系（GET /feed/follows 返回项）
public struct FeedFollow: Decodable, Sendable, Hashable {
    public let targetType: String
    public let targetKey: String
}

// 「收藏与关注」管理页条目（GET /feed/follows/detail 返回项，按关注时间倒序）。
// 对象失效（下架/停用/被删）时 name 可能为 nil 或 available=false —— 行仍显示，用户可手动移除。
public struct FollowDetailItem: Decodable, Sendable, Identifiable, Hashable {
    public let targetType: String
    public let targetKey: String
    public let name: String?
    /// 频道 @username（仅 channel）
    public let handle: String?
    /// 商品缩略图 / 店铺 logo（channel 无）
    public let thumbnail: String?
    /// 商品现价（仅 product）
    public let price: Decimal?
    /// 对象当前是否有效（可购/在营/仍有内容）
    public let available: Bool?

    public var id: String { "\(targetType):\(targetKey)" }
    public var type: FollowTargetType? { FollowTargetType(rawValue: targetType) }
}

public struct FollowDetailList: Decodable, Sendable {
    public let items: [FollowDetailItem]
}

// 0.5 互动埋点事件（发往 POST /feed/events，JSONEncoder 自动转 snake_case）
public struct FeedEvent: Encodable, Sendable {
    public let feedItemId: Int
    public let eventType: String    // impression | click | dwell
    public let dwellMs: Int?
    public init(feedItemId: Int, eventType: String, dwellMs: Int? = nil) {
        self.feedItemId = feedItemId
        self.eventType = eventType
        self.dwellMs = dwellMs
    }
}
