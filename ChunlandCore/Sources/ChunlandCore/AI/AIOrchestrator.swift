import Foundation

// MARK: - OpenAI-compatible message types

public struct ChatMessage: Codable, Identifiable {
    public var id = UUID()
    public var role: String       // "user" | "assistant" | "tool"
    public var content: String?
    public var toolCallId: String?
    public var toolCalls: [ToolCall]?
    public var name: String?      // tool name when role == "tool"

    // 模型思考过程（仅 assistant message 可能有值；DeepSeek/Gemma 等支持的 endpoint）
    // 注意：刻意不在 CodingKeys 中 —— 永远不回发给 AI，避免污染对话历史 + 浪费 token
    public var reasoning: String? = nil

    // Phase 2：多模态图片附件（base64 data URL，如 "data:image/jpeg;base64,…"）。
    // 不入 CodingKeys —— 由自定义 encode(to:) 与 content 合成 OpenAI vision 的 content 数组
    public var images: [String]? = nil

    enum CodingKeys: String, CodingKey {
        case role, content, toolCallId, toolCalls, name
    }

    // 多模态 content parts 编码用（convertToSnakeCase 会把 imageUrl → image_url）
    private enum PartKeys: String, CodingKey { case type, text, imageUrl }
    private enum ImageURLKeys: String, CodingKey { case url }

    // 自定义编码：有图 → content 编成 OpenAI parts 数组 [{type:text},{type:image_url}…]；
    // 无图 → content 编成普通字符串（与改造前一致，向后兼容）。Decodable 仍自动合成（只读 CodingKeys）
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encodeIfPresent(toolCallId, forKey: .toolCallId)
        try c.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try c.encodeIfPresent(name, forKey: .name)
        if let images, !images.isEmpty {
            var parts = c.nestedUnkeyedContainer(forKey: .content)
            if let text = content, !text.isEmpty {
                var t = parts.nestedContainer(keyedBy: PartKeys.self)
                try t.encode("text", forKey: .type)
                try t.encode(text, forKey: .text)
            }
            for url in images {
                var im = parts.nestedContainer(keyedBy: PartKeys.self)
                try im.encode("image_url", forKey: .type)
                var iu = im.nestedContainer(keyedBy: ImageURLKeys.self, forKey: .imageUrl)
                try iu.encode(url, forKey: .url)
            }
        } else {
            try c.encodeIfPresent(content, forKey: .content)
        }
    }

    public static func system(_ text: String) -> ChatMessage {
        ChatMessage(role: "system", content: text, toolCallId: nil, toolCalls: nil, name: nil)
    }

    public static func user(_ text: String) -> ChatMessage {
        ChatMessage(role: "user", content: text, toolCallId: nil, toolCalls: nil, name: nil)
    }

    // Phase 2：带图片附件的 user 消息（images 为 base64 data URL 数组）
    public static func user(_ text: String, images: [String]) -> ChatMessage {
        ChatMessage(role: "user", content: text, toolCallId: nil, toolCalls: nil, name: nil,
                    images: images.isEmpty ? nil : images)
    }

    public static func assistant(_ text: String) -> ChatMessage {
        ChatMessage(role: "assistant", content: text, toolCallId: nil, toolCalls: nil, name: nil)
    }

    // 流式占位 message —— content 用 nil 而不是 ""（避免空字符串残留触发某些 endpoint 的模板渲染错误，例如 LM Studio jinja）
    public static func assistantPlaceholder() -> ChatMessage {
        ChatMessage(role: "assistant", content: nil, toolCallId: nil, toolCalls: nil, name: nil)
    }

    public static func toolResult(callId: String, toolName: String, result: String) -> ChatMessage {
        ChatMessage(role: "tool", content: result, toolCallId: callId, toolCalls: nil, name: toolName)
    }
}

public struct ToolCall: Codable, Sendable {
    public var id: String
    public var type: String
    public var function: ToolCallFunction
}

public struct ToolCallFunction: Codable, Sendable {
    public var name: String
    public var arguments: String  // JSON string
}

// MARK: - AI API Request

private struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let tools: [AITool]
    let toolChoice: String = "auto"
    let stream: Bool = true
}

// MARK: - SSE Stream Chunk types (OpenAI standard)
//
// 每个 chunk 形如：
//   data: {"choices":[{"index":0,"delta":{"content":"加"},"finish_reason":null}], ...}
//
// 兼容两类 tool_call 实现：
//   - 标准 OpenAI：tool_calls.arguments 按字符 delta 切片，按 index 累积
//   - 部分兼容端：tool_calls 一次性完整返回（仍走同套 buffer 逻辑，无副作用）

private struct StreamChunk: Decodable {
    let choices: [StreamChoice]?

    struct StreamChoice: Decodable {
        let delta: StreamDelta
        let finishReason: String?
    }

