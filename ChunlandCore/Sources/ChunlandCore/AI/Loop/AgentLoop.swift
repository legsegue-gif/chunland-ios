import Foundation

// MARK: - agent 循环
//
// 一次「用户发送 → 得到最终答复」的完整过程。
//
// 与旧实现最大的差别不是轮次从 8 放到 30，而是**每条退出路径都有可解释的状态**：
// 旧实现触顶只会回一句「查询轮次过多，请换个问题试试」，用户不知道做到哪了、
// 该怎么办；空响应只回「AI 返回了空响应，请重试」，而那多半是上游过载、
// 重试一次就好。

/// 循环对外发出的事件。UI 订阅它渲染，不关心内部机制。
public enum AgentLoopEvent: Sendable {
    case turnStarted(index: Int)
    case textDelta(String)
    case thinkingDelta(String)
    /// 工具开始执行。`title` 是模型自述的「在做什么」。
    case toolStarted(id: String, name: String, title: String?)
    case toolFinished(id: String, name: String, isError: Bool)
    /// 发生了模型降级，应告知用户。
    case fallback(FallbackRecord)
    /// 上下文被压缩了。
    case compacted
    /// 一轮的 token 用量。
    case usage(TokenUsage)
    case finished(AgentLoopEnd)
}

/// 循环为什么结束。**每种都要能向用户解释清楚**。
public enum AgentLoopEnd: Sendable, Equatable {
    /// 正常给出了答复。
    case completed
    /// 连续执行到轮次上限仍未收敛。可续跑。
    case turnLimit(Int)
    /// 上下文压不动了，需要新开会话。
    case contextExhausted
    /// 模型输出被截断（max_tokens）。可续跑。
    case truncated
    /// 模型拒答 —— 确定性的，重试无用。
    case refused
    /// 用户取消。
    case cancelled
    case failed(String)

    /// 是否可以从当前状态继续跑。
    public var isResumable: Bool {
        switch self {
        case .turnLimit, .truncated, .cancelled: return true
        case .completed, .contextExhausted, .refused, .failed: return false
        }
    }
}

