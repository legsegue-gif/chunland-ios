import Foundation

// MARK: - 会话消息的 domain 表示
//
// 这是运行时与业务**唯一认的形状** —— UI、agent 循环、工具管道都只认它。
// wire 编码（各 provider 自己的请求体）与 storage（SQLite 表行）都是它的投影，
// 两侧互不知道对方。
//
// 为什么要这一层：旧实现里一个类型同时是 wire 格式、运行时模型、存储 DTO，
// 三者变化频率完全不同，绑在一起的后果是历史裁剪只能去改 wire 字符串、
// 图片只能以文本形式塞进消息、工具结果无处携带引用。

/// 媒体引用 —— **字节永远不进这里，也永远不进数据库**。
/// 真实文件由 MediaStore 按内容寻址落盘，这里只带定位信息与元数据。
public struct MediaRef: Sendable, Equatable, Codable {
    /// media 表主键。
    public let id: String
    /// 内容哈希（同一张图多次发送只存一份）。
    public let sha256: String
    /// 相对媒体根目录的路径，形如 `ab/abcdef….jpg`。
    public let relPath: String
    public let mime: String
    public let bytes: Int
    public let width: Int?
    public let height: Int?

    public init(id: String, sha256: String, relPath: String, mime: String,
                bytes: Int, width: Int? = nil, height: Int? = nil) {
        self.id = id
        self.sha256 = sha256
        self.relPath = relPath
        self.mime = mime
        self.bytes = bytes
        self.width = width
        self.height = height
    }
}

/// 消息里的一段内容。
///
/// 注意 `.toolResult` 与 `.toolUse` 通过 `id` 配对 —— 这是整个 agent 循环的**第一约束**：
/// 调用与结果必须严格配对且同序，历史裁剪 / 压缩 / 卸载 / 重试 / 取消全都不能破坏它。
public enum AgentContentPart: Sendable, Equatable {
    /// 普通文本（用户输入或模型输出）。
    case text(String)

    /// 模型发起的工具调用。`input` 是已解析的参数字典。
    case toolUse(id: String, name: String, input: AgentToolInput)

    /// 工具执行结果。
    /// - `media`: 工具产出的图片（如未来的凭证识别），无则 nil
    /// - `offloadRef`: 非空表示 `text` 已被替换成占位说明，原文可按此 ref 从 OffloadStore 取回
    case toolResult(id: String, name: String, text: String, isError: Bool,
                    media: MediaRef? = nil, offloadRef: String? = nil)

    /// 用户附带的图片。
    case image(MediaRef)
}

/// 工具调用参数。
///
/// 用具体类型而不是 `[String: Any]`：`Any` 不是 `Sendable`，会让整条链路上的
/// 消息、流事件、缓存全部被迫 `@unchecked`。JSON 的取值空间本来就是封闭的，
/// 显式建模后并发检查、相等比较、编解码全部免费获得。
public enum AgentJSONValue: Sendable, Equatable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    indirect case array([AgentJSONValue])
    indirect case object([String: AgentJSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([AgentJSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: AgentJSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "无法识别的 JSON 值")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:            try c.encodeNil()
        case .bool(let v):     try c.encode(v)
        case .number(let v):   try c.encode(v)
        case .string(let v):   try c.encode(v)
        case .array(let v):    try c.encode(v)
        case .object(let v):   try c.encode(v)
        }
    }

    // MARK: 取值便利（工具 handler 用）

    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        // 模型偶尔把字符串字段发成数字/布尔，这里宽容读取；
        // 真正的修复在 ToolArgsRepair，此处只是让 handler 不必到处判类型。
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b):   return b ? "true" : "false"
        default: return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .number(let n): return Int(n)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let b):   return b
        case .string(let s): return s == "true" ? true : (s == "false" ? false : nil)
        case .number(let n): return n != 0
        default: return nil
        }
    }

    public var arrayValue: [AgentJSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: AgentJSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// 是否是「空白」值 —— preflight 判定必填字段是否形同缺失时用。
    /// 模型常发 `{"path": ""}`，键在但没内容，和缺键一样坏。
    public var isBlank: Bool {
        switch self {
        case .null: return true
        case .string(let s): return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .array(let a): return a.isEmpty
        case .object(let o): return o.isEmpty
        default: return false
        }
    }
}

/// 工具调用参数字典。
public struct AgentToolInput: Sendable, Equatable, Codable {
    public private(set) var values: [String: AgentJSONValue]

    public init(_ values: [String: AgentJSONValue] = [:]) {
        self.values = values
    }