    struct StreamDelta: Decodable {
        let role: String?
        let content: String?
        let toolCalls: [StreamToolCallDelta]?
        // 模型 thinking 内容（DeepSeek R1 / Gemma 等）
        // 兼容两种字段名：
        //   - reasoning_content (DeepSeek 标准，gemma-4-e4b 用此)
        //   - reasoning         (某些适配器变体)
        // 任何不支持的 endpoint 这两个字段都缺，reasoning = nil
        let reasoning: String?

        enum CodingKeys: String, CodingKey {
            case role, content, toolCalls
            case reasoningContent       // → JSON "reasoning_content"（keyDecoder snake_case）
            case reasoning              // → JSON "reasoning"（直接匹配）
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            role     = try c.decodeIfPresent(String.self, forKey: .role)
            content  = try c.decodeIfPresent(String.self, forKey: .content)
            toolCalls = try c.decodeIfPresent([StreamToolCallDelta].self, forKey: .toolCalls)
            // 优先 reasoning_content；某些端点用 reasoning
            let primary  = try c.decodeIfPresent(String.self, forKey: .reasoningContent)
            let fallback = try c.decodeIfPresent(String.self, forKey: .reasoning)
            reasoning = primary ?? fallback
        }
    }

    struct StreamToolCallDelta: Decodable {
        let index: Int
        let id: String?
        let type: String?
        let function: StreamToolCallFunctionDelta?
    }

    struct StreamToolCallFunctionDelta: Decodable {
        let name: String?
        let arguments: String?
    }
}

private enum StreamResult {
    case finished                       // finish_reason=stop / length, 占位 message 已含完整文本
    case toolCalls([ToolCall])          // finish_reason=tool_calls, 占位 message 已转 tool_call 形态
    case interrupted                    // Task.cancel / 网络断
    case error(String)
}

// SSE event: error 帧的 payload 形态（兼容 LM Studio / Ollama / 其他实现的常见格式）
private struct SSEErrorPayload: Decodable {
    let error: ErrorDetail?
    let message: String?

    struct ErrorDetail: Decodable {
        let message: String?
    }
}

// MARK: - AIOrchestrator

@MainActor
public final class AIOrchestrator: ObservableObject {
    @Published public var messages: [ChatMessage] = []
    @Published public var isThinking = false
    // 整个 send 生成周期为 true（含首 token 之后的流式输出）；停止按钮据此显示，比 isThinking 更完整
    @Published public var isResponding = false

    // HITL（Human-in-the-loop）—— AI 想执行 mutation 工具时设此值，
    // View 监听后弹 confirmationDialog；用户决策走 confirmIntent / cancelIntent
    @Published public var pendingIntent: MutationIntent?

    // 是否已有可用 AI 配置（View 据此在「配置 CTA / 欢迎语」间分支）。
    // 必须 @Published：configure 不再必然改 messages，靠它保证配置后视图刷新。
    @Published public private(set) var isConfigured = false

    // 当前会话的欢迎语 —— View 层视觉元素（会话为空时显示的固定气泡）。
    // 刻意不作为 assistant 消息进对话历史：喂给模型会被当成"自己说过的话"照抄（复读问题根因）。
    @Published public private(set) var welcomeText = AIOrchestrator.defaultWelcome
    public static let defaultWelcome = "你好！我是你的代购助手。你想买什么？"

    private var pendingContinuation: CheckedContinuation<Bool, Never>?
    private var config: AIConfig?
    private var apiKey: String?
    private let authManager: AuthManager

    // 当前正在跑的流式 agent loop —— clearConversation 时 cancel
    private var streamingTask: Task<Void, Never>?

    // 当前会话的工具子集（nil = 全量）。页面 scoped 会话据 AIContext.tools 设；
    // tab 路径（startNewConversation / loadConversation）恒置 nil → 回 tab 永远全量工具。
    private var toolScope: Set<AIToolName>?

    // 当前会话的结构化作用域（AIContext.scope）—— 工具执行时作为第二参数注入，
    // 进店等场景据此把 search_products / get_categories 硬限定到当前商家。
    // tab 路径恒回 .global。
    private var runScope: AIToolScope = .global

    // ✨ scoped 会话开始前 tab 的活跃会话 id —— sheet 关闭时恢复，
    // 避免「从页面聊完回到 AI tab，主对话被 scoped 会话顶掉」。
    private var suspendedTabConversationId: UUID?

    public init(authManager: AuthManager) {
        self.authManager = authManager
    }

    public func configure(config: AIConfig, apiKey: String) {
        self.config = config
        self.apiKey = apiKey
        isConfigured = true
        // 不再清空 messages —— 改个 model / key 不该丢掉正在进行的对话。
        // 仅首次配置（还没有任何活跃会话）才开一条新会话。
        if ConversationStore.shared.activeId == nil {
            startNewConversation()
        }
    }

    // 当前会话的页面上下文事实（AIContext.seedNote，scoped ✨ 注入；tab 会话为 nil）。
    // system prompt 发送期由它现拼（composedSystemPrompt），**不存进会话历史** ——
    // 存了就冻结了：prompt 后续迭代永远触达不了存量会话（旧版即此病，Android 一直是现拼）。
    private var seedNote: String?

