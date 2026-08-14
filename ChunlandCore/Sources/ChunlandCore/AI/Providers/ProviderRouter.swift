import Foundation

// MARK: - 重试与降级
//
// 这一层解决当前实现里最要命的一个问题：**系统 AI 是唯一来源，它挂了用户就没 AI 用**
//（号池耗尽 → 服务端下发 disabled → 直接不可用，没有任何兜底）。
//
// 降级链：
//
//   首选模型 ──失败──> 按策略：
//                       limited（保守）→ 网络/瞬时错误先原地重试，耗尽再换模型
//                       always（激进）→ 任何错误立刻换下一个
//                     ──换到底──> 抛出最后一个错误
//
// **降级只发生在「第一个事件到达之前」。** 一旦模型开始吐字，内容已经进了 UI，
// 这时再换模型会让用户看到半句话被另一个模型接着写下去。中途失败属于
// 「清除未提交的尾巴 + 原模型重试」，那是循环层的职责，不在这里。

public struct ProviderRouter: Sendable {

    /// 重试间隔（秒）。
    ///
    /// 比通用 agent 工具短得多 —— 那类工具在做长任务，用户不盯着；
    /// 而这里用户正看着对话框等回复，超过十几秒就该换模型而不是继续等。
    public static let retryDelays: [UInt64] = [2, 4, 8]

    private let config: ProviderConfigStore
    private let factory: ProviderFactory
    private let logger = AppLogger(subsystem: AppLogger.subsystem, category: "ai.router")

    public init(config: ProviderConfigStore, factory: ProviderFactory) {
        self.config = config
        self.factory = factory
    }

    /// 一次路由的结果。
    public struct Routed: Sendable {
        public let stream: AsyncThrowingStream<AgentStreamEvent, Error>
        /// 最终用上的模型条目。
        public let entry: ModelEntry
        /// 中途发生过的降级（按顺序），供 UI 告知用户。
        public let fallbacks: [FallbackRecord]
    }

    /// 打开一条流，必要时自动重试与降级。
    public func stream(
        binding: SessionModelBinding?,
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int? = nil
    ) async throws -> Routed {

        let candidates = await resolveCandidates(binding: binding)
        guard !candidates.isEmpty else { throw LLMError.notConfigured }
        await Self.primeSystemAvailability(candidates)

        let strategy = await fallbackStrategy(for: binding)
        var fallbacks: [FallbackRecord] = []
        var lastError: LLMError = .notConfigured

        for (index, entry) in candidates.enumerated() {
            let isLast = index == candidates.count - 1
            // 保守策略下才在当前模型上重试；激进策略直接换下一个。
            let attempts = (strategy == .limited) ? Self.retryDelays.count + 1 : 1

            for attempt in 0..<attempts {
                if attempt > 0 {
                    let delay = Self.retryDelays[attempt - 1]
                    logger.info("重试等待 \(delay)s", metadata: ["model": entry.modelId, "attempt": "\(attempt)"])
                    try await Task.sleep(nanoseconds: delay * 1_000_000_000)
                    try Task.checkCancellation()
                }

                do {
                    let provider = try await factory.make(entry: entry)
                    let raw = try await provider.streamAgent(
                        messages: messages,
                        systemPrompt: systemPrompt,
                        tools: tools,
                        maxTokens: maxTokens ?? entry.maxOutputTokens
                    )
                    // 关键：把第一个事件拉出来。连接失败、鉴权失败、限流
                    // 都在这一步暴露 —— 此时还没有任何内容进 UI，可以安全换模型。
                    let primed = try await Self.prime(raw)
                    if !fallbacks.isEmpty {
                        logger.info("降级后成功", metadata: ["model": entry.modelId, "hops": "\(fallbacks.count)"])
                    }
                    return Routed(stream: primed, entry: entry, fallbacks: fallbacks)

                } catch let error as LLMError {
                    lastError = error
                    if error.isCancellation { throw error }

                    let canRetryHere = strategy == .limited
                        && error.isRetryable
                        && attempt < attempts - 1
                    if canRetryHere {
                        logger.warn("将重试", metadata: ["model": entry.modelId, "reason": error.fallbackReason])
                        continue
                    }
                    logger.warn("放弃该模型", metadata: ["model": entry.modelId, "reason": error.fallbackReason])
                    break   // 换下一个候选

                } catch {
                    lastError = LLMError.fromURLError(error)
                    if lastError.isCancellation { throw lastError }
                    break
                }
            }

            if !isLast {
                let next = candidates[index + 1]
                fallbacks.append(FallbackRecord(
                    fromModel: entry.displayName,
                    toModel: next.displayName,
                    reason: lastError.fallbackReason
                ))
            }
        }

        throw lastError
    }

    // MARK: - 系统 AI 就绪预热

    /// 系统 AI 未就绪时最多等多久。
    ///
    /// 用户正盯着输入框，等待必须短到「像是在加载」而不是「卡住了」。
    /// 等不到就按原路失败 —— 后台那次拉取仍在跑，再点一次通常就好了。
    public static let systemSyncWaitSeconds: Double = 3

    /// 系统 AI 不可用是候选链里唯一**前置条件可修**的失败：模块本就在轮询，
    /// 只是下一拍可能还有一整个周期（默认 60s）。这里先催一次。
    ///
    /// **只在它是唯一候选时才等**：还有下一档可降级时干等，等于让配了兜底来源的用户
    /// 平白多花几秒 —— 那种情况下催拉扔后台，本次请求照常走降级。
    private static func primeSystemAvailability(_ candidates: [ModelEntry]) async {
        guard SystemAIProvider.isIntegrated, !SystemAIProvider.isAvailable else { return }
        guard candidates.contains(where: { $0.instanceId == ProviderInstance.systemInstanceId })
        else { return }

        if candidates.count == 1 {
            await SystemAIProvider.requestSync(waitingUpTo: systemSyncWaitSeconds)
        } else {
            SystemAIProvider.requestSyncDetached()
        }
    }

    // MARK: - 候选解析

    /// 按绑定解析出有序的候选链。
    private func resolveCandidates(binding: SessionModelBinding?) async -> [ModelEntry] {
        switch binding {
        case .entry(let id):
            // 用户显式钉死了模型：**不降级**。他选了什么就用什么，
            // 背着他换模型比失败更糟（回答风格突变且无从解释）。
            return await config.entry(id: id).map { [$0] } ?? []

        case .group(let gid):
            if let g = await config.group(id: gid) {
                let usable = await config.usableEntries(in: g)
                if !usable.isEmpty { return usable }
            }
            return await defaultCandidates()

        case nil:
            return await defaultCandidates()
        }
    }

    private func defaultCandidates() async -> [ModelEntry] {
        guard let g = await config.defaultGroup() else { return [] }
        return await config.usableEntries(in: g)
    }

    private func fallbackStrategy(for binding: SessionModelBinding?) async -> FallbackStrategy {
        if case .group(let gid) = binding, let g = await config.group(id: gid) {
            return g.fallbackStrategy
        }
        return await config.defaultGroup()?.fallbackStrategy ?? .limited
    }

    // MARK: - 预热

    /// 拉取第一个事件，再把它与后续事件一起重新组成流。
    ///
    /// 这是「失败可降级」与「已出内容不可撤回」之间的分界线：
    /// 第一个事件成功 = 连接已建立、鉴权已通过、上游开始工作。
    private static func prime(
        _ upstream: AsyncThrowingStream<AgentStreamEvent, Error>
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        var iterator = upstream.makeAsyncIterator()
        let first = try await iterator.next()

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let first { continuation.yield(first) }
                    while let event = try await iterator.next() {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