    public init(from decoder: Decoder) throws {
        values = try [String: AgentJSONValue](from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try values.encode(to: encoder)
    }

    public var isEmpty: Bool { values.isEmpty }
    public var keys: [String] { Array(values.keys) }

    public subscript(key: String) -> AgentJSONValue? {
        get { values[key] }
        set { values[key] = newValue }
    }

    public func string(_ key: String) -> String? { values[key]?.stringValue }
    public func int(_ key: String)    -> Int?    { values[key]?.intValue }
    public func double(_ key: String) -> Double? { values[key]?.doubleValue }
    public func bool(_ key: String)   -> Bool?   { values[key]?.boolValue }

    /// 从工具调用的原始 JSON 串解析。解析失败返回空参数 —— 由 ToolArgsRepair 与
    /// preflight 接手处理，此处不抛错（模型发来的 JSON 截断是常态而非异常）。
    public static func parse(_ raw: String) -> AgentToolInput {
        guard let data = raw.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: AgentJSONValue].self, from: data) else {
            return AgentToolInput()
        }
        return AgentToolInput(dict)
    }

    /// 序列化回 JSON 串（落库与 wire 编码共用）。
    public func jsonString() -> String {
        guard let data = try? JSONEncoder().encode(values),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    /// 供 ToolArgsRepair 修改后回填。
    public mutating func set(_ key: String, _ value: AgentJSONValue?) {
        values[key] = value
    }

    public mutating func remove(_ key: String) {
        values.removeValue(forKey: key)
    }

    public mutating func rename(_ from: String, to: String) {
        guard let v = values.removeValue(forKey: from) else { return }
        values[to] = v
    }
}

/// 一条会话消息。
///
/// **只有 user / assistant 两种角色，没有 tool。** 工具结果是 user 消息里的 `.toolResult` part。
/// OpenAI wire 里的独立 `role: "tool"` 帧由 wire 层在编码时拆出来 —— domain 不关心传输格式。
public struct AgentMessage: Sendable, Equatable {
    public enum Role: String, Sendable, Codable {
        case user
        case assistant
    }

    public let role: Role
    public var parts: [AgentContentPart]

    /// 流式生成中途断开（网络掉线 / 进程被杀）。
    ///
    /// 这种消息里的 `.toolUse` 参数可能残缺（JSON 没写完），回发会被上游拒绝。
    /// agent 循环在每轮开始前据此**丢弃**尾部的中断消息，从上一回合重来。
    public var isInterrupted: Bool

    /// 部分模型返回的思考内容。多轮对话需要原样回发时才带上。
    public var reasoning: String?

    /// 落库后回填的 messages 表主键。
    /// 压缩与卸载据此定位消息边界 —— 用 id 而不是数组下标，因为历史随时可能被裁剪。
    public var dbId: String?

    public init(role: Role,
                parts: [AgentContentPart],
                isInterrupted: Bool = false,
                reasoning: String? = nil,
                dbId: String? = nil) {
        self.role = role
        self.parts = parts
        self.isInterrupted = isInterrupted
        self.reasoning = reasoning
        self.dbId = dbId
    }

    // MARK: 便利构造

    public static func user(_ text: String) -> AgentMessage {
        AgentMessage(role: .user, parts: [.text(text)])
    }

    public static func user(_ text: String, media: [MediaRef]) -> AgentMessage {
        var parts: [AgentContentPart] = text.isEmpty ? [] : [.text(text)]
        parts.append(contentsOf: media.map { .image($0) })
        return AgentMessage(role: .user, parts: parts)
    }

    public static func assistant(_ text: String) -> AgentMessage {
        AgentMessage(role: .assistant, parts: [.text(text)])
    }

    /// 一批工具结果打成一条 user 消息 —— 必须与上一条 assistant 的 toolUse 顺序一致。
    public static func toolResults(_ parts: [AgentContentPart]) -> AgentMessage {
        AgentMessage(role: .user, parts: parts)
    }

    // MARK: 查询

    /// 拼接全部文本片段（UI 预览、标题派生、FTS 入库共用）。
    public var plainText: String {
        parts.compactMap {
            if case .text(let t) = $0 { return t }
            return nil
        }.joined(separator: "\n")
    }

    public var toolUses: [(id: String, name: String, input: AgentToolInput)] {
        parts.compactMap {
            if case .toolUse(let id, let name, let input) = $0 { return (id, name, input) }
            return nil
        }
    }

    public var toolResultIds: [String] {
        parts.compactMap {
            if case .toolResult(let id, _, _, _, _, _) = $0 { return id }
            return nil
        }
    }