    // 完整人设：身份 + 回复风格 + 输出格式 + 工具规则。
    // 工具规则的核心是避免模型把历史 tool result 当永久事实复用。
    private static let systemPrompt = """
    你是代购平台 App 的内置助手，帮用户挑选商品、加入购物车、下单、跟进订单。
    用户可能同时拥有买家/代购人/商家多重身份，但工具集按其**当前活跃身份**下发：
    买家身份才有选购/购物车/下单工具，代购身份才有接单/采购清单/结算工具，
    商家身份才有店铺商品/分类方案工具。用户想做当前身份之外的事（如代购身份下想买东西）时，
    不要凭对话历史调用当前不可用的工具，直接提示其到「我的」页切换身份后再来。

    回复风格：
    - 简洁直接：先给结论或答案，再补必要细节；不重复问候，不复述用户的话。
    - 默认用中文回复；用户用其他语言提问时跟随对方语言。
    - 排版用 Markdown：关键信息（价格、数量、状态）用**粗体**，多个商品或选项用列表；金额统一写成 ¥1,234.56 格式。
    - 拿不准的信息（价格、库存、订单状态）不要凭记忆编造 —— 先用工具查询再回答。

    工具规则（违反会让用户看到过期数据）：
    1. 涉及实时可变数据的问题（购物车内容、订单状态等），**每次都必须重新调用对应的工具**获取最新数据。两次对话之间用户可能修改了数据，**不要复用历史 tool 结果**。
    2. 加购 (add_to_cart) 和 下单 (place_order) 是变更操作 —— 调用前先用一句话告诉用户你打算做什么，再调用工具。
    3. 商品搜索结果（search_products / get_product_detail）可以适当复用，但用户说"再搜一次/刷新"时必须重新调用。
    4. 下单 (place_order) 的收货地址自动取用户地址簿的默认地址，费用以服务端报价为准，两者都会在确认弹窗里展示给用户 —— **绝不向用户索要姓名/电话/收货地址，也不要凭空报费用**。用户没有地址时引导其到「我的 → 地址管理」添加；想换地址时告知其到购物车结算页选择，或先调整默认地址。
    """

    /// 发送期现拼的完整 system prompt：基础人设 + 当前会话的页面上下文（scoped ✨）。
    private func composedSystemPrompt() -> String {
        guard let note = seedNote, !note.isEmpty else { return Self.systemPrompt }
        return "\(Self.systemPrompt)\n\n当前上下文：\(note)"
    }

    // MARK: - 会话生命周期（历史会话持久化）

    /// AIView 出现时调：恢复 AI 配置 + 加载最近会话（无会话则开新）。幂等，可重复调。
    public func bootstrap() {
        restoreConfig()
        ConversationStore.shared.loadIfNeeded()
        // 已有活跃会话（热重入 / 已 bootstrap）→ 保持现状
        if ConversationStore.shared.activeId != nil { return }
        if let recent = ConversationStore.shared.conversations.first {
            loadConversation(id: recent.id)
        } else {
            startNewConversation()
        }
    }

    /// 从本地（UserDefaults + Keychain）恢复 AI 配置，不触碰 messages。
    /// 冷启动后即可直接续聊历史会话，无需重进设置页。
    public func restoreConfig() {
        guard config == nil else { return }
        // 系统 AI：baseUrl 留空，streamCallAI 每次实时取 endpoint（避开冷启动时序）。
        if UserDefaults.standard.bool(forKey: "ai_use_system") {
            self.config = AIConfig(provider: "system", baseUrl: "", model: SystemAIProvider.defaultModel)
            self.apiKey = SystemAIProvider.internalKey
            isConfigured = true
            return
        }
        guard let baseUrl = UserDefaults.standard.string(forKey: "ai_base_url"),
              let model = UserDefaults.standard.string(forKey: "ai_model"),
              let key = authManager.aiApiKey, !key.isEmpty else { return }
        self.config = AIConfig(provider: "openai", baseUrl: baseUrl, model: model)
        self.apiKey = key
        isConfigured = true
    }

    /// 新建空会话：先存当前对话，再开一条全空的新会话。
    /// 历史只存 user/assistant/tool —— system 发送期现拼（composedSystemPrompt），
    /// 欢迎语是 View 层装饰（welcomeText），两者都不进历史。
    public func startNewConversation() {
        cancelOngoing()
        persistCurrent()
        toolScope = nil            // tab 路径恒全量工具
        runScope = .global
        seedNote = nil
        welcomeText = Self.defaultWelcome
        messages = []
        ConversationStore.shared.newConversation(seed: [])
    }

    /// 同 contextKey 的会话多久内可续聊（超过则视为过期、重新开）。
    private static let scopedResumeWindow: TimeInterval = 24 * 3600

