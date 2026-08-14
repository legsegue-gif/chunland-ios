import Foundation
import Observation

// MARK: - 一条会话
//
// 连接 `AgentLoop`（内核）与视图的桥。视图只读它的状态、只调它的方法，
// 不知道循环、provider、存储的存在。
//
// **每个 contextKey 一个实例**（见 AISessionRegistry）—— 这是对旧实现
// 「一个全局 orchestrator + startScoped/endScoped 切进切出」的替换。
// 旧模型需要 `started` 标志防重入、需要记住挂起的 tab 会话 id、
// 关闭时还要恢复回去；多实例把这些全部消掉了：各自独立，互不干扰。

@MainActor
@Observable
public final class AIChatSession {

    // MARK: - 对外状态

    public private(set) var messages: [ChatDisplayMessage] = []
    /// 正在生成（输入栏禁用、显示停止按钮）。
    public private(set) var isResponding = false
    /// 待用户确认的一批变更（HITL）。非 nil 时 UI 弹确认框。
    public private(set) var pendingConfirmation: [AgentMutationIntent]?
    /// 当前会话在库里的 id。
    public private(set) var sessionId: String?
    /// 页面上下文（决定工具子集、作用域、欢迎语）。
    public let context: AIContext

    /// 欢迎语。**是 View 层装饰，绝不作为 assistant 消息进历史** ——
    /// 塞进历史会被模型当成「自己说过的话」照抄，导致复读。
    public var welcomeText: String {
        context.welcome ?? "你好！有什么可以帮你？"
    }

    // MARK: - 依赖

    private let loop: AgentLoop
    private let sessions: SessionRepo
    private let messages_: MessageRepo
    private let config: ProviderConfigStore
    private let ownerUserId: () -> String?
    private let logger = AppLogger(subsystem: AppLogger.subsystem, category: "ai.session")

    private var runTask: Task<Void, Never>?
    private var confirmContinuation: CheckedContinuation<Bool, Never>?

    public init(context: AIContext,
                loop: AgentLoop,
                sessions: SessionRepo,
                messages: MessageRepo,
                config: ProviderConfigStore,
                ownerUserId: @escaping () -> String?) {
        self.context = context
        self.loop = loop
        self.sessions = sessions
        self.messages_ = messages
        self.config = config
        self.ownerUserId = ownerUserId
    }

    // MARK: - 生命周期

    /// 打开会话：命中同 contextKey 的近期会话就续聊，否则新建。
    ///
    /// 默认续聊窗口 24h —— 「问一半收起再打开」上下文不丢，隔天算新话题。
    /// 传 nil = 不限时间（助手 tab 的主对话用它：那是「你正在进行的对话」，
    /// 每次冷启动都新建会在历史里堆一串没说过话的空会话）。
    public func open(resumeWithin seconds: TimeInterval? = 24 * 3600) async {
        guard sessionId == nil else { return }
        let owner = ownerUserId()

        do {
            if let key = context.contextKey,
               let existing = try await sessions.recent(owner: owner, contextKey: key, within: seconds) {
                sessionId = existing.id
                let history = try await messages_.load(sessionId: existing.id)
                await loop.setHistory(history)
                messages = history.compactMap(Self.display(from:))
                logger.info("续聊", metadata: ["key": key, "messages": "\(history.count)"])
                return
            }

            let record = try await sessions.create(
                owner: owner,
                title: context.title,
                contextKey: context.contextKey
            )
            sessionId = record.id
        } catch {
            logger.error("打开会话失败", metadata: ["error": "\(error)"])
        }
    }

    /// 装载一条指定的历史会话（抽屉里点开某条时用）。
    ///
    /// 与 `open()` 的区别：那个是「按 contextKey 找或建」，这个是「就要这一条」。
    /// 装载前先把当前会话存好 —— 用户从 A 切到 B 再切回 A，A 的内容不能丢。
    public func load(sessionId targetId: String) async {
        guard targetId != sessionId else { return }
        stop()
        await persist()

        do {
            let history = try await messages_.load(sessionId: targetId)
            sessionId = targetId
            await loop.setHistory(history)
            messages = history.compactMap(Self.display(from:))
            logger.info("装载历史会话", metadata: ["messages": "\(history.count)"])
        } catch {
            logger.error("装载历史会话失败", metadata: ["error": "\(error)"])
        }
    }

