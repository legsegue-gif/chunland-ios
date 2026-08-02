import Foundation

/// 订单会话（IM）服务。三个端点都需登录（APIClient 自动带 token）。
/// 注意：`config()` 每次调用都会在 IM 服务上重新签发连接 token（旧 token 作废），
/// 所以只在真正要建立连接前调用；纯「功能是否开通」判断走 `IMStore.loadIfNeeded()`。
public actor IMService {
    public static let shared = IMService()
    private let api = APIClient.shared

    /// 连接配置（uid + 一次性 token + wsUrl）
    public func config() async throws -> IMClientConfig {
        try await api.get("/im/config")
    }

    /// 打开订单会话：服务端校验参与方 + 幂等建频道
    public func orderChannel(orderId: Int) async throws -> IMChannelInfo {
        try await api.get("/im/orders/\(orderId)/channel")
    }

    /// 买家发起店铺咨询（进店页/商品页「联系商家」）：服务端解析接线人 + 幂等建频道
    public func shopChannel(merchantId: Int) async throws -> IMChannelInfo {
        try await api.get("/im/shops/\(merchantId)/channel")
    }

    /// 按频道打开会话（会话列表点行通用：订单/店铺、双方都可走）
    public func channel(channelId: String) async throws -> IMChannelInfo {
        try await api.get("/im/channels/\(channelId)")
    }

    /// 历史消息（服务端代理 IM 服务）
    public func syncMessages(channelId: String, limit: Int = 50) async throws -> IMSyncResult {
        struct Body: Encodable {
            let channelId: String
            let limit: Int
            let pullMode: Int
        }
        return try await api.post("/im/messages/sync", body: Body(channelId: channelId, limit: limit, pullMode: 1))
    }

    /// 会话列表（订单语义 + 未读数 + 最后一条消息，按时间倒序）。
    /// role: "consumer" | "agent" —— 按「我在订单中的角色」过滤（身份边界）；nil = 全部。
    public func conversations(role: String? = nil) async throws -> [IMConversation] {
        let path = role.map { "/im/conversations?role=\($0)" } ?? "/im/conversations"
        let list: IMConversationList = try await api.get(path)
        return list.items
    }

    /// 未读置零（打开/关闭会话时调用；尽力而为，失败无碍）。
    /// receiptSeq：已读水位（我已看到的对方消息最大 seq）—— 带值时服务端向频道发
    /// type 102 已读回执，发送方据此显示「已读」。仅在水位推进时携带（调用方去重）。
    public func markRead(channelId: String, receiptSeq: Int? = nil) async {
        struct Body: Encodable { let channelId: String; let receiptSeq: Int? }
        struct Empty: Decodable {}
        let _: Empty? = try? await api.post("/im/conversations/read",
                                            body: Body(channelId: channelId, receiptSeq: receiptSeq))
    }

    /// 会话移除（软删：仅本人列表消失，历史保留；对方新消息自动复活会话）
    public func deleteConversation(channelId: String) async throws {
        struct Body: Encodable { let channelId: String }
        struct Empty: Decodable {}
        let _: Empty = try await api.post("/im/conversations/delete", body: Body(channelId: channelId))
    }

    /// 上传会话图片（raw jpeg body，鉴权）→ 返回文件名（消息 payload 存它）
    public func uploadImage(channelId: String, jpeg: Data) async throws -> String {
        struct Resp: Decodable { let name: String }
        let r: Resp = try await api.postData("/im/channels/\(channelId)/media", data: jpeg, contentType: "image/jpeg")
        return r.name
    }

    /// 取会话图片（鉴权二进制 → UIImage 由调用方构造）
    public func imageData(channelId: String, name: String) async throws -> Data {
        try await api.getData("/im/channels/\(channelId)/media/\(name)")
    }

    /// 上传会话视频（raw mp4 body，鉴权）→ 返回文件名（消息 payload 存它 + thumb）
    public func uploadVideo(channelId: String, mp4: Data) async throws -> String {
        struct Resp: Decodable { let name: String }
        let r: Resp = try await api.postData("/im/channels/\(channelId)/media/video", data: mp4, contentType: "video/mp4")
        return r.name
    }

    /// 取会话视频到临时文件。AVPlayer 无法给远端 URL 带 Bearer，故下整段到沙盒临时文件再播（短片可接受）。
    public func videoFileURL(channelId: String, name: String) async throws -> URL {
        let data = try await api.getData("/im/channels/\(channelId)/media/\(name)")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("im-video", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// 上传会话文件（任意类型 raw body，鉴权）→ 返回存储名（原始文件名/大小走消息 meta）
    public func uploadFile(channelId: String, data: Data) async throws -> String {
        struct Resp: Decodable { let name: String }
        let r: Resp = try await api.postData("/im/channels/\(channelId)/media/file", data: data, contentType: "application/octet-stream")
        return r.name
    }

    /// 取会话文件到临时文件。用原始文件名命名，保证 QuickLook 用对扩展名与显示名。
    public func fileURL(channelId: String, name: String, filename: String) async throws -> URL {
        let data = try await api.getData("/im/channels/\(channelId)/media/\(name)")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("im-file", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = filename.replacingOccurrences(of: "/", with: "_")
        let url = dir.appendingPathComponent(safe.isEmpty ? name : safe)
        try data.write(to: url, options: .atomic)
        return url
    }
}