    /// 从功能页面唤起的「带上下文」会话（方案 B）：注入 seedNote（system 消息，用户
    /// 不可见、只喂模型）+ 工具子集，标题预置为 context.title（「关于 X」），
    /// 存入历史抽屉、不污染 tab 的持久会话。scoped 欢迎语走 welcomeText（View 层装饰）。
    /// 24h 内同 contextKey 的会话直接续聊 —— 「问一半收起再开」上下文不丢。
    public func startScopedConversation(_ context: AIContext) {
        // 冷启动后不经 AI tab 直接 ✨ 唤起：bootstrap 没跑过，这里补恢复配置（幂等）。
        // 否则 isConfigured=false 误显配置 CTA（改造前的等价缺陷是欢迎语在但发送静默无响应）。
        restoreConfig()
        ConversationStore.shared.loadIfNeeded()
        cancelOngoing()
        persistCurrent()
        // 记住 tab 会话以便 sheet 关闭时恢复（连续开两个 ✨ 时已挂起的不被 scoped id 覆盖）
        if suspendedTabConversationId == nil {
            suspendedTabConversationId = ConversationStore.shared.activeId
        }
        toolScope = context.tools
        runScope = context.scope
        seedNote = context.seedNote   // 发送期并入唯一一条 system（composedSystemPrompt）
        welcomeText = context.welcome ?? "你好！有什么可以帮你？"

        // 续聊：同 key 的近期会话直接灌回。seedNote 用页面刚传入的（不是历史里存的）——
        // 旧版把 system 存进历史导致 prompt 冻结，这里顺带过滤掉存量会话里的遗留 system 帧（迁移）。
        if let key = context.contextKey,
           let existing = ConversationStore.shared.recentConversation(contextKey: key, within: Self.scopedResumeWindow) {
            messages = existing.decodeMessages().filter { $0.role != "system" }
            ConversationStore.shared.activeId = existing.id
            return
        }

        messages = []
        ConversationStore.shared.newConversation(seed: [], title: context.title, contextKey: context.contextKey)
    }

    /// ✨ 面板「新对话」按钮：归档语义 —— 旧 scoped 会话**留在抽屉**当历史（只摘掉
    /// contextKey，不删），原地另起一条同上下文的新会话（新会话独占续聊 key）。
    /// suspendedTabConversationId 不动 —— 关 sheet 仍恢复 tab 会话。
    public func restartScopedConversation(_ context: AIContext) {
        cancelOngoing()
        persistCurrent()   // 旧会话消息存好，随后进抽屉
        if let conv = ConversationStore.shared.active {
            ConversationStore.shared.detachContextKey(conv)
        }
        // 复用新开路径：旧会话已摘 key，resume 必不命中 → 必然全新会话
        startScopedConversation(context)
    }

    /// ✨ sheet 关闭时调（AIChatSheet.onDisappear）：存好 scoped 会话、恢复 tab 原会话。
    /// 没聊过的空 scoped 会话（只有 system seed）直接删除 —— 不让抽屉堆一次性死会话。
    public func endScopedConversation() {
        cancelOngoing()
        let hadUserMessage = messages.contains { $0.role == "user" }
        if hadUserMessage {
            persistCurrent()
        } else if let conv = ConversationStore.shared.active {
            ConversationStore.shared.delete(conv)
        }
        toolScope = nil
        runScope = .global
        seedNote = nil
        welcomeText = Self.defaultWelcome
        let tabId = suspendedTabConversationId
        suspendedTabConversationId = nil
        if let tabId, let conv = ConversationStore.shared.conversation(id: tabId) {
            messages = conv.decodeMessages().filter { $0.role != "system" }
            ConversationStore.shared.activeId = tabId
        } else if let recent = ConversationStore.shared.conversations.first(where: { $0.contextKey == nil }) {
            // 冷启动未经 AI tab 直接 ✨（挂起时 activeId 还是 nil）→ 恢复最近一条主对话，
            // 不新造空会话（否则这条路径每走一次抽屉多一条「新对话」死会话）
            messages = recent.decodeMessages().filter { $0.role != "system" }
            ConversationStore.shared.activeId = recent.id
        } else {
            // 全库无主对话（全新安装即 ✨）→ 开一条空白新会话兜底
            startNewConversation()
        }
    }

    /// 清空全部历史会话，然后开一条空白新会话（避免删完后无活跃会话）。
    public func deleteAllConversations() {
        cancelOngoing()
        ConversationStore.shared.deleteAll()
        seedNote = nil
        welcomeText = Self.defaultWelcome
        messages = []
        ConversationStore.shared.newConversation(seed: [])
    }

    /// 切换到指定历史会话：先存当前，再把目标会话的消息灌回 UI。
    public func loadConversation(id: UUID) {
        guard let conv = ConversationStore.shared.conversation(id: id) else { return }
        cancelOngoing()
        persistCurrent()
        toolScope = nil            // 从历史重开（含旧 scoped 会话）一律回全量工具
        runScope = .global
        seedNote = nil             // 抽屉重开 = tab 语义：全局作用域，页面上下文不再随行
        welcomeText = Self.defaultWelcome
        messages = conv.decodeMessages().filter { $0.role != "system" }
        ConversationStore.shared.activeId = id
    }