    /// 关闭：没聊过的空会话直接删掉，不让抽屉堆一次性死会话。
    public func close() async {
        stop()
        guard let id = sessionId else { return }
        if messages.isEmpty {
            try? await sessions.delete(id: id)
            logger.info("删除空会话")
        }
    }

    /// 「新对话」= 归档语义：旧会话摘掉续聊键留在抽屉里当历史，
    /// 新会话独占这个 key。**不删旧的** —— 用户可能还想翻回去看。
    public func restart() async {
        stop()
        if let id = sessionId {
            if messages.isEmpty {
                try? await sessions.delete(id: id)
            } else {
                try? await sessions.detachContextKey(id: id)
            }
        }
        sessionId = nil
        messages.removeAll()
        await loop.reset()
        await open()
    }

    // MARK: - 发送

    public func send(_ text: String, media: [MediaRef] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !media.isEmpty else { return }
        guard !isResponding else { return }

        let userDisplay = ChatDisplayMessage(role: .user, media: media)
        userDisplay.appendText(trimmed)
        messages.append(userDisplay)

        let assistantDisplay = ChatDisplayMessage(role: .assistant, isStreaming: true)
        messages.append(assistantDisplay)

        isResponding = true
        runTask = Task { [weak self] in
            await self?.run(text: trimmed, media: media, into: assistantDisplay)
        }
    }

    /// 停止生成。
    ///
    /// 已经产出的内容保留 —— 用户点停止是「够了」，不是「撤销」。
    public func stop() {
        runTask?.cancel()
        runTask = nil
        // 卡在确认框里时点停止：当作取消处理，否则循环会一直等下去
        resumeConfirmation(false)
    }

    private func run(text: String, media: [MediaRef], into display: ChatDisplayMessage) async {
        defer {
            display.isStreaming = false
            display.closeDanglingTools()
            isResponding = false
            runTask = nil
        }

        guard let sessionId else {
            display.error = "会话未就绪，请重试。"
            return
        }

        let binding = try? await config.binding(sessionId: sessionId)
        let entry = await config.resolveEntry(binding: binding)
        guard let entry else {
            display.error = "尚未配置可用的 AI 模型，请到「AI 配置」选择。"
            return
        }

        // system prompt 发送期现拼：prompt 迭代要能即时触达存量会话，
        // 而且工具集是当前身份的函数 —— 冻进历史的那份描述的是当时的身份。
        let profile = try? await ProductService.shared.profileFragment()
        let systemPrompt = AIPrompts.system(
            pageContext: context.seedNote,
            userProfile: profile
        )

        var userMessage = AgentMessage(role: .user, parts: [])
        if !text.isEmpty { userMessage.parts.append(.text(text)) }
        media.forEach { userMessage.parts.append(.image($0)) }

        let stream = await loop.run(
            userMessage: userMessage,
            binding: binding,
            systemPrompt: systemPrompt,
            contextWindow: entry.contextWindow
        )

        for await event in stream {
            apply(event, to: display)
        }

        await persist()
    }

    // MARK: - 事件 → UI

    private func apply(_ event: AgentLoopEvent, to display: ChatDisplayMessage) {
        switch event {
        case .textDelta(let delta):
            display.appendText(delta)

        case .thinkingDelta(let delta):
            display.appendText(delta, thinking: true)

        case .toolStarted(let id, let name, let title):
            display.addTool(id: id, name: name, title: title)

        case .toolFinished(let id, _, let isError):
            display.finishTool(id: id, isError: isError, preview: nil)

        case .fallback(let record):
            // 降级必须让用户看见 —— 否则「今天回答风格怎么变了」无从解释
            appendSystemNote(record.userText)

        case .compacted:
            appendSystemNote("较早的对话已折叠以节省上下文。")

        case .finished(let end):
            applyEnd(end, to: display)

        case .turnStarted, .usage:
            break
        }
    }

