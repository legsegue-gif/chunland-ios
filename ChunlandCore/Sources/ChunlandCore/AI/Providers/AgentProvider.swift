import Foundation

// MARK: - 双协议
//
// 把「调 LLM」切成两个协议，而不是一个：
//
//   LLMProvider    单次调用 —— 会话标题生成、上下文压缩摘要、商家 AI 分类
//   AgentProvider  agent 循环 —— 带工具、多轮、流式
//
// 两者共用同一套 provider 实现与配置源。这正是当前代码分散的根因所在：
// AIClassifyService 因为「不是对话」而自己写了一套 endpoint 解析 + SSE 解析 +
// 错误处理，与 orchestrator 完全重复。切成双协议后，它只是换个协议调同一个实现，
// 顺带白拿重试与降级能力。

/// 单次调用：给一段输入，拿一段输出。无工具、无多轮。
public protocol LLMProvider: Sendable {
    /// 本次调用实际使用的模型标识（日志与降级提示用）。
    var modelId: String { get }

    /// 流式返回文本增量。
    ///
    /// 即使调用方只想要完整结果也走流式：**不押注上游实现了非流式**。
    /// 实测中不少 OpenAI 兼容端点的非流式分支要么没实现、要么行为不一致，
    /// 而流式是它们的主路径。聚合成整段由调用方决定。
    func streamText(
        messages: [LLMTurn],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<String, Error>
}

public extension LLMProvider {
    /// 聚合成完整文本 —— 单次结构化调用（如商家分类）用这个。
    func completeText(
        messages: [LLMTurn],
        systemPrompt: String? = nil,
        maxTokens: Int = 4096,
        temperature: Double? = nil
    ) async throws -> String {
        var out = ""
        let stream = try await streamText(
            messages: messages, systemPrompt: systemPrompt,
            maxTokens: maxTokens, temperature: temperature
        )
        for try await delta in stream { out += delta }
        return out
    }
}

/// 单次调用的一轮消息（比 `AgentMessage` 轻，没有工具与媒体）。
public struct LLMTurn: Sendable, Equatable {
    public enum Role: String, Sendable { case system, user, assistant }
    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }

    public static func user(_ text: String) -> LLMTurn { LLMTurn(role: .user, content: text) }
    public static func assistant(_ text: String) -> LLMTurn { LLMTurn(role: .assistant, content: text) }
}

/// agent 循环：流式 + 工具调用。
public protocol AgentProvider: Sendable {
    var modelId: String { get }

    /// 该模型的默认最大输出 token。
    var defaultMaxTokens: Int { get }

    /// 开一条流。
    ///
    /// 实现只负责「把自家 wire 翻译成 `AgentStreamEvent`」，
    /// 不做重试、不做降级、不碰历史 —— 那些是循环层的职责。
    func streamAgent(
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error>
}

// MARK: - 供给方
//
// 循环层不直接构造 provider —— 它只说「给我当前该用的 provider」，
// 由配置层决定是系统 AI 还是用户自配、是哪个模型、降级到第几个。

public protocol AgentProviderResolving: Sendable {
    /// 解析出当前应使用的 provider 与其模型条目。
    func resolveAgentProvider(entryId: String?) async throws -> ResolvedAgentProvider
}

public struct ResolvedAgentProvider: Sendable {
    public let provider: any AgentProvider
    public let entry: ModelEntry

    public init(provider: any AgentProvider, entry: ModelEntry) {
        self.provider = provider
        self.entry = entry
    }
}