    /// 把当前 messages 回写到活跃会话（无活跃会话时为 no-op）。
    public func persistCurrent() {
        ConversationStore.shared.persistCurrent(messages: messages)
    }

    /// 取消正在跑的流式请求 + pending intent（切换/新建会话前的清理）。
    private func cancelOngoing() {
        streamingTask?.cancel()
        streamingTask = nil
        pendingContinuation?.resume(returning: false)
        pendingContinuation = nil
        pendingIntent = nil
    }

    // MARK: - HITL: 用户决策入口

    public func confirmIntent() {
        guard let continuation = pendingContinuation else { return }
        pendingContinuation = nil
        pendingIntent = nil
        continuation.resume(returning: true)
    }

    public func cancelIntent() {
        guard let continuation = pendingContinuation else { return }
        pendingContinuation = nil
        pendingIntent = nil
        continuation.resume(returning: false)
    }

    private func awaitConfirmation(_ intent: MutationIntent) async -> Bool {
        // dev 期默认 aiAutoConfirm = true，跳过弹窗自动执行；上线前关掉
        if AppSettings.shared.aiAutoConfirm {
            return true
        }
        return await withCheckedContinuation { continuation in
            pendingContinuation = continuation
            pendingIntent = intent
        }
    }

    // MARK: - 发送期历史组装
    //
    // 两个变换只作用于发出去的请求 —— UI 与本地持久化始终保留完整原文：
    //  1. 轮次裁剪：只保留最近 maxUserTurns 个用户轮。在用户消息边界整轮切，
    //     assistant.tool_calls 与其 tool 结果天然成对保留/成对丢弃（拦腰截断会破 wire 协议）；
    //     更早的折叠成一句占位。老轮的图片附件（base64）也随之整轮卸掉。
    //  2. 过期工具结果折叠：最后一个用户消息之前的实时类工具结果（resultIsVolatile：
    //     购物车/订单/接单/店铺快照）替换为占位 —— 物理杜绝模型复用过期数据（比 prompt
    //     规则 1 的许愿硬），token 同时大降。搜索/详情/分类结果刻意保留（规则 3 允许复用）。
    // 兼容：顺带滤掉存量会话遗留的 system 帧（旧版曾把 system 存进历史）。
    static func wireHistory(_ history: [ChatMessage], maxUserTurns: Int = 8) -> [ChatMessage] {
        var msgs = history.filter { $0.role != "system" }
        let userIdxs = msgs.indices.filter { msgs[$0].role == "user" }
        if userIdxs.count > maxUserTurns {
            let cut = userIdxs[userIdxs.count - maxUserTurns]
            msgs = [.assistant("（更早的 \(cut) 条消息已折叠以节省上下文）")] + Array(msgs[cut...])
        }
        guard let lastUser = msgs.lastIndex(where: { $0.role == "user" }) else { return msgs }
        for i in msgs.indices where i < lastUser {
            guard msgs[i].role == "tool", let name = msgs[i].name,
                  AIToolName(rawValue: name)?.resultIsVolatile == true else { continue }
            msgs[i].content = "（此工具结果已过期折叠；需要最新数据请重新调用 \(name)）"
        }
        return msgs
    }

    // MARK: - Main send

    public func send(_ userText: String, images: [String] = []) async {
        guard let config, let apiKey else { return }
        messages.append(images.isEmpty ? .user(userText) : .user(userText, images: images))
        isThinking = true
        isResponding = true
        defer { isThinking = false; isResponding = false }

        // 包成 Task 以便 clearConversation 时 cancel
        // isThinking=true 期间 UI 输入栏 disable，不会并发 send，所以无需识别"同一 task"
        let task = Task { @MainActor in
            await runAgentLoop(config: config, apiKey: apiKey)
        }
        streamingTask = task
        await task.value
        streamingTask = nil

        // 每轮对话结束回写本地会话（首条用户消息发出后顺带定标题）
        persistCurrent()
    }

    /// 流式生成中由 UI「停止按钮」调用 —— 复用 clearConversation 的 cancel 路径：
    /// runAgentLoop 抛 CancellationError → appendInterruptedMark → send 的 defer 复位 isThinking。
    public func stop() {
        streamingTask?.cancel()
    }

    // MARK: - Agent loop (流式版本)

