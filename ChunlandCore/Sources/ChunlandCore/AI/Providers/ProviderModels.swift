import Foundation

// MARK: - 四级配置模型
//
//   ProviderInstance   凭证与地址（一个「来源」）
//     └ ModelEntry     该来源下的一个模型
//         └ ModelGroup 一组模型 + 路由策略（降级的载体）
//             └ 会话绑定  某个会话用哪个组 / 哪个模型
//
// 为什么要四级而不是「一条配置记录」：
// 当前实现是 provider/baseUrl/model 三个字段，意味着**系统 AI 挂了用户就没 AI 用**
// （号池耗尽 → 下发 disabled → 直接不可用）。有了组，才能表达
// 「先用系统 AI，不行就切用户自配」这件事。
//
// 结构照搬但实现只做 OpenAI 兼容（决策 D7）：系统 AI 与用户自配都是 OpenAI 兼容协议，
// 多协议实现当前没有需求驱动。

/// 来源类型。
public enum ProviderKind: String, Codable, Sendable, CaseIterable {
    /// 用户自配的 OpenAI 兼容端点。
    case openAICompatible = "openai_compatible"

    /// 系统提供的 AI（本机服务）。
    ///
    /// 地址与密钥都不存库 —— 运行时经依赖反转接缝取（端口与就绪态是动态的）。
    case system

    /// 本 App 版本不认识的类型（更高版本写入的配置）。
    /// 解码成它而不是丢弃，避免把别人的配置改坏。
    case unsupported

    public static func decoded(_ raw: String) -> ProviderKind {
        ProviderKind(rawValue: raw) ?? .unsupported
    }

    public var displayName: String {
        switch self {
        case .openAICompatible: return "自定义（OpenAI 兼容）"
        case .system: return "系统提供"
        case .unsupported: return "不支持的来源"
        }
    }

    /// 密钥是否存 Keychain。系统 AI 的密钥由接缝提供，不落任何存储。
    public var usesStoredAPIKey: Bool { self == .openAICompatible }
}

/// 一个配置好的来源。
public struct ProviderInstance: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public var label: String
    public let kind: ProviderKind
    /// OpenAI 兼容端点的 base URL（系统 AI 为 nil，运行时取）。
    public var baseURL: String?
    public var isEnabled: Bool
    public let createdAt: Date
    /// 不认识的类型的原始字符串 —— 回写时原样保留，不改坏别人的配置。
    public var unknownKindRaw: String?

    public init(id: String = UUID().uuidString,
                label: String,
                kind: ProviderKind,
                baseURL: String? = nil,
                isEnabled: Bool = true,
                createdAt: Date = .now,
                unknownKindRaw: String? = nil) {
        self.id = id
        self.label = label
        self.kind = kind
        self.baseURL = baseURL
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.unknownKindRaw = unknownKindRaw
    }

    /// 系统 AI 实例的固定 id —— 它是单例，不允许建多个。
    public static let systemInstanceId = "system"

    public static func system() -> ProviderInstance {
        ProviderInstance(id: systemInstanceId, label: "系统提供的 AI", kind: .system)
    }
}

/// 一个可用的模型。
public struct ModelEntry: Identifiable, Codable, Sendable, Equatable {
    /// 系统 AI 落库时占位用的 modelId。真实模型 id 是运行时属性，读出口现取（见 ProviderConfigStore）。
    public static let systemModelSentinel = "system"

    /// 系统 AI 条目的固定 id。
    public static let systemEntryId = "\(ProviderInstance.systemInstanceId):\(systemModelSentinel)"

    /// 复合 id：`{instanceId}:{modelId}` —— 同一个模型挂在不同来源下是两个条目。
    ///
    /// **系统 AI 例外**：它的 modelId 是运行时属性（随模块预设 / 服务端下发变化），
    /// 若编进 id，换一次模型就等于换了一个条目 —— 默认组成员与会话绑定会一起踩空。
    /// 故系统 AI 的 id 恒为 `system:system`，与 modelId 解耦。
    public var id: String {
        instanceId == ProviderInstance.systemInstanceId
            ? Self.systemEntryId
            : "\(instanceId):\(modelId)"
    }

