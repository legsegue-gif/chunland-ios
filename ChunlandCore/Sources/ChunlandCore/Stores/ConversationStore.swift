import Foundation
import SwiftData
import Observation

// AI 助手历史会话缓存 + 持久化协调中心。
//
// 自建 ModelContainer（懒加载），**不依赖 SwiftUI @Environment 注入** ——
// 守住「ChunlandCore 与 UI 隔离」的架构约定，orchestrator 也能直接访问。
// activeId 是「当前会话」的唯一源：UI 据此高亮、orchestrator 据此回写。
@MainActor
@Observable
public final class ConversationStore {
    public static let shared = ConversationStore()

    /// 会话列表，按 updatedAt 倒序（最近在前）。UI 再分组成 今天/昨天/更早。
    /// 只含当前登录用户（属主）的会话 —— 换账号绝不外泄他人历史。
    public private(set) var conversations: [AIConversation] = []
    /// 当前活跃会话 id。nil 表示尚未 bootstrap。
    public var activeId: UUID?

    private var isLoaded = false
    /// 当前内存态对应的属主（AuthManager.currentUserId 快照；nil = 游客）。
    /// 属主自愈的锚点：一切读路径先核对它，换账号自动重置重载 ——
    /// 不依赖 logout 时有人记得调清理，视图生命周期怎么变都漏不掉。
    private var loadedOwner: String?

    /// 当前属主（nil = 游客）。
    private var currentOwner: String? { AuthManager.shared.currentUserId }

    /// 新建会话的默认占位标题；首条用户消息发出后由 deriveTitle 替换。
    /// nonisolated：可被 newConversation 的默认参数（nonisolated 上下文）引用。
    nonisolated public static let untitled = "新对话"

    private init() {}

    @ObservationIgnored
    private lazy var _context: ModelContext? = {
        do {
            // 显式 Schema + ModelConfiguration，不依赖隐式推断
            let schema = Schema([AIConversation.self])
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            let container = try ModelContainer(for: schema, configurations: [config])
            return ModelContext(container)
        } catch {
            AppLogger.app.error("ConversationStore: ModelContainer 初始化失败",
                                metadata: ["error": String(describing: error)])
            return nil
        }
    }()
    private var context: ModelContext? { _context }

    // MARK: - 查询

    public func loadIfNeeded() {
        if isLoaded && loadedOwner == currentOwner { return }
        reload()
        isLoaded = true
    }

    public func reload() {
        guard let context else { return }
        let owner = currentOwner
        // 属主变了（换账号/登出）→ 活跃会话指针作废，orchestrator 下次 bootstrap 重建
        if loadedOwner != owner { activeId = nil }
        loadedOwner = owner
        let descriptor = FetchDescriptor<AIConversation>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        let all = (try? context.fetch(descriptor)) ?? []
        // 一次性收编：加属主列之前的遗留会话（ownerUserId=nil）归本机首个登录用户。
        // 单人设备（绝对多数）无感保留历史；代价是共享设备上的遗留行归先登录者，可接受。
        if let owner {
            let orphans = all.filter { $0.ownerUserId == nil }
            if !orphans.isEmpty {
                for o in orphans { o.ownerUserId = owner }
                try? context.save()
            }
        }
        conversations = all.filter { $0.ownerUserId == owner }
    }

    public func conversation(id: UUID) -> AIConversation? {
        conversations.first { $0.id == id }
    }

    /// 当前活跃会话对象。
    public var active: AIConversation? {
        guard let activeId else { return nil }
        return conversation(id: activeId)
    }

    /// 同 contextKey 的最近会话（within 秒内活跃过）—— ✨ 页面会话续聊用。
    /// conversations 已按 updatedAt 倒序，first 即最近。
    public func recentConversation(contextKey: String, within seconds: TimeInterval) -> AIConversation? {
        conversations.first {
            $0.contextKey == contextKey && Date.now.timeIntervalSince($0.updatedAt) < seconds
        }
    }

    // MARK: - 变更

    /// 新建一条会话并置为活跃，返回它。seed 通常为空 —— 历史只存 user/assistant/tool，
    /// system 由 AIOrchestrator 发送期现拼、欢迎语是 View 装饰，都不进历史。
    /// title 非默认值时（如页面 scoped 会话「关于 X」）预置标题；persistCurrent 仅在标题仍为
    /// untitled 时才用首条用户消息派生，故预置标题不会被覆盖。
    @discardableResult
    public func newConversation(seed: [ChatMessage],
                                title: String = ConversationStore.untitled,
                                contextKey: String? = nil) -> AIConversation? {
        guard let context else { return nil }
        let conv = AIConversation(title: title, contextKey: contextKey, ownerUserId: currentOwner)
        conv.setMessages(seed)
        context.insert(conv)
        try? context.save()
        // 先 reload 再置 activeId：reload 的属主自愈可能清 activeId（换账号后首次建会话），
        // 新会话的活跃指针必须在其后落定
        reload()
        activeId = conv.id
        return conv
    }

    /// 把当前 messages 回写到活跃会话；首条用户消息发出后顺带定标题。
    public func persistCurrent(messages: [ChatMessage]) {
        guard let context, let conv = active else { return }
        conv.setMessages(messages)
        if conv.title == Self.untitled {
            conv.title = Self.deriveTitle(from: messages)
        }
        try? context.save()
        reload()   // updatedAt 变了 → 重排序
    }

    /// 摘掉会话的续聊 key（✨「新对话」归档语义）：会话留在抽屉当纯历史，
    /// 之后不再被同 key 的 ✨ 续聊命中 —— 新会话独占该 key。
    public func detachContextKey(_ conv: AIConversation) {
        conv.contextKey = nil
        try? context?.save()
    }

    public func delete(_ conv: AIConversation) {
        guard let context else { return }
        let deletedId = conv.id
        context.delete(conv)
        try? context.save()
        if activeId == deletedId { activeId = nil }
        reload()
    }

    public func deleteAll() {
        guard let context else { return }
        for conv in conversations {
            context.delete(conv)
        }
        try? context.save()
        activeId = nil
        reload()
    }

    public func reset() {
        conversations = []
        activeId = nil
        isLoaded = false
        loadedOwner = nil
    }

    // MARK: - 标题派生

    /// 取首条 user 消息截断作标题（零额外 API 请求）。
    static func deriveTitle(from messages: [ChatMessage]) -> String {
        guard let first = messages.first(where: { $0.role == "user" }),
              let content = first.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            return untitled
        }
        let maxLen = 20
        return content.count <= maxLen ? content : String(content.prefix(maxLen)) + "…"
    }
}
