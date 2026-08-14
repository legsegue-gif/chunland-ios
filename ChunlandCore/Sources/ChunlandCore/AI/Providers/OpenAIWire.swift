import Foundation

// MARK: - domain ↔ OpenAI wire 映射
//
// 这一层是 domain 与传输格式之间**唯一**的接触面。
// domain 只有 user / assistant 两种角色，工具结果是 user 消息里的一个片段；
// OpenAI 协议里工具结果是独立的 `role: "tool"` 帧 —— 转换在这里发生。
//
// 顺序约束：`role: "tool"` 帧的顺序必须与前一条 assistant 的 `tool_calls` 一致。
// 并发执行工具时按索引缝合结果就是为了保证这一点。

enum OpenAIWire {

    // MARK: - 请求体

    struct Request: Encodable {
        let model: String
        let messages: [Message]
        let tools: [AgentJSONValue]?
        let toolChoice: String?
        let maxTokens: Int?
        let temperature: Double?
        let stream: Bool

        enum CodingKeys: String, CodingKey {
            case model, messages, tools, stream, temperature
            case toolChoice = "tool_choice"
            case maxTokens = "max_tokens"
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(model, forKey: .model)
            try c.encode(messages, forKey: .messages)
            try c.encodeIfPresent(tools, forKey: .tools)
            try c.encodeIfPresent(toolChoice, forKey: .toolChoice)
            try c.encodeIfPresent(maxTokens, forKey: .maxTokens)
            try c.encodeIfPresent(temperature, forKey: .temperature)
            // stream 必须显式落 wire —— 用默认值省略会让部分端点退化成非流式，
            // 表现是「一直转圈然后整段吐出来」。
            try c.encode(stream, forKey: .stream)
        }
    }

    /// wire 层的一条消息。`role` 在这里有四种（多了 system 与 tool）。
    struct Message: Encodable {
        let role: String
        /// 纯文本，或多模态 parts 数组。二选一。
        var content: Content?
        var toolCalls: [ToolCall]?
        var toolCallId: String?

        enum CodingKeys: String, CodingKey {
            case role, content
            case toolCalls = "tool_calls"
            case toolCallId = "tool_call_id"
        }

        enum Content: Encodable {
            case text(String)
            case parts([Part])

            func encode(to encoder: Encoder) throws {
                var c = encoder.singleValueContainer()
                switch self {
                case .text(let s): try c.encode(s)
                case .parts(let p): try c.encode(p)
                }
            }
        }

        enum Part: Encodable {
            case text(String)
            case imageURL(String)