    private func runAgentLoop(config: AIConfig, apiKey: String) async {
        var iterations = 0

        while iterations < 8 {
            iterations += 1

            let result = await streamCallAI(config: config, apiKey: apiKey)
            switch result {
            case .finished:
                #if DEBUG
                AIDebugFileLog.response(outcome: "finished", message: messages.last)
                #endif
                // 异常 finish（stream 正常结束但 placeholder 一片空白）—— 防御性清理 + 提示
                // 避免空 placeholder 残留污染对话历史，导致后续请求触发某些 endpoint 的模板错误
                if discardEmptyPlaceholder() {
                    messages.append(.assistant("AI 返回了空响应，请重试。"))
                }
                return

            case .toolCalls(let calls):
                #if DEBUG
                AIDebugFileLog.response(outcome: "toolCalls", message: messages.last)
                #endif
                // 占位 message 已经被替换为 tool_call 形态，执行工具后继续循环
                let results = await executeToolBatch(calls)
                for (call, toolResult) in zip(calls, results) {
                    messages.append(.toolResult(callId: call.id, toolName: call.function.name, result: toolResult))
                }

            case .interrupted:
                #if DEBUG
                AIDebugFileLog.response(outcome: "interrupted", message: messages.last)
                #endif
                // 在占位 message 后追加中断标记（保留已生成的部分）
                appendInterruptedMark()
                return

            case .error(let detail):
                #if DEBUG
                AIDebugFileLog.response(outcome: "error", message: messages.last, detail: detail)
                #endif
                // 占位 message 为空则丢弃，否则保留部分内容
                discardEmptyPlaceholder()
                messages.append(.assistant(Self.friendlyErrorText(detail)))
                return
            }
        }

        messages.append(.assistant("抱歉，查询轮次过多，请换个问题试试。"))
    }

    // 错误原样透传对用户是天书（"HTTP 429"）—— 按已知模式映射成人话。
    // 原始 detail 已进 DEBUG 日志（AIDebugFileLog），排查不受影响。
    // 系统 AI 的服务级文案（"维护中"等）不命中任何模式 → 走 fallback，行为与改前一致。
    private static func friendlyErrorText(_ detail: String) -> String {
        let d = detail.lowercased()
        if d.contains("429") { return "AI 服务当前请求较多，请稍等片刻再试。" }
        if d.contains("401") || d.contains("403") { return "AI 服务鉴权失败，请到 AI 配置里检查来源或 API Key。" }
        if d.contains("http 5") { return "AI 服务暂时不可用，请稍后再试。" }
        if d.contains("timed out") || detail.contains("超时") { return "AI 响应超时，请重试。" }
        if d.contains("offline") || d.contains("not connected") || detail.contains("断开") || detail.contains("网络连接") {
            return "网络连接不可用，请检查网络后重试。"
        }
        return "抱歉，AI 请求失败：\(detail)"
    }

    private func appendInterruptedMark() {
        guard let last = messages.indices.last else { return }
        var m = messages[last]
        if let c = m.content, !c.isEmpty {
            m.content = c + "\n\n（…回复被中断）"
        } else {
            m.content = "（回复被中断）"
            m.toolCalls = nil
        }
        messages[last] = m
    }

    @discardableResult
    private func discardEmptyPlaceholder() -> Bool {
        guard let last = messages.indices.last else { return false }
        let m = messages[last]
        // 空 placeholder = role assistant + content 空 + 无 tool_calls
        // 注意：reasoning 不算"有效回复内容" —— 因为它不在 CodingKeys，发回 server 仍会触发"无 content 无 tool_calls"的协议错误
        let isEmptyPlaceholder = m.role == "assistant"
            && (m.content?.isEmpty ?? true)
            && (m.toolCalls?.isEmpty ?? true)
        if isEmptyPlaceholder {
            messages.remove(at: last)
            return true
        }
        return false
    }

    // MARK: - Execute tool calls

    /// 同轮多工具执行：**全只读才并发**（MainActor 挂起点重叠 = 网络并行，只读工具间无
    /// 写副作用、也无同轮数据依赖 —— 依赖前一结果的调用模型只能下一轮才发得出）；
    /// 含 mutation 则整批按序 —— HITL 确认是单槽位（pendingIntent/pendingContinuation）
    /// 不能并发弹窗，且同轮「先加购后查车」的因果顺序不可乱。
    /// 结果恒按 calls 原顺序回填，tool 帧与 assistant.tool_calls 对齐（wire 协议要求）。
    private func executeToolBatch(_ calls: [ToolCall]) async -> [String] {
        let allReadOnly = calls.allSatisfy {
            AIToolRegistry.spec(forRawName: $0.function.name)?.kind != .mutation
        }
        guard allReadOnly, calls.count > 1 else {
            var out: [String] = []
            for call in calls { out.append(await executeTool(call)) }
            return out
        }
        return await withTaskGroup(of: (Int, String).self) { group in
            for (i, call) in calls.enumerated() {
                group.addTask { @MainActor in (i, await self.executeTool(call)) }
            }
            var results = [String](repeating: "", count: calls.count)
            for await (i, r) in group { results[i] = r }
            return results
        }
    }

