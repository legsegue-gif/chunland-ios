import Foundation

// 订单会话（IM）wire 模型。消息真相源在服务端 IM 服务，客户端不落库。
// 两条纪律（与服务端 IM 服务约定对应）：
//   1. 聊天消息不进本地持久化（历史每次经 /im/messages/sync 拉取）
//   2. 聊天只是沟通层，不承载业务操作

/// GET /im/config —— enabled=false 时整个聊天功能隐身
public struct IMClientConfig: Decodable, Sendable {
    public let enabled: Bool
    public let uid: String?
    public let token: String?
    public let wsUrl: String?
    /// 通话子能力开关（CALL_PROVIDER=trtc 时为 true）；缺省/false 时隐藏通话入口
    public let callEnabled: Bool?
}

/// GET /im/orders/:id/channel、GET /im/shops/:merchantId/channel、GET /im/channels/:channelId
/// （订单会话与店铺咨询共用形状，kind 区分）
public struct IMChannelInfo: Decodable, Sendable {
    /// "order" | "shop"
    public let kind: String?
    public let channelId: String
    public let channelType: Int
    public let peerName: String
    /// 店铺咨询的店名（kind == "shop" 时有值）
    public let shopName: String?
    /// 对端用户 id（拉黑操作用）
    public let peerUserId: Int?
    /// 我是否已拉黑对方（聊天页开关初值）
    public let blockedByMe: Bool?
    /// 对方已读水位初值（「已读/未读」标注用；后续推进走 type 102 实时回执）
    public let peerReadSeq: Int?
}

/// POST /im/messages/sync 响应（IM 服务原始形状经服务端透传，snake_case 由解码器转驼峰）
public struct IMSyncResult: Decodable, Sendable {
    public let messages: [IMSyncedMessage]?
}

public struct IMSyncedMessage: Decodable, Sendable {
    public let messageIdstr: String?
    public let messageSeq: Int?
    public let clientMsgNo: String?
    public let fromUid: String?
    /// 秒级时间戳
    public let timestamp: Int?
    /// base64 编码的 payload JSON（{type:1,content:"…"} 文本 / {type:100,…} 系统条）
    public let payload: String?
}

/// GET /im/conversations —— 会话列表条目（服务端已翻译成业务语义：订单会话 / 店铺咨询）
public struct IMConversation: Decodable, Identifiable, Sendable {
    /// "order" | "shop"
    public let kind: String?
    public let channelId: String?
    /// 订单会话字段（kind == "order"）
    public let orderId: Int?
    public let orderNumber: String?
    public let orderStatus: String?
    /// 店铺咨询字段（kind == "shop"）
    public let merchantId: Int?
    public let shopName: String?
    public let peerName: String
    public let unread: Int
    /// 最后一条消息的秒级时间戳
    public let timestamp: Int
    public let lastMessage: String?
    public let lastIsSystem: Bool?
    public let lastFromMe: Bool?

    public var id: String { channelId ?? orderId.map { "order_\($0)" } ?? peerName }
    public var isShop: Bool { kind == "shop" }
}

public struct IMConversationList: Decodable, Sendable {
    public let items: [IMConversation]
}

/// GET /blocks —— 黑名单条目（联系方式已脱敏）
public struct BlockedUser: Decodable, Identifiable, Sendable {
    public let userId: Int
    public let displayName: String
    public let createdAt: String?

    public var id: Int { userId }
}

public struct BlockedUserList: Decodable, Sendable {
    public let items: [BlockedUser]
}
