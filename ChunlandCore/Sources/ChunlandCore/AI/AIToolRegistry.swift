import Foundation

// MARK: - PreparedMutation —— mutation 工具「执行期解析」的产物
//
// 有 prepare 的工具在弹确认前先解析系统里的真实数据（地址簿、服务端报价等）：
// 确认弹窗展示的 intent 与随后执行的 execute 闭包持有**同一份解析快照** ——
// 「确认里看到的 = 实际执行的」由构造保证，而不是靠模型转述参数。
// 与 AIToolScope 同一条红线的延伸：系统已有的数据（地址/价格）由代码解析，
// 绝不让模型重新收集或复述（place_order 让用户口述地址 = 距离计费旁路的根因）。
public enum PreparedMutation {
    /// 前置条件不满足（如地址簿为空、未达起送）：不弹确认，文本直接作为工具结果回给模型。
    case abort(String)
    /// 解析完成：intent 给用户确认，通过后执行 execute。
    case ready(intent: MutationIntent, execute: () async throws -> String)
}

// MARK: - AIToolSpec —— 一个工具的「定义 + 执行」自包含描述
//
// 每个域（Product / Cart / Order …）在自己的 Tools/ 文件里声明若干 AIToolSpec 并注册进 AIToolRegistry。
// orchestrator 不再用巨型 switch 分发 —— 按 name 查 spec、跑 run 即可。新增域只加一个 Tools 文件，
// orchestrator / 本注册表均无需改动（这是「让 AI 长到更多域」的架构地基）。
//
// 全部在 @MainActor 执行（orchestrator 即 @MainActor）：handler 内 `await SomeService.shared.x()`
// 自然 hop 到对应 actor，[String: Any] 不跨隔离域，无需 Sendable 体操。
@MainActor
public struct AIToolSpec {
    public let name: AIToolName
    public let tool: AITool                                   // 发给 AI 的 function schema
    public let kind: AIToolName.Kind                          // readOnly 直接跑 / mutation 走 HITL
    /// mutation 专用：据 args 生成给用户看的确认摘要；readOnly 为 nil。
    public let intentSummary: (([String: Any]) -> String)?
    /// mutation 专用（可选）：执行期解析。设了它的工具，确认与执行整体走 prepare
    /// 返回的快照，intentSummary / run 不再参与 —— 见 PreparedMutation。
    public let prepare: (([String: Any], AIToolScope) async throws -> PreparedMutation)?
    /// 执行体：readOnly 立即跑；mutation 在 awaitConfirmation 通过后跑。返回给模型的文本结果。
    /// 第二参数是当前会话的结构化作用域（AIContext.scope 注入）—— 进店等场景据此硬限定查询范围。
    public let run: ([String: Any], AIToolScope) async throws -> String

    public init(name: AIToolName,
                tool: AITool,
                kind: AIToolName.Kind,
                intentSummary: (([String: Any]) -> String)? = nil,
                prepare: (([String: Any], AIToolScope) async throws -> PreparedMutation)? = nil,
                run: @escaping ([String: Any], AIToolScope) async throws -> String) {
        self.name = name
        self.tool = tool
        self.kind = kind
        self.intentSummary = intentSummary
        self.prepare = prepare
        self.run = run
    }
}

// MARK: - AIToolRegistry —— 全部域工具的单一汇集点

@MainActor
public enum AIToolRegistry {
    /// 所有已注册工具。新增域 = 在此追加该域的 specs（仅此一行变更）。
    public static let specs: [AIToolSpec] =
        ProductTools.specs + CartTools.specs + OrderTools.specs + AgentTools.specs + MerchantTools.specs

    public static func spec(for name: AIToolName) -> AIToolSpec? {
        specs.first { $0.name == name }
    }

    public static func spec(forRawName raw: String) -> AIToolSpec? {
        guard let name = AIToolName(rawValue: raw) else { return nil }
        return spec(for: name)
    }

    /// 按作用域裁剪发给 AI 的工具 schema。**当前活跃身份是全局不变量**：
    /// scope == nil（tab 主对话）→ 该身份可用的全量（allowedIdentities，三域互斥，
    /// 买家才有购物/下单、代购才有接单/结算、商家才有店铺管理）；
    /// scope 非空（页面 ✨）→ 集合 ∩ 身份可用集（页面与身份本就同层布局，交集通常是
    /// 无损的，但守住「换身份后残留 context 越权」这条缝）。
    /// 执行侧还有同判定的第二道守卫（AIOrchestrator.executeTool），此处裁剪只是第一道。
    public static func tools(scope: Set<AIToolName>?) -> [AITool] {
        let identity = AuthManager.shared.activeIdentity
        return specs.filter {
            $0.name.isAllowed(for: identity) && (scope?.contains($0.name) ?? true)
        }.map(\.tool)
    }
}
