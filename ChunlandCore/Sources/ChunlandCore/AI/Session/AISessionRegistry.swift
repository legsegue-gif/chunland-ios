import Foundation
import Observation

// MARK: - 会话实例注册表
//
// **每个 contextKey 一个会话实例，进程内复用。**
//
// 这是对旧实现的替换。旧的是「一个全局 orchestrator + 切进切出」：
//   startScopedConversation  记住当前 tab 会话 id、装载新上下文、可能续聊
//   endScopedConversation    存盘、恢复 tab 会话、挂起 id 失效时还要回退
//   外加一个 `started` 标志防 onAppear 重入
//
// 每一步都在处理「同一个对象被反复改用途」带来的状态残留。多实例把这类
// 问题整体消掉：进店的会话和购物车的会话是两个对象，互不知道对方存在。

@MainActor
public final class AISessionRegistry {

    private var sessions: [String: AIChatSession] = [:]

    private let db: AIDatabase
    private let config: ProviderConfigStore
    private let sessionRepo: SessionRepo
    private let messageRepo: MessageRepo
    /// 建工具执行器。收整个 `AIContext` 而不只是 scope ——
    /// 工具集裁剪要同时用到作用域与页面建议的子集。
    private let executorFactory: @MainActor (AIContext) -> any AgentToolExecuting
    private let ownerUserId: () -> String?

    public init(db: AIDatabase,
                config: ProviderConfigStore,
                executorFactory: @escaping @MainActor (AIContext) -> any AgentToolExecuting,
                ownerUserId: @escaping () -> String?) {
        self.db = db
        self.config = config
        self.sessionRepo = SessionRepo(db: db)
        self.messageRepo = MessageRepo(db: db)
        self.executorFactory = executorFactory
        self.ownerUserId = ownerUserId
    }

    /// 取（或建）该上下文的会话实例。
    public func session(for context: AIContext) -> AIChatSession {
        let key = context.contextKey ?? context.title
        if let existing = sessions[key] { return existing }

        let executor = executorFactory(context)
        let detector = ToolLoopDetector()
        let factory = ProviderFactory(config: config) { ref in
            // 图片字节只在 wire 编码那一刻读，读完即弃
            try? MediaStore(db: self.db).loadData(ref)
        }
        let router = ProviderRouter(config: config, factory: factory)

        // pipeline 需要 confirmer，而 confirmer 就是 session 自己（HITL 单槽位）——
        // 先建 session 再补 pipeline 会绕，所以用一个转发壳打破循环依赖。
        let forwarder = ConfirmForwarder()
        let pipeline = AgentToolPipeline(
            executor: executor,
            confirmer: forwarder,
            detector: detector
        )
        // 压缩摘要走单次协议 —— 与对话共用同一套配置与传输，
        // 但**不带工具**（摘要不该触发工具调用）。
        let config = self.config
        let loop = AgentLoop(
            router: router,
            pipeline: pipeline,
            executor: executor,
            detector: detector,
            summarize: { transcript in
                guard let entry = await config.resolveEntry(binding: nil) else {
                    throw LLMError.notConfigured
                }
                let provider = try await factory.make(entry: entry)
                return try await provider.completeText(
                    messages: [.user(AIPrompts.compactionRequest(conversation: transcript))],
                    systemPrompt: AIPrompts.compaction,
                    // 摘要要压缩内容，给太多额度反而让它啰嗦
                    maxTokens: min(2048, entry.maxOutputTokens)
                )
            }
        )
        let session = AIChatSession(
            context: context,
            loop: loop,
            sessions: sessionRepo,
            messages: messageRepo,
            config: config,
            ownerUserId: ownerUserId
        )
        forwarder.target = session

        sessions[key] = session
        return session
    }

    /// 丢弃某个会话实例（关闭页面且会话为空时）。
    public func discard(contextKey: String) {
        sessions.removeValue(forKey: contextKey)
    }

    /// 换账号 / 登出：全部清掉。
    ///
    /// 会话是账号数据 —— 同设备换账号绝不能看到别人的对话，
    /// 内存里的实例也必须一并丢弃（库里按 owner 过滤只挡住了读路径）。
    public func reset() {
        for session in sessions.values {
            session.stop()
        }
        sessions.removeAll()
    }
}

/// 确认请求的转发壳。
///
/// 只为打破「pipeline 需要 confirmer，而 confirmer 是 session，session 又需要
/// 装好 pipeline 的 loop」这个循环。除了转发不做任何事。
@MainActor
final class ConfirmForwarder: MutationConfirming {
    weak var target: AIChatSession?

    func confirm(_ batch: [AgentMutationIntent]) async -> Bool {
        guard let target else { return false }
        return await target.confirm(batch)
    }
}