    // 按 name 查注册表分发：先过身份守卫，mutation 再走 HITL 确认，最后跑 spec.run。
    // 新增工具只需在对应域的 Tools 文件注册，本方法无需改动。
    private func executeTool(_ call: ToolCall) async -> String {
        guard let spec = AIToolRegistry.spec(forRawName: call.function.name) else {
            return "未知工具: \(call.function.name)"
        }
        // 执行侧身份守卫（第二道，与下发侧同一真相源 allowedIdentities）：
        // 会话跨身份留存，模型可能从历史复调旧身份的工具 —— 拒绝并引导切换身份。
        let identity = authManager.activeIdentity
        guard spec.name.isAllowed(for: identity) else {
            let need = spec.name.allowedIdentities
                .map { AIToolName.identityLabel($0) }.sorted().joined(separator: "或")
            return "工具 \(spec.name.rawValue) 在当前身份（\(AIToolName.identityLabel(identity))）下不可用，"
                + "此操作需要\(need)身份。请直接告知用户：到「我的」页切换身份后再试，不要重试本工具。"
        }
        let args = parseArgs(call.function.arguments)
        do {
            if spec.kind == .mutation {
                // 执行期解析工具（如 place_order）：先解析真实数据（地址/报价）再确认，
                // 确认展示与执行共用同一份解析快照（见 PreparedMutation）。
                if let prepare = spec.prepare {
                    switch try await prepare(args, runScope) {
                    case .abort(let text):
                        return text
                    case .ready(let intent, let execute):
                        guard await awaitConfirmation(intent) else { return "用户取消了操作" }
                        return try await execute()
                    }
                }
                let summary = spec.intentSummary?(args) ?? "AI 想执行 \(spec.name.rawValue)"
                let intent = MutationIntent(toolName: spec.name, summary: summary, payload: stringifyPayload(args))
                guard await awaitConfirmation(intent) else {
                    return "用户取消了操作"
                }
            }
            return try await spec.run(args, runScope)
        } catch {
            return "执行 \(call.function.name) 时出错：\(error.localizedDescription)"
        }
    }

    // MARK: - Call AI API (SSE 流式)
    //
    // 策略：
    //   1. 先 append 一个空占位 assistant message —— SwiftUI ForEach 已 identity by id
    //   2. 逐行读 text/event-stream，解析 data: {...} chunk
    //   3. delta.content 累积写回占位 message.content（每个 chunk 触发一次 UI 更新）
    //   4. delta.tool_calls 按 index 累积到 toolCallBuffer，等 finish_reason=tool_calls 整体转 ToolCall
    //   5. finish_reason=stop 自然结束；tool_calls 把占位转 tool_call 形态返回给 agent loop

