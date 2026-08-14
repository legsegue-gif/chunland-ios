import Foundation

// MARK: - 工具定义（provider 无关）
//
// 发给模型的 function schema 的中间表示。各 provider 自己把它翻译成自家格式
// （OpenAI 的 `tools[].function.parameters`、其他家的等价物）。
//
// 与现有业务侧的工具注册表分工：注册表管「有哪些工具、谁能用、怎么执行」，
// 这里只管「怎么描述给模型」。

public enum AgentParamType: String, Sendable, Codable {
    case string
    case integer
    case number
    case boolean
    case array
    case object
}

public struct AgentToolParam: Sendable, Equatable {
    public let type: AgentParamType
    public let description: String
    /// 枚举值。写清楚可选集合能显著降低模型瞎填的概率。
    public let enumValues: [String]?
    /// `type == .array` 时的元素类型。
    public let itemType: AgentParamType?

    public init(type: AgentParamType,
                description: String,
                enumValues: [String]? = nil,
                itemType: AgentParamType? = nil) {
        self.type = type
        self.description = description
        self.enumValues = enumValues
        self.itemType = itemType
    }
}

public struct AgentToolDefinition: Sendable, Equatable {
    public let name: String
    public let description: String
    public let parameters: [String: AgentToolParam]
    public let required: [String]
    /// 参数在 schema 里的生成顺序。部分模型对顺序敏感（先给关键参数命中率更高）。
    public let propertyOrdering: [String]?

    public init(name: String,
                description: String,
                parameters: [String: AgentToolParam],
                required: [String],
                propertyOrdering: [String]? = nil) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.required = required
        self.propertyOrdering = propertyOrdering
    }

    // MARK: 通用参数

    /// 每个工具都带的自述参数：模型自己写一句给用户看的说明。
    ///
    /// 收益远大于成本 —— 工具指示器从「搜索商品」变成「在本店找 100 元内的坚果」，
    /// 用户能看懂 AI 正在做什么，而不是看一个笼统的工具名。
    public static let toolTitleKey = "tool_title"

    public static let toolTitleParam = AgentToolParam(
        type: .string,
        description: "用一句话（5-15 字）说明这次调用在做什么，展示给用户看，"
            + "例如「在本店找 100 元内的坚果」「查看订单配送进度」。用与用户相同的语言。"
    )

    /// 在已有定义上补齐 `tool_title`（业务侧注册表统一走这里，避免每个工具手写一遍）。
    public func withToolTitle() -> AgentToolDefinition {
        guard parameters[Self.toolTitleKey] == nil else { return self }
        var params = parameters
        params[Self.toolTitleKey] = Self.toolTitleParam
        var order = propertyOrdering ?? Array(parameters.keys).sorted()
        order.removeAll { $0 == Self.toolTitleKey }
        order.insert(Self.toolTitleKey, at: 0)
        return AgentToolDefinition(
            name: name,
            description: description,
            parameters: params,
            required: required + [Self.toolTitleKey],
            propertyOrdering: order
        )
    }
}

// MARK: - JSON Schema 投影
//
// 放在 domain 而不是 provider 里：OpenAI 兼容协议是当前唯一实现，
// 但 JSON Schema 本身是跨协议通用的，各家只是外层包装不同。

public extension AgentToolDefinition {

    /// 生成 `parameters` 的 JSON Schema 对象。
    func parametersSchema() -> AgentJSONValue {
        let order = propertyOrdering ?? parameters.keys.sorted()
        var props: [String: AgentJSONValue] = [:]
        for key in order {
            guard let p = parameters[key] else { continue }
            var field: [String: AgentJSONValue] = [
                "type": .string(p.type.rawValue),
                "description": .string(p.description),
            ]
            if let e = p.enumValues, !e.isEmpty {
                field["enum"] = .array(e.map { .string($0) })
            }
            if p.type == .array, let item = p.itemType {
                field["items"] = .object(["type": .string(item.rawValue)])
            }
            props[key] = .object(field)
        }
        return .object([
            "type": .string("object"),
            "properties": .object(props),
            "required": .array(required.map { .string($0) }),
        ])
    }

    /// OpenAI 兼容格式的完整工具描述。
    func openAISchema() -> AgentJSONValue {
        .object([
            "type": .string("function"),
            "function": .object([
                "name": .string(name),
                "description": .string(description),
                "parameters": parametersSchema(),
            ]),
        ])
    }
}

// MARK: - 执行前校验（preflight）
//
// 模型发来空参数或字段名打错是常态：流截断、笔误、把必填当选填。
// 直接让 handler 崩或返回「执行出错」是最差的处理 —— 用户看到失败，
// 模型也不知道自己错在哪，多半会原样重发一次。

public enum AgentToolPreflight {

    public struct Rejection: Sendable, Equatable {
        /// 给日志与 UI 看的简短原因。
        public let reason: String
        /// 给模型看的完整说明。
        ///
        /// **必须明确禁止原样重试** —— 不写这句的话，模型收到「参数无效」
        /// 会理解成「再发一次试试」，于是同样的空参数再来一遍。
        public let modelMessage: String

        public init(reason: String, modelMessage: String) {
            self.reason = reason
            self.modelMessage = modelMessage
        }
    }

    /// 校验必填字段。返回 nil 表示通过。
    public static func validate(name: String,
                                input: AgentToolInput,
                                definition: AgentToolDefinition?) -> Rejection? {
        guard let def = definition else {
            return Rejection(
                reason: "未知工具 \(name)",
                modelMessage: "工具 \(name) 不存在。请从当前可用的工具列表中选择，不要重复调用这个名字。"
            )
        }

        var missing: [String] = []
        for field in def.required {
            guard let value = input[field] else { missing.append(field); continue }
            if value.isBlank { missing.append(field) }
        }
        guard !missing.isEmpty else { return nil }

        let list = missing.joined(separator: "、")
        return Rejection(
            reason: "缺少必填参数：\(list)",
            modelMessage: "调用 \(name) 被拒绝：缺少必填参数 \(list)（为空或未提供）。"
                + "请补全这些参数后重新调用，**不要用同样的空参数重试**。"
        )
    }
}