    private func applyEnd(_ end: AgentLoopEnd, to display: ChatDisplayMessage) {
        display.isResumable = end.isResumable
        switch end {
        case .completed:
            break
        case .turnLimit(let limit):
            display.error = AIPrompts.turnLimitReached(limit)
        case .contextExhausted:
            display.error = "这轮对话已经很长了，新开一个对话可以继续。"
        case .truncated:
            display.error = "回复被截断了，可以让我接着说。"
        case .refused:
            display.error = "这个请求我没法回答，换个说法试试，或者到配置里换个模型。"
        case .cancelled:
            // 用户主动停的，不算错误，不显示红字
            break
        case .failed(let message):
            display.error = message
        }
    }

    private func appendSystemNote(_ text: String) {
        let note = ChatDisplayMessage(role: .system)
        note.appendText(text)
        // 插在正在生成的助手消息之前，时间顺序才对
        if let last = messages.indices.last, messages[last].isStreaming {
            messages.insert(note, at: last)
        } else {
            messages.append(note)
        }
    }

    // MARK: - 落库

    private func persist() async {
        guard let sessionId else { return }
        do {
            let history = await loop.currentHistory()
            // 只写还没落库的部分 —— 已有 dbId 的说明写过了
            let pending = history.filter { $0.dbId == nil }
            guard !pending.isEmpty else { return }
            let stored = try await messages_.append(sessionId: sessionId, messages: pending)

            // 把 dbId 回填进循环的历史，避免下次重复写
            var updated = history
            var storedIterator = stored.makeIterator()
            for index in updated.indices where updated[index].dbId == nil {
                updated[index].dbId = storedIterator.next()?.dbId
            }
            await loop.setHistory(updated)

            // 首条用户消息发出后用它派生标题
            if let first = messages.first(where: { $0.role == .user }),
               context.contextKey == nil || context.title == SessionRepo.untitled {
                let title = String(first.plainText.prefix(20))
                if !title.isEmpty {
                    try? await sessions.rename(id: sessionId, title: title)
                }
            }
        } catch {
            logger.error("落库失败", metadata: ["error": "\(error)"])
        }
    }

    // MARK: - 展示模型转换

    /// 历史消息 → 展示模型。
    ///
    /// 工具调用与结果在 domain 里是两条消息，在 UI 上要合成一个块 ——
    /// 所以先建块（assistant 的 toolUse），再由后续的 toolResult 补状态。
    nonisolated static func display(from message: AgentMessage) -> ChatDisplayMessage? {
        MainActor.assumeIsolated {
            let role: ChatDisplayMessage.Role = message.role == .user ? .user : .assistant
            let display = ChatDisplayMessage(role: role)

            for part in message.parts {
                switch part {
                case .text(let text):
                    // 空响应提醒是内部注入的，不给用户看
                    guard !text.hasPrefix("<系统提醒>") else { continue }
                    display.appendText(text)
                case .toolUse(let id, let name, let input):
                    display.addTool(id: id, name: name,
                                    title: input.string(AgentToolDefinition.toolTitleKey))
                case .toolResult:
                    // 结果由 mergeToolResults 补到对应的块上
                    continue
                case .image(let ref):
                    display.media.append(ref)
                }
            }
            if let reasoning = message.reasoning, !reasoning.isEmpty {
                display.appendText(reasoning, thinking: true)
            }
            return display.isEmpty ? nil : display
        }
    }
}

// MARK: - HITL 确认

extension AIChatSession: MutationConfirming {

    /// 一次确认一批变更。
    ///
    /// 挂起循环直到用户点了按钮 —— 单槽位（同一时刻只有一个确认框），
    /// 这也是为什么变更类工具必须按序执行。
    public func confirm(_ batch: [AgentMutationIntent]) async -> Bool {
        guard !batch.isEmpty else { return true }
        return await withCheckedContinuation { continuation in
            pendingConfirmation = batch
            confirmContinuation = continuation
        }
    }

    /// UI 点了确认 / 取消。
    public func resolveConfirmation(approved: Bool) {
        resumeConfirmation(approved)
    }

    private func resumeConfirmation(_ approved: Bool) {
        guard let continuation = confirmContinuation else { return }
        confirmContinuation = nil
        pendingConfirmation = nil
        continuation.resume(returning: approved)
    }
}