    private func streamCallAI(config: AIConfig, apiKey: String) async -> StreamResult {
        // 系统 AI：每次实时取本机 endpoint（端口/就绪态动态，不固化到 config）。
        let base: String
        if config.provider == "system" {
            guard let ep = SystemAIProvider.endpoint else {
                // 按状态说准原因（服务级措辞，不暴露本机实现）
                switch SystemAIProvider.status {
                case .disabled: return .error("系统 AI 服务维护中，请稍后再试，或在配置中改用自定义来源")
                default: return .error("系统 AI 服务暂不可用，请稍候再试")
                }
            }
            base = ep.absoluteString
        } else {
            base = config.baseUrl
        }
        guard let url = URL(string: base + "/chat/completions") else {
            return .error("URL 无效")
        }

        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        // 发送期组装：system 现拼（prompt 迭代即时触达所有会话）+ 历史裁剪/过期折叠（wireHistory）。
        // 工具按当前会话 scope 裁剪（nil = 全量）：页面 scoped 会话只发相关工具，提升命中率。
        let wireMessages = [ChatMessage.system(composedSystemPrompt())] + Self.wireHistory(messages)
        let body = ChatRequest(model: config.model, messages: wireMessages, tools: AIToolRegistry.tools(scope: toolScope))
        guard let data = try? encoder.encode(body) else {
            return .error("请求编码失败")
        }
        req.httpBody = data

        #if DEBUG
        AIDebugFileLog.request(provider: config.provider, model: config.model, stream: true,
                                toolNames: body.tools.map(\.function.name), messages: wireMessages)
        #endif

        // 占位 assistant message —— content 用 nil 而非 ""，避免空字符串污染对话历史
        let placeholderIdx = messages.count
        messages.append(.assistantPlaceholder())

        struct ToolCallBuffer {
            var id: String?
            var type: String?
            var name: String?
            var arguments: String = ""
        }
        var toolBuf: [Int: ToolCallBuffer] = [:]
        var finishReason: String?
        var hasReceivedDelta = false
        var pendingEventType: String?       // 跟踪上一行 `event: xxx`
        var sseErrorMessage: String?         // 检测到 event:error 帧后存放错误文本

        // token 合批：delta 先积累在局部 buffer，≥80ms 才写回 messages（触发 UI 更新 + 滚动）。
        // 首 token 强制立即写（用户尽快看到开始输出）；所有退出路径 force flush，零丢字。
        // 无 trailing timer：中途停顿最多滞留一个批次，下一个 delta 到达即冲掉。
        var contentBuf = ""
        var reasoningBuf = ""
        var lastFlushAt = Date.distantPast
        func flushStreamBuffers(force: Bool = false) {
            guard !contentBuf.isEmpty || !reasoningBuf.isEmpty else { return }
            let now = Date()
            guard force || now.timeIntervalSince(lastFlushAt) >= 0.08 else { return }
            var m = messages[placeholderIdx]
            if !reasoningBuf.isEmpty {
                m.reasoning = (m.reasoning ?? "") + reasoningBuf
                reasoningBuf = ""
            }
            if !contentBuf.isEmpty {
                m.content = (m.content ?? "") + contentBuf
                contentBuf = ""
            }
            messages[placeholderIdx] = m
            lastFlushAt = now
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        do {
            let (stream, response) = try await URLSession.shared.bytes(for: req)

            guard let http = response as? HTTPURLResponse else {
                return .error("响应类型错误")
            }
            if !(200..<300 ~= http.statusCode) {
                return .error("HTTP \(http.statusCode)")
            }

            for try await line in stream.lines {
                try Task.checkCancellation()

                // 空行是 SSE 事件分隔符 —— 重置 pendingEventType
                if line.isEmpty {
                    pendingEventType = nil
                    continue
                }

                // `event: xxx` 行 —— 记录当前事件类型，下一行 data 按此类型解读
                if line.hasPrefix("event: ") {
                    pendingEventType = String(line.dropFirst(7))
                    continue
                }

                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst(6))
                if payload == "[DONE]" { break }

                // event: error 帧 —— LM Studio 模板渲染失败 / Ollama 模型加载失败等都走这里
                if pendingEventType == "error" {
                    if let errData = payload.data(using: .utf8),
                       let err = try? decoder.decode(SSEErrorPayload.self, from: errData) {
                        sseErrorMessage = err.error?.message ?? err.message ?? payload
                    } else {
                        sseErrorMessage = payload
                    }
                    break
                }

                guard let payloadData = payload.data(using: .utf8),
                      let chunk = try? decoder.decode(StreamChunk.self, from: payloadData),
                      let choice = chunk.choices?.first else {
                    continue
                }

                // reasoning delta（DeepSeek/Gemma 等支持的 endpoint）
                if let reasoningDelta = choice.delta.reasoning, !reasoningDelta.isEmpty {
                    let isFirst = !hasReceivedDelta
                    if isFirst {
                        hasReceivedDelta = true
                        isThinking = false   // reasoning chunk 也算首 token，关闭"正在思考"占位
                    }
                    reasoningBuf += reasoningDelta
                    flushStreamBuffers(force: isFirst)
                }

                // 文本 delta
                if let textDelta = choice.delta.content, !textDelta.isEmpty {
                    let isFirst = !hasReceivedDelta
                    if isFirst {
                        hasReceivedDelta = true
                        isThinking = false   // 第一个 token 到达，关闭"正在思考"占位
                    }
                    contentBuf += textDelta
                    flushStreamBuffers(force: isFirst)
                }

                // tool_call delta（按 index 累积）
                if let tcs = choice.delta.toolCalls {
                    if !hasReceivedDelta {
                        hasReceivedDelta = true
                        isThinking = false
                    }
                    for tc in tcs {
                        var buf = toolBuf[tc.index] ?? ToolCallBuffer()
                        if let id = tc.id { buf.id = id }
                        if let t = tc.type { buf.type = t }
                        if let n = tc.function?.name { buf.name = n }
                        if let a = tc.function?.arguments { buf.arguments += a }
                        toolBuf[tc.index] = buf
                    }
                }

                if let fr = choice.finishReason {
                    finishReason = fr
                }
            }
        } catch is CancellationError {
            flushStreamBuffers(force: true)     // 中断保留已生成的部分
            return .interrupted
        } catch let urlError as URLError where urlError.code == .cancelled {
            flushStreamBuffers(force: true)
            return .interrupted
        } catch {
            flushStreamBuffers(force: true)
            return .error(error.localizedDescription)
        }

        // 流结束（[DONE] / error 帧 break / 自然收尾）—— 冲掉节流滞留的最后一批 delta
        flushStreamBuffers(force: true)

        // SSE event: error 帧优先于 finish_reason 处理
        if let err = sseErrorMessage {
            return .error(err)
        }

        // 组装 tool_calls（仅当 finish_reason 明确为 tool_calls）
        if finishReason == "tool_calls", !toolBuf.isEmpty {
            let calls = toolBuf.keys.sorted().compactMap { idx -> ToolCall? in
                guard let buf = toolBuf[idx],
                      let id = buf.id,
                      let name = buf.name,
                      !buf.arguments.isEmpty else { return nil }
                return ToolCall(
                    id: id,
                    type: buf.type ?? "function",
                    function: ToolCallFunction(name: name, arguments: buf.arguments)
                )
            }
            // 占位 message 转 tool_call 形态：content 清空、toolCalls 填充
            var m = messages[placeholderIdx]
            if m.content?.isEmpty ?? true { m.content = nil }
            m.toolCalls = calls
            messages[placeholderIdx] = m
            return .toolCalls(calls)
        }

        return .finished
    }

    private func parseArgs(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    private func stringifyPayload(_ args: [String: Any]) -> [String: String] {
        args.reduce(into: [String: String]()) { result, pair in
            result[pair.key] = String(describing: pair.value)
        }
    }
}
