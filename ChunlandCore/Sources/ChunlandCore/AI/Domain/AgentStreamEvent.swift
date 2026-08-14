import Foundation

// MARK: - 流事件（provider 无关）
//
// 各家 endpoint 的 SSE 帧格式差异全部压在 provider 实现里，agent 循环只认这套事件。
// 换 provider = 换一个把自家 wire 翻译成这些事件的适配器，循环本身一行不动。

/// 一个内容块开始了。
public enum AgentBlockStart: Sendable, Equatable {
    case text
    case toolUse(id: String, name: String)
    case thinking
}

/// 停止原因。
public enum AgentStopReason: String, Sendable, Equatable, Codable {
    /// 正常结束本回合。
    case endTurn
    /// 因为要调工具而暂停 —— 循环应继续。
    case toolUse
    /// 输出 token 用尽，回复被截断。
    case maxTokens
    /// 模型主动拒答。
    ///
    /// **必须与 endTurn 分开**：拒答是确定性的，重试同一请求必然再被拒，
    /// 只会白烧 token。它不能进重试/降级路径，要直接告诉用户换个说法或换模型。
    case refused
}

/// 一次请求的 token 消耗。
public struct TokenUsage: Sendable, Equatable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cachedTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cachedTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedTokens = cachedTokens
    }

    /// 上下文占用量 —— 上下文治理的判断依据。
    /// 有 API 返回值时以它为准，没有才回退到本地估算。
    public var contextTokens: Int { inputTokens + cachedTokens }

    public static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(inputTokens: a.inputTokens + b.inputTokens,
                   outputTokens: a.outputTokens + b.outputTokens,
                   cachedTokens: a.cachedTokens + b.cachedTokens)
    }
}

/// 流式事件。
public enum AgentStreamEvent: Sendable, Equatable {
    /// 新内容块开始。
    case blockStart(AgentBlockStart)

    /// 文本增量。
    case textDelta(String)

    /// 工具参数的增量累积值（完整的 JSON 片段，不是 delta 本身）。
    /// 给 UI 做「正在输入参数」的实时预览用；
    /// 同时会被留存，供 ToolArgsRepair 在参数截断时尝试补全。
    case toolInputDelta(name: String, accumulated: String)

    /// 工具调用完成，参数已解析。
    case toolCallComplete(id: String, name: String, input: AgentToolInput)

    /// 思考内容增量（实时展示用，不回发）。
    case thinkingDelta(String)

    /// 完整的思考内容（多轮对话需要原样回发时带上）。
    case reasoning(String)

    /// token 用量。
    case usage(TokenUsage)

    /// 流结束。
    case done(AgentStopReason)
}

// MARK: - 一次流式请求的汇总结果
//
// 循环需要的是「这一轮模型说了什么、要调哪些工具、为什么停」，
// 而不是一串事件。provider 负责产事件，这个结构由循环侧聚合而成。

public struct AgentTurnResult: Sendable, Equatable {

    /// 一次工具调用的完整信息。
    public struct ToolEntry: Sendable, Equatable {
        public let id: String
        public let name: String
        public var input: AgentToolInput
        /// 参数流的原始累积文本 —— 参数解析失败时，ToolArgsRepair 拿它试补全。
        public let rawInput: String

        public init(id: String, name: String, input: AgentToolInput, rawInput: String) {
            self.id = id
            self.name = name
            self.input = input
            self.rawInput = rawInput
        }
    }

    public var text: String
    public var toolEntries: [ToolEntry]
    public var reasoning: String?
    public var stopReason: AgentStopReason?
    public var usage: TokenUsage
    /// 流在收到终止事件前就断了。
    public var isInterrupted: Bool

    public init(text: String = "",
                toolEntries: [ToolEntry] = [],
                reasoning: String? = nil,
                stopReason: AgentStopReason? = nil,
                usage: TokenUsage = TokenUsage(),
                isInterrupted: Bool = false) {
        self.text = text
        self.toolEntries = toolEntries
        self.reasoning = reasoning
        self.stopReason = stopReason
        self.usage = usage
        self.isInterrupted = isInterrupted
    }

    /// 这一轮什么都没产出。
    ///
    /// 判定要排除三种「看起来空但其实不是异常」的情况：
    /// - 有思考内容 → 模型确实工作了
    /// - 流被中断 → 走中断路径，不是空响应
    /// - 输出截断 / 拒答 → 有明确原因，不该当成空响应去重试
    ///
    /// 上游 HTTP 200 却什么都不返回是真实存在的失败模式（限流、过载、长上下文），
    /// 必须能识别出来才能触发提醒重试。
    public var isEmpty: Bool {
        text.isEmpty
            && toolEntries.isEmpty
            && (reasoning?.isEmpty ?? true)
            && !isInterrupted
            && stopReason != .maxTokens
            && stopReason != .refused
    }
}
