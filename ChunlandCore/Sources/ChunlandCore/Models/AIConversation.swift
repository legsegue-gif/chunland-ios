import Foundation
import SwiftData

// 编解码器放文件级（不放 @Model 类里）—— 避免 @Model 宏处理类内 static 属性时出岔。
private let conversationEncoder = JSONEncoder()
private let conversationDecoder = JSONDecoder()

// MARK: - AIConversation（SwiftData 持久化模型）
//
// 一条 AI 助手会话。messages 以 Data blob 形式存储（序列化的 [StoredMessage]）——
// 不用 SwiftData relationship，因为 ChatMessage 嵌套 ToolCall/images/reasoning，
// 结构复杂、且其 Codable 自定义 encode 是给 OpenAI API 用的，不适合直接当 @Model。
//
// 注意：id 不加 @Attribute(.unique) —— UUID 已天然唯一，加 .unique 反而是
// SwiftData fetch 崩溃（EXC_BREAKPOINT）的已知来源。
@Model
public final class AIConversation {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var messagesBlob: Data
    // 页面 scoped 会话的续聊 key（如 "product:123456"）；tab 会话为 nil。
    // optional + 默认 nil → SwiftData 轻量迁移，旧库无需手动升级
    public var contextKey: String?
    // 会话属主（AuthManager.currentUserId）。会话是账号数据，不是设备数据 ——
    // 同设备换账号登录绝不能看到别人的对话历史（含店铺经营数据）。
    // nil = 游客创建 / 加列前的遗留数据（遗留行由 ConversationStore 首次登录时收编）。
    // optional + 默认 nil → SwiftData 轻量迁移，旧库无需手动升级
    public var ownerUserId: String?

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        messagesBlob: Data = Data(),
        contextKey: String? = nil,
        ownerUserId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messagesBlob = messagesBlob
        self.contextKey = contextKey
        self.ownerUserId = ownerUserId
    }

    /// 还原成运行时的 [ChatMessage]（含 images / reasoning，与发送态完全一致）。
    public func decodeMessages() -> [ChatMessage] {
        guard let stored = try? conversationDecoder.decode([StoredMessage].self, from: messagesBlob) else {
            return []
        }
        return stored.map { $0.toChatMessage() }
    }

    /// 写入消息（同时刷新 updatedAt）。
    public func setMessages(_ msgs: [ChatMessage]) {
        let stored = msgs.map { StoredMessage($0) }
        messagesBlob = (try? conversationEncoder.encode(stored)) ?? Data()
        updatedAt = .now
    }
}

// MARK: - StoredMessage（持久化专用 DTO）
//
// ⚠️ 不能直接拿 ChatMessage 的 Codable 来持久化：它的 CodingKeys 只含
// role/content/toolCallId/toolCalls/name，**故意排除了 images 和 reasoning**
// （自定义 encode 是为了拼 OpenAI vision 的 content 数组）。直接序列化 ChatMessage
// 会丢图片和思考过程。这里用全字段 DTO 做无损存储，与 ChatMessage 互转。
struct StoredMessage: Codable {
    var id: UUID
    var role: String
    var content: String?
    var toolCallId: String?
    var toolCalls: [ToolCall]?
    var name: String?
    var reasoning: String?
    var images: [String]?

    init(_ m: ChatMessage) {
        id = m.id
        role = m.role
        content = m.content
        toolCallId = m.toolCallId
        toolCalls = m.toolCalls
        name = m.name
        reasoning = m.reasoning
        images = m.images
    }

    func toChatMessage() -> ChatMessage {
        ChatMessage(
            id: id,
            role: role,
            content: content,
            toolCallId: toolCallId,
            toolCalls: toolCalls,
            name: name,
            reasoning: reasoning,
            images: images
        )
    }
}