            enum Keys: String, CodingKey {
                case type, text
                case imageUrl = "image_url"
            }
            enum URLKeys: String, CodingKey { case url }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: Keys.self)
                switch self {
                case .text(let s):
                    try c.encode("text", forKey: .type)
                    try c.encode(s, forKey: .text)
                case .imageURL(let url):
                    try c.encode("image_url", forKey: .type)
                    var u = c.nestedContainer(keyedBy: URLKeys.self, forKey: .imageUrl)
                    try u.encode(url, forKey: .url)
                }
            }
        }

        struct ToolCall: Encodable {
            let id: String
            let type: String
            let function: Function

            struct Function: Encodable {
                let name: String
                let arguments: String
            }
        }
    }

    // MARK: - 编码：domain → wire

    /// 把 domain 历史编成 wire 消息数组。
    ///
    /// `loadImage` 由调用方提供 —— 图片字节**只在编码这一刻**读进内存，
    /// 编完即弃，绝不驻留在 domain 或存储里。
    /// 模型不支持视觉时传 nil，图片会被降级成一行文字说明。
    static func encode(
        messages: [AgentMessage],
        systemPrompt: String?,
        loadImage: ((MediaRef) -> Data?)?
    ) -> [Message] {
        var out: [Message] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            out.append(Message(role: "system", content: .text(systemPrompt)))
        }

        for msg in messages {
            switch msg.role {
            case .assistant:
                out.append(contentsOf: encodeAssistant(msg))
            case .user:
                out.append(contentsOf: encodeUser(msg, loadImage: loadImage))
            }
        }
        return out
    }

    private static func encodeAssistant(_ msg: AgentMessage) -> [Message] {
        var text = ""
        var calls: [Message.ToolCall] = []
        for part in msg.parts {
            switch part {
            case .text(let t):
                text += text.isEmpty ? t : "\n" + t
            case .toolUse(let id, let name, let input):
                calls.append(.init(id: id, type: "function",
                                   function: .init(name: name, arguments: input.jsonString())))
            default:
                break
            }
        }
        // 既无文本也无工具调用的 assistant 帧会被部分端点判为非法，直接丢掉。
        guard !text.isEmpty || !calls.isEmpty else { return [] }
        return [Message(role: "assistant",
                        content: text.isEmpty ? nil : .text(text),
                        toolCalls: calls.isEmpty ? nil : calls)]
    }

    private static func encodeUser(_ msg: AgentMessage, loadImage: ((MediaRef) -> Data?)?) -> [Message] {
        var out: [Message] = []
        var parts: [Message.Part] = []

        for part in msg.parts {
            switch part {
            case .text(let t):
                parts.append(.text(t))

            case .image(let ref):
                if let loadImage, let data = loadImage(ref) {
                    parts.append(.imageURL("data:\(ref.mime);base64,\(data.base64EncodedString())"))
                } else {
                    // 模型不支持视觉、或文件已丢失：给一行说明而不是静默丢弃，
                    // 否则模型会认为用户什么都没发。
                    parts.append(.text("（此处有一张图片，当前模型无法查看）"))
                }

            case .toolResult(let id, _, let text, _, let media, _):
                // 工具结果必须**单独成帧**，且要排在它之前累积的 parts 之后。
                if !parts.isEmpty {
                    out.append(Message(role: "user", content: .parts(parts)))
                    parts = []
                }
                var body = text
                // 工具产出的图片：OpenAI 协议的 tool 帧不支持多模态内容，
                // 只能补一句说明，真正的图片留给下一条 user 帧携带。
                if media != nil { body += "\n（该结果附带一张图片）" }
                out.append(Message(role: "tool", content: .text(body), toolCallId: id))

            case .toolUse:
                break   // user 消息里不应出现工具调用
            }
        }

        if !parts.isEmpty {
            // 纯文本时编成字符串而不是数组 —— 兼容性更好，
            // 有的端点对 content 数组的支持只覆盖了带图场景。
            if parts.count == 1, case .text(let only) = parts[0] {
                out.append(Message(role: "user", content: .text(only)))
            } else {
                out.append(Message(role: "user", content: .parts(parts)))
            }
        }
        return out
    }

    /// 单次调用的轻量编码。
    static func encode(turns: [LLMTurn], systemPrompt: String?) -> [Message] {
        var out: [Message] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            out.append(Message(role: "system", content: .text(systemPrompt)))
        }
        out.append(contentsOf: turns.map { Message(role: $0.role.rawValue, content: .text($0.content)) })
        return out
    }

    // MARK: - 解码：SSE chunk

    struct Chunk: Decodable {
        let choices: [Choice]?
        let usage: Usage?

        struct Choice: Decodable {
            let delta: Delta?
            let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case delta
                case finishReason = "finish_reason"
            }
        }

        struct Delta: Decodable {
            let content: String?
            let toolCalls: [ToolCallDelta]?
            /// 思考内容。两种字段名都见过，取先有的那个。
            let reasoning: String?

            enum CodingKeys: String, CodingKey {
                case content
                case toolCalls = "tool_calls"
                case reasoningContent = "reasoning_content"
                case reasoning
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                content = try? c.decodeIfPresent(String.self, forKey: .content)
                toolCalls = try? c.decodeIfPresent([ToolCallDelta].self, forKey: .toolCalls)
                let primary = try? c.decodeIfPresent(String.self, forKey: .reasoningContent)
                let fallback = try? c.decodeIfPresent(String.self, forKey: .reasoning)
                reasoning = primary ?? fallback
            }
        }

        struct ToolCallDelta: Decodable {
            let index: Int
            let id: String?
            let function: FunctionDelta?

            struct FunctionDelta: Decodable {
                let name: String?
                let arguments: String?
            }
        }

        struct Usage: Decodable {
            let promptTokens: Int?
            let completionTokens: Int?
            let cachedTokens: Int?

            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
                case promptTokensDetails = "prompt_tokens_details"
            }
            enum DetailKeys: String, CodingKey {
                case cachedTokens = "cached_tokens"
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                promptTokens = try? c.decodeIfPresent(Int.self, forKey: .promptTokens)
                completionTokens = try? c.decodeIfPresent(Int.self, forKey: .completionTokens)
                let detail = try? c.nestedContainer(keyedBy: DetailKeys.self, forKey: .promptTokensDetails)
                cachedTokens = try? detail?.decodeIfPresent(Int.self, forKey: .cachedTokens)
            }
        }
    }

    /// SSE 里内嵌的错误帧（HTTP 200 但 body 是错误）。
    struct ErrorPayload: Decodable {
        let error: Detail?
        let message: String?

        struct Detail: Decodable {
            let message: String?
            let type: String?
        }

        var text: String {
            error?.message ?? message ?? "未知错误"
        }
    }

    /// `finish_reason` → 停止原因。
    static func stopReason(from raw: String?) -> AgentStopReason? {
        switch raw {
        case "stop": return .endTurn
        case "tool_calls", "function_call": return .toolUse
        case "length", "max_tokens": return .maxTokens
        case "content_filter": return .refused
        case nil: return nil
        default: return .endTurn
        }
    }
}

// MARK: - 工具调用分片累积
//
// 两种上游实现都要吃：
//   标准 OpenAI —— arguments 按字符切片，按 index 累积
//   部分兼容端 —— 一次性给完整的 tool_calls
// 同一套 buffer 逻辑对两者都成立。

struct ToolCallAssembler {

    private struct Slot {
        var id: String = ""
        var name: String = ""
        var arguments: String = ""
    }

    private var slots: [Int: Slot] = [:]

    mutating func accept(_ deltas: [OpenAIWire.Chunk.ToolCallDelta]) {
        for d in deltas {
            var slot = slots[d.index] ?? Slot()
            if let id = d.id, !id.isEmpty { slot.id = id }
            if let name = d.function?.name, !name.isEmpty { slot.name = name }
            if let args = d.function?.arguments { slot.arguments += args }
            slots[d.index] = slot
        }
    }

    /// 某个槽位当前累积的原始参数文本（供实时预览与截断修复）。
    func rawArguments(at index: Int) -> String? { slots[index]?.arguments }

    var isEmpty: Bool { slots.isEmpty }

    /// 按 index 升序产出 —— 顺序即 wire 上的顺序，工具结果必须按同序回填。
    func finish() -> [AgentTurnResult.ToolEntry] {
        slots.sorted { $0.key < $1.key }.compactMap { _, slot in
            guard !slot.name.isEmpty else { return nil }
            // id 缺失时补一个：某些端点在单工具调用时省略 id，
            // 但我们的配对约束要求它必须存在。
            let id = slot.id.isEmpty ? "call_\(UUID().uuidString.prefix(8))" : slot.id
            return AgentTurnResult.ToolEntry(
                id: id,
                name: slot.name,
                input: AgentToolInput.parse(slot.arguments),
                rawInput: slot.arguments
            )
        }
    }
}