    public let instanceId: String
    /// var 而非 let：系统 AI 的真实模型 id 由读出口现取覆盖（见 `applyingSystemPreset`）。
    public var modelId: String
    public var displayName: String
    /// 上下文窗口。决定上下文治理走哪一档策略。
    public var contextWindow: Int
    /// 默认最大输出 token。
    public var maxOutputTokens: Int
    /// 是否支持图片输入。不支持时不下发读图类工具、也不把图片编进请求。
    public var supportsVision: Bool

    public init(instanceId: String,
                modelId: String,
                displayName: String? = nil,
                contextWindow: Int = 32_000,
                maxOutputTokens: Int = 4_096,
                supportsVision: Bool = false) {
        self.instanceId = instanceId
        self.modelId = modelId
        self.displayName = displayName ?? modelId
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.supportsVision = supportsVision
    }

    /// 从复合 id 拆回两段。
    public static func split(_ entryId: String) -> (instanceId: String, modelId: String)? {
        guard let sep = entryId.firstIndex(of: ":") else { return nil }
        let inst = String(entryId[entryId.startIndex..<sep])
        let model = String(entryId[entryId.index(after: sep)...])
        guard !inst.isEmpty, !model.isEmpty else { return nil }
        return (inst, model)
    }
}

/// 组内路由策略。
public enum RoutingStrategy: String, Codable, Sendable {
    /// 按顺序试，失败换下一个。
    case fallback
    /// 会话间轮换（分摊用量）。
    case loadBalance
}

/// 什么错误触发降级。
public enum FallbackStrategy: String, Codable, Sendable {
    /// 保守：只在 provider 级错误（限流、密钥无效、拒绝）时换；
    /// 网络与瞬时错误先在当前模型重试。
    case limited
    /// 激进：任何错误都立刻换，不在当前模型重试。
    case always
}

/// 一组模型 —— 降级的载体。
public struct ModelGroup: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public var name: String
    /// 有序的成员条目 id。顺序即降级顺序。
    public var memberEntryIds: [String]
    public var strategy: RoutingStrategy
    public var fallbackStrategy: FallbackStrategy

    public init(id: String = UUID().uuidString,
                name: String,
                memberEntryIds: [String],
                strategy: RoutingStrategy = .fallback,
                fallbackStrategy: FallbackStrategy = .limited) {
        self.id = id
        self.name = name
        self.memberEntryIds = memberEntryIds
        self.strategy = strategy
        self.fallbackStrategy = fallbackStrategy
    }

    /// 默认组的固定 id —— 新装用户自动获得「系统 AI 优先，自配兜底」。
    public static let defaultGroupId = "default"
}

/// 会话用哪个模型。
public enum SessionModelBinding: Codable, Sendable, Equatable {
    /// 绑到一个组（可降级）。
    case group(String)
    /// 钉死一个模型（用户显式选择，不降级、不被自动改写）。
    case entry(String)

    public var groupId: String? {
        if case .group(let g) = self { return g }
        return nil
    }

    public var entryId: String? {
        if case .entry(let e) = self { return e }
        return nil
    }
}

// MARK: - 降级记录
//
// 降级必须让用户看得见 —— 否则「为什么今天回答风格变了」无从解释。

public struct FallbackRecord: Sendable, Equatable {
    public let fromModel: String
    public let toModel: String
    public let reason: String
    public let at: Date

    public init(fromModel: String, toModel: String, reason: String, at: Date = .now) {
        self.fromModel = fromModel
        self.toModel = toModel
        self.reason = reason
        self.at = at
    }

    public var userText: String {
        "「\(fromModel)」\(reason)，已切换到「\(toModel)」继续。"
    }
}
