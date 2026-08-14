import Foundation

// MARK: - 一个工具的「定义 + 执行」自包含描述
//
// 与旧 `AIToolSpec` 的差别只在类型：定义用 `AgentToolDefinition`（provider 无关，
// 自带 JSON Schema 投影与 `tool_title`），参数用 `AgentToolInput`（强类型，
// 不是 `[String: Any]`）。执行逻辑本身原样保留 —— 那些文案与兜底都是踩坑后调过的。
//
// 每个域在自己的文件里声明若干 spec，`AgentToolRegistry` 汇集。
// 新增域 = 加一个文件 + 在注册表里加一行，循环层零改动。

@MainActor
public struct AgentToolSpec {

    public let name: AIToolName
    public let definition: AgentToolDefinition
    public let kind: AIToolName.Kind

    /// 变更类专用：据参数生成给用户看的确认摘要。只读工具为 nil。
    public let intentSummary: ((AgentToolInput) -> String)?

    /// 变更类专用（可选）：执行期解析。
    ///
    /// 设了它的工具，确认与执行整体走 prepare 返回的快照 ——
    /// `intentSummary` / `run` 不再参与。这是「确认里看到的 = 实际执行的」
    /// 由构造保证，而不是靠模型转述参数。
    public let prepare: ((AgentToolInput, AIToolScope) async throws -> AgentPreparedMutation)?

    /// 执行体。第二参数是当前会话的结构化作用域 —— 进店等场景据此硬限定查询范围。
    public let run: (AgentToolInput, AIToolScope) async throws -> String

    public init(name: AIToolName,
                definition: AgentToolDefinition,
                kind: AIToolName.Kind,
                intentSummary: ((AgentToolInput) -> String)? = nil,
                prepare: ((AgentToolInput, AIToolScope) async throws -> AgentPreparedMutation)? = nil,
                run: @escaping (AgentToolInput, AIToolScope) async throws -> String) {
        self.name = name
        // 每个工具都自动带上 tool_title —— 不必在每处手写一遍
        self.definition = definition.withToolTitle()
        self.kind = kind
        self.intentSummary = intentSummary
        self.prepare = prepare
        self.run = run
    }
}

// MARK: - 构造便利
//
// 把「参数字典 + 必填列表」写成更紧凑的形式，减少每个工具定义的样板。

public extension AgentToolDefinition {

    static func make(_ name: AIToolName,
                     _ description: String,
                     params: [(String, AgentToolParam)] = [],
                     required: [String] = []) -> AgentToolDefinition {
        AgentToolDefinition(
            name: name.rawValue,
            description: description,
            parameters: Dictionary(uniqueKeysWithValues: params),
            required: required,
            propertyOrdering: params.map(\.0)
        )
    }
}

public extension AgentToolParam {
    static func string(_ description: String, values: [String]? = nil) -> AgentToolParam {
        AgentToolParam(type: .string, description: description, enumValues: values)
    }

    static func integer(_ description: String) -> AgentToolParam {
        AgentToolParam(type: .integer, description: description)
    }

    static func number(_ description: String) -> AgentToolParam {
        AgentToolParam(type: .number, description: description)
    }

    static func boolean(_ description: String) -> AgentToolParam {
        AgentToolParam(type: .boolean, description: description)
    }
}
