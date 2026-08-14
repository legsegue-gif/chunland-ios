import Foundation

// MARK: - OpenAI 兼容 provider
//
// 同时实现两个协议：单次调用与 agent 循环共用同一份传输实现。
// 这正是要消灭的重复所在 —— 旧代码里 orchestrator 与 AIClassifyService
// 各写了一套 SSE 解析、各有一套错误处理、各读一遍配置。
//
// 职责边界：只负责「把请求发出去、把 SSE 翻译成事件」。
// 不重试、不降级、不碰历史 —— 那些在上层。

public struct OpenAICompatibleProvider: AgentProvider, LLMProvider {

    public let modelId: String
    public let defaultMaxTokens: Int

    private let baseURL: String
    private let apiKey: String
    private let supportsVision: Bool
    /// 图片字节读取器。只在编码那一刻调用，读完即弃。
    private let loadImage: (@Sendable (MediaRef) -> Data?)?

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        // 流式请求的「无数据超时」要放宽：模型思考期间可能几十秒不吐字节。
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    public init(modelId: String,
                baseURL: String,
                apiKey: String,
                maxTokens: Int = 4_096,
                supportsVision: Bool = false,
                loadImage: (@Sendable (MediaRef) -> Data?)? = nil) {
        self.modelId = modelId
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.defaultMaxTokens = maxTokens
        self.supportsVision = supportsVision
        self.loadImage = loadImage
    }

    // MARK: - AgentProvider

    public func streamAgent(
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        // 分步构造：整体塞进一个初始化器会让类型检查器在
        // 「可选数组 + 三元 + map 闭包」的组合上爆炸（编译器直接放弃出诊断）。
        let imageLoader: (@Sendable (MediaRef) -> Data?)? = supportsVision ? loadImage : nil
        let wireMessages = OpenAIWire.encode(
            messages: messages,
            systemPrompt: systemPrompt,
            loadImage: imageLoader
        )
        var toolSchemas: [AgentJSONValue]?
        var toolChoice: String?
        if !tools.isEmpty {
            toolSchemas = tools.map { $0.openAISchema() }
            toolChoice = "auto"
        }

        let body = OpenAIWire.Request(
            model: modelId,
            messages: wireMessages,
            tools: toolSchemas,
            toolChoice: toolChoice,
            maxTokens: maxTokens,
            temperature: nil,
            stream: true
        )
        return try await openStream(body: body)
    }

    // MARK: - LLMProvider

    public func streamText(
        messages: [LLMTurn],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<String, Error> {
        let body = OpenAIWire.Request(
            model: modelId,
            messages: OpenAIWire.encode(turns: messages, systemPrompt: systemPrompt),
            tools: nil,
            toolChoice: nil,
            maxTokens: maxTokens,
            temperature: temperature,
            stream: true
        )
        let events = try await openStream(body: body)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in events {
                        if case .textDelta(let t) = event { continuation.yield(t) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 传输

    private func makeRequest(body: OpenAIWire.Request) throws -> URLRequest {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: trimmed + "/chat/completions") else {
            throw LLMError.notConfigured
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            req.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw LLMError.decodingError(message: "请求编码失败：\(error.localizedDescription)")
        }
        return req
    }

    private func openStream(body: OpenAIWire.Request) async throws
        -> AsyncThrowingStream<AgentStreamEvent, Error>
    {
        let request = try makeRequest(body: body)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await Self.session.bytes(for: request)

                    if let http = response as? HTTPURLResponse,
                       !(200..<300).contains(http.statusCode) {
                        // 错误 body 也是流式的，先读出来再归类 —— 不读的话
                        // 用户只能看到「HTTP 400」，看不到上游给的具体原因。
                        var detail = ""
                        for try await line in bytes.lines {
                            detail += line
                            if detail.count > 800 { break }
                        }
                        throw LLMError.fromHTTPStatus(http.statusCode, body: detail)
                    }

                    var assembler = ToolCallAssembler()
                    var sawContent = false
                    var finishReason: String?
                    var lastToolName = ""

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else {
                            // SSE 的 event: error 帧后面才是 data，这里只跳过非 data 行
                            continue
                        }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty { continue }
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8) else { continue }

                        // HTTP 200 里内嵌的错误帧 —— 上游过载时的常见形态。
                        // 不识别的话流会静默结束，表现为「AI 什么都没说」。
                        if let err = try? JSONDecoder().decode(OpenAIWire.ErrorPayload.self, from: data),
                           err.error != nil || err.message != nil {
                            throw LLMError.transientError(message: err.text)
                        }

                        guard let chunk = try? JSONDecoder().decode(OpenAIWire.Chunk.self, from: data)
                        else { continue }

                        if let usage = chunk.usage {
                            continuation.yield(.usage(TokenUsage(
                                inputTokens: usage.promptTokens ?? 0,
                                outputTokens: usage.completionTokens ?? 0,
                                cachedTokens: usage.cachedTokens ?? 0
                            )))
                        }

                        guard let choice = chunk.choices?.first else { continue }

                        if let reason = choice.finishReason { finishReason = reason }

                        if let delta = choice.delta {
                            if let text = delta.content, !text.isEmpty {
                                if !sawContent {
                                    sawContent = true
                                    continuation.yield(.blockStart(.text))
                                }
                                continuation.yield(.textDelta(text))
                            }
                            if let think = delta.reasoning, !think.isEmpty {
                                continuation.yield(.thinkingDelta(think))
                            }
                            if let calls = delta.toolCalls, !calls.isEmpty {
                                for c in calls where c.function?.name?.isEmpty == false {
                                    lastToolName = c.function?.name ?? lastToolName
                                    continuation.yield(.blockStart(
                                        .toolUse(id: c.id ?? "", name: lastToolName)
                                    ))
                                }
                                assembler.accept(calls)
                                // 实时预览：把当前累积的参数文本推给 UI
                                if let idx = calls.first?.index,
                                   let raw = assembler.rawArguments(at: idx) {
                                    continuation.yield(.toolInputDelta(name: lastToolName, accumulated: raw))
                                }
                            }
                        }
                    }

                    for entry in assembler.finish() {
                        continuation.yield(.toolCallComplete(
                            id: entry.id, name: entry.name, input: entry.input
                        ))
                    }

                    // 有工具调用时，部分端点不给 finish_reason，按实际内容判定。
                    let stop = OpenAIWire.stopReason(from: finishReason)
                        ?? (assembler.isEmpty ? nil : .toolUse)
                    if let stop {
                        continuation.yield(.done(stop))
                    }
                    // 没有 stop：流在收到终止事件前就断了。不合成一个假的
                    // .done —— 循环层据「有没有 done」判断是否中断，
                    // 伪造终止会让中断的回合被当成正常完成落库。
                    continuation.finish()

                } catch is CancellationError {
                    continuation.finish(throwing: LLMError.cancelled)
                } catch let error as LLMError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: LLMError.fromURLError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