    public var hasToolUse: Bool { !toolUses.isEmpty }

    /// 是否整条消息都是工具结果（用于判断「最后一条是不是工具结果」——
    /// 空响应重试的触发条件之一）。
    public var isPureToolResult: Bool {
        !parts.isEmpty && parts.allSatisfy {
            if case .toolResult = $0 { return true }
            return false
        }
    }
}

// MARK: - 配对完整性
//
// 「调用与结果严格配对同序」是第一约束，但历史会被裁剪、压缩、卸载、取消打断，
// 孤儿是必然会出现的。所以每轮进入循环前都要做一次双向扫描修复，
// 而不是指望每条产生路径都不出错。

public enum AgentHistoryIntegrity {

    public struct Report: Sendable, Equatable {
        /// 有调用无结果 —— 需要补占位结果，否则模型永远等不到回应。
        public var orphanToolUses: [(messageIndex: Int, id: String, name: String)] = []
        /// 有结果无调用 —— 必须删掉，否则上游报「未知的 tool_use_id」。
        public var orphanToolResults: [(messageIndex: Int, id: String)] = []
        /// 尾部中断的 assistant 消息（参数可能残缺，整条丢弃）。
        public var trailingInterruptedIndex: Int?

        public var isClean: Bool {
            orphanToolUses.isEmpty && orphanToolResults.isEmpty && trailingInterruptedIndex == nil
        }

        public static func == (a: Report, b: Report) -> Bool {
            a.orphanToolUses.map(\.id) == b.orphanToolUses.map(\.id)
                && a.orphanToolResults.map(\.id) == b.orphanToolResults.map(\.id)
                && a.trailingInterruptedIndex == b.trailingInterruptedIndex
        }
    }

    /// 只扫描不修改 —— 修复动作由调用方执行，便于分别记日志。
    public static func scan(_ history: [AgentMessage]) -> Report {
        var report = Report()

        if let last = history.last, last.role == .assistant, last.isInterrupted {
            report.trailingInterruptedIndex = history.count - 1
        }

        var useIds = Set<String>()
        var resultIds = Set<String>()
        for msg in history {
            for part in msg.parts {
                switch part {
                case .toolUse(let id, _, _):          useIds.insert(id)
                case .toolResult(let id, _, _, _, _, _): resultIds.insert(id)
                default: break
                }
            }
        }

        for (i, msg) in history.enumerated() {
            for part in msg.parts {
                switch part {
                case .toolUse(let id, let name, _) where !resultIds.contains(id):
                    report.orphanToolUses.append((i, id, name))
                case .toolResult(let id, _, _, _, _, _) where !useIds.contains(id):
                    report.orphanToolResults.append((i, id))
                default:
                    break
                }
            }
        }
        return report
    }

    /// 按扫描结果就地修复：丢弃尾部中断消息 → 删孤儿结果 → 补孤儿调用的占位结果。
    /// 顺序不能变：先丢中断消息，它带走的 toolUse 就不必再补占位了。
    @discardableResult
    public static func repair(_ history: inout [AgentMessage]) -> Report {
        var report = scan(history)

        if let idx = report.trailingInterruptedIndex {
            history.remove(at: idx)
            report = scan(history)   // 丢弃后配对关系变了，重扫
        }

        if !report.orphanToolResults.isEmpty {
            let drop = Set(report.orphanToolResults.map(\.id))
            for i in history.indices.reversed() {
                let kept = history[i].parts.filter { part in
                    if case .toolResult(let id, _, _, _, _, _) = part { return !drop.contains(id) }
                    return true
                }
                if kept.isEmpty {
                    history.remove(at: i)
                } else if kept.count != history[i].parts.count {
                    history[i].parts = kept
                }
            }
        }

        // 补占位：紧跟在产生该调用的 assistant 消息之后插入，保持同序。
        let orphanUses = scan(history).orphanToolUses
        if !orphanUses.isEmpty {
            var byMessage: [Int: [(String, String)]] = [:]
            for o in orphanUses { byMessage[o.messageIndex, default: []].append((o.id, o.name)) }
            for (msgIdx, uses) in byMessage.sorted(by: { $0.key > $1.key }) {
                let parts = uses.map { (id, name) in
                    AgentContentPart.toolResult(
                        id: id, name: name,
                        text: "工具执行被意外中断，未能取得结果。",
                        isError: true
                    )
                }
                history.insert(.toolResults(parts), at: msgIdx + 1)
            }
        }

        return report
    }
}