public actor AgentLoop {

    /// 轮次上限。
    ///
    /// 按实际业务链路推算而非拍脑袋：最长的是商家「按吃穿住行分类」
    /// （读商品 → 建方案 → 逐分类归类），约 10-15 轮，留一倍余量。
    /// 旧实现的 8 轮在这个场景下必然触顶。
    public static let maxTurns = 30

    /// 循环内压缩的次数上限。压缩是空间管理动作，不占轮次预算，
    /// 但总上限永不重置 —— 否则一个反复压缩的循环能永远跑下去。
    public static let maxCompactions = 3

    /// 历史里保留的图片张数。更早的换成可重取的占位。
    public static let keepImages = 8

    private let router: ProviderRouter
    private let pipeline: AgentToolPipeline
    private let executor: any AgentToolExecuting
    private let detector: ToolLoopDetector
    /// 生成压缩摘要。由装配层注入（需要一个单次调用的 provider）。
    /// 为 nil 时退化成「折叠成一句占位」—— 上下文仍能腾出来，只是丢了细节。
    private let summarize: (@Sendable (String) async throws -> String)?
    private let logger = AppLogger(subsystem: AppLogger.subsystem, category: "ai.loop")

    /// 会话历史（内存态，落库由调用方在事件回调里做）。
    private var history: [AgentMessage] = []
    /// 上一轮 API 返回的真实上下文用量。有它就不用估算。
    private var lastContextTokens = 0
    /// 本次发送是否已经注入过空响应提醒 —— 每次发送只允许一次，物理上不会循环。
    private var didInjectEmptyReminder = false

    public init(router: ProviderRouter,
                pipeline: AgentToolPipeline,
                executor: any AgentToolExecuting,
                detector: ToolLoopDetector,
                summarize: (@Sendable (String) async throws -> String)? = nil) {
        self.router = router
        self.pipeline = pipeline
        self.executor = executor
        self.detector = detector
        self.summarize = summarize
    }

    // MARK: - 历史

    public func setHistory(_ messages: [AgentMessage]) {
        history = messages
    }

    public func currentHistory() -> [AgentMessage] { history }

    public func reset() {
        history.removeAll()
        lastContextTokens = 0
        detector.reset()
    }

    // MARK: - 主循环

    /// 跑一轮完整对话。返回事件流。
    public func run(
        userMessage: AgentMessage,
        binding: SessionModelBinding?,
        systemPrompt: String,
        contextWindow: Int
    ) -> AsyncStream<AgentLoopEvent> {
        AsyncStream { continuation in
            let task = Task {
                await self.execute(
                    userMessage: userMessage,
                    binding: binding,
                    systemPrompt: systemPrompt,
                    contextWindow: contextWindow,
                    emit: { continuation.yield($0) }
                )
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func execute(
        userMessage: AgentMessage,
        binding: SessionModelBinding?,
        systemPrompt: String,
        contextWindow: Int,
        emit: @Sendable (AgentLoopEvent) -> Void
    ) async {
        history.append(userMessage)
        didInjectEmptyReminder = false

        let policy = ContextPolicy(contextWindow: contextWindow)
        let tools = await executor.availableTools()
        var compactions = 0
        var turn = 0

        while turn < Self.maxTurns {
            if Task.isCancelled {
                emit(.finished(.cancelled))
                return
            }

            // 进入前修复配对：历史被裁剪、取消打断、流中断都会制造孤儿，
            // 带着孤儿发请求会被上游 400 拒。修复而不是指望每条路径都不出错。
            let report = AgentHistoryIntegrity.repair(&history)
            if !report.isClean {
                logger.warn("修复了历史配对", metadata: [
                    "orphanUses": "\(report.orphanToolUses.count)",
                    "orphanResults": "\(report.orphanToolResults.count)",
                    "droppedInterrupted": "\(report.trailingInterruptedIndex != nil)",
                ])
            }

            trimOldImages()

            // 上下文治理：先用便宜手段（卸载），不够再用贵的（压缩）
            let used = lastContextTokens > 0 ? lastContextTokens : TokenEstimator.estimate(history)
            switch policy.decide(usedTokens: used) {
            case .ok:
                break
            case .needsCompact:
                guard compactions < Self.maxCompactions else {
                    logger.warn("压缩次数用尽仍near capacity，按耗尽处理")
                    emit(.finished(.contextExhausted))
                    return
                }
                compactions += 1
                // 压缩是空间管理动作，不消耗轮次预算 —— 但总上限不重置
                await compactHistory()
                emit(.compacted)
                continue
            case .exhausted:
                emit(.finished(.contextExhausted))
                return
            }

            turn += 1
            emit(.turnStarted(index: turn))

            // 开流（内含重试与降级）
            let routed: ProviderRouter.Routed
            do {
                routed = try await router.stream(
                    binding: binding,
                    messages: history,
                    systemPrompt: systemPrompt,
                    tools: tools
                )
            } catch let error as LLMError {
                #if DEBUG
                AIDebugFileLog.response(outcome: error.isCancellation ? "cancelled" : "openFailed",
                                        text: nil, detail: error.errorDescription)
                #endif
                if error.isCancellation { emit(.finished(.cancelled)) }
                else { emit(.finished(.failed(error.errorDescription ?? "请求失败"))) }
                return
            } catch {
                #if DEBUG
                AIDebugFileLog.response(outcome: "openFailed", text: nil, detail: error.localizedDescription)
                #endif
                emit(.finished(.failed(error.localizedDescription)))
                return
            }
            routed.fallbacks.forEach { emit(.fallback($0)) }

            // 请求落盘放在开流之后：model 要用**实际选中的**那个（可能已经降级过），
            // 开流前记等于记了一个可能没被用上的模型。
            #if DEBUG
            AIDebugFileLog.request(model: routed.entry.modelId,
                                   toolNames: tools.map(\.name),
                                   messages: history)
            #endif

            // 消费流
            let result: AgentTurnResult
            do {
                result = try await consume(routed.stream, emit: emit)
            } catch let error as LLMError {
                #if DEBUG
                AIDebugFileLog.response(outcome: error.isCancellation ? "cancelled" : "streamFailed",
                                        text: nil, detail: error.errorDescription)
                #endif
                if error.isCancellation { emit(.finished(.cancelled)) }
                else { emit(.finished(.failed(error.errorDescription ?? "请求失败"))) }
                return
            } catch {
                #if DEBUG
                AIDebugFileLog.response(outcome: "streamFailed", text: nil, detail: error.localizedDescription)
                #endif
                emit(.finished(.failed(error.localizedDescription)))
                return
            }

            // 本轮产出（工具调用也是产出的一种形态）
            #if DEBUG
            AIDebugFileLog.response(
                outcome: result.toolEntries.isEmpty
                    ? (result.stopReason.map { "\($0)" } ?? "interrupted")
                    : "toolCalls",
                text: result.text,
                toolNames: result.toolEntries.map(\.name)
            )
            #endif

            lastContextTokens = result.usage.contextTokens
            if result.usage.contextTokens > 0 { emit(.usage(result.usage)) }

            // 空响应：上游过载 / 长上下文的真实失败模式，表现是聊天静默停止。
            // 注入一次提醒重试一轮，每次发送只允许一次。
            if result.isEmpty {
                if !didInjectEmptyReminder, history.last?.isPureToolResult == true {
                    didInjectEmptyReminder = true
                    logger.warn("空响应，注入提醒重试一轮")
                    history.append(.user(AIPrompts.emptyResponseReminder))
                    turn -= 1   // 提醒重试不算一轮任务迭代
                    continue
                }
                emit(.finished(.failed("AI 没有返回内容，可能是服务繁忙，请重试或换个模型。")))
                return
            }

            // 落进历史
            var assistant = AgentMessage(role: .assistant, parts: [])
            if !result.text.isEmpty { assistant.parts.append(.text(result.text)) }
            for entry in result.toolEntries {
                assistant.parts.append(.toolUse(id: entry.id, name: entry.name, input: entry.input))
            }
            assistant.reasoning = result.reasoning
            assistant.isInterrupted = result.stopReason == nil
            history.append(assistant)

            // 没有工具调用 = 这一轮给出了答复
            guard !result.toolEntries.isEmpty else {
                switch result.stopReason {
                case .maxTokens:  emit(.finished(.truncated))
                case .refused:    emit(.finished(.refused))
                case nil:         emit(.finished(.truncated))   // 流中断，可续跑
                default:          emit(.finished(.completed))
                }
                return
            }

            // 执行工具
            let outcomes = await pipeline.executeBatch(result.toolEntries, tools: tools)
            for outcome in outcomes {
                emit(.toolStarted(id: outcome.toolId, name: outcome.toolName, title: outcome.title))
                emit(.toolFinished(id: outcome.toolId, name: outcome.toolName, isError: outcome.isError))
            }
            history.append(.toolResults(outcomes.map(\.part)))

            if outcomes.contains(where: \.cancelled) || Task.isCancelled {
                // 工具结果已经落进历史，配对是完整的，可以安全停在这里
                emit(.finished(.cancelled))
                return
            }
        }

        // 触顶：说清为什么停、可以怎么办
        logger.warn("触到轮次上限", metadata: ["limit": "\(Self.maxTurns)"])
        emit(.finished(.turnLimit(Self.maxTurns)))
    }

    // MARK: - 消费流

    private func consume(
        _ stream: AsyncThrowingStream<AgentStreamEvent, Error>,
        emit: @Sendable (AgentLoopEvent) -> Void
    ) async throws -> AgentTurnResult {
        var text = ""
        var reasoning = ""
        var entries: [AgentTurnResult.ToolEntry] = []
        var usage = TokenUsage()
        var stopReason: AgentStopReason?

        for try await event in stream {
            try Task.checkCancellation()
            switch event {
            case .textDelta(let delta):
                text += delta
                emit(.textDelta(delta))
            case .thinkingDelta(let delta):
                reasoning += delta
                emit(.thinkingDelta(delta))
            case .reasoning(let full):
                reasoning = full
            case .toolCallComplete(let id, let name, let input):
                entries.append(.init(id: id, name: name, input: input, rawInput: input.jsonString()))
            case .usage(let u):
                usage = u
            case .done(let reason):
                stopReason = reason
            case .blockStart, .toolInputDelta:
                break
            }
        }

        return AgentTurnResult(
            text: text,
            toolEntries: entries,
            reasoning: reasoning.isEmpty ? nil : reasoning,
            stopReason: stopReason,
            usage: usage,
            isInterrupted: stopReason == nil
        )
    }

    // MARK: - 上下文治理

    /// 图片老化：只保留最近 N 张，更早的换成文字占位。
    ///
    /// 图片是上下文里最重的东西（一张约 800 token），而对话进行到后面
    /// 早期的图片几乎都不再需要 —— 模型已经把它描述过一遍了。
    private func trimOldImages() {
        var remaining = Self.keepImages
        for messageIndex in history.indices.reversed() {
            for partIndex in history[messageIndex].parts.indices.reversed() {
                guard case .image = history[messageIndex].parts[partIndex] else { continue }
                if remaining > 0 {
                    remaining -= 1
                } else {
                    history[messageIndex].parts[partIndex] =
                        .text("（一张较早发送的图片已从上下文移出，如需重看请让用户再发一次）")
                }
            }
        }
    }

    /// 压缩历史：把中间那段交给模型总结成一段背景摘要。
    ///
    /// 首尾都保留：开头几条通常带着任务的起点（用户到底要什么），
    /// 结尾几条是当前正在做的事 —— 两头都压掉的话，模型会不知道自己在干嘛。
    ///
    /// 摘要生成失败（限流、超时）不能让整个循环卡住 —— 退化成占位标记，
    /// 上下文照样腾出来了，只是丢了细节。
    private func compactHistory() async {
        guard history.count > 6 else { return }
        let head = Array(history.prefix(2))
        let tail = Array(history.suffix(4))
        let middle = Array(history.dropFirst(2).dropLast(4))
        guard !middle.isEmpty else { return }

        var marker: AgentMessage
        if let summarize {
            let transcript = middle.map { message -> String in
                let who = message.role == .user ? "用户" : "助手"
                var line = "\(who)：\(message.plainText)"
                let tools = message.toolUses.map(\.name)
                if !tools.isEmpty { line += "（调用了 \(tools.joined(separator: "、"))）" }
                return line
            }.joined(separator: "\n")

            do {
                let summary = try await summarize(transcript)
                marker = .user("（以下是这段对话较早部分的摘要，作为背景参考）\n\(summary)")
                logger.info("历史已压缩", metadata: ["dropped": "\(middle.count)"])
            } catch {
                logger.warn("压缩失败，退化为占位", metadata: ["error": "\(error)"])
                marker = Self.placeholder(dropped: middle.count)
            }
        } else {
            marker = Self.placeholder(dropped: middle.count)
        }

        history = head + [marker] + tail
        lastContextTokens = 0   // 压缩后旧基线失效，下轮重新估算
    }

    private static func placeholder(dropped: Int) -> AgentMessage {
        .user("（中间 \(dropped) 条较早的对话已折叠以节省上下文。"
            + "如需其中的具体信息，请重新查询而不是凭印象作答。）")
    }
}
