import Foundation

// MARK: - 工具注册表（循环与业务之间的实现）
//
// 实现 `AgentToolExecuting` —— 循环层只认那个协议，不知道有哪些工具。
//
// **三身份可用集是这里的核心不变量**：
// 工具可用集是「当前活跃身份」的函数，两侧共用同一判定 ——
//   下发侧：`availableTools` 裁剪发给模型的 schema
//   执行侧：`isAvailable` 在管道的 preflight 阶段再拦一次
// 执行侧必须存在：会话跨身份留存（切身份不清历史），模型可能从历史里
// 复调旧身份的工具名，「模型看不到」不等于「调不到」。

@MainActor
public final class AgentToolRegistry: AgentToolExecuting {

    /// 全部已注册工具。新增域 = 在此追加该域的 specs（仅此一行变更）。
    static let allSpecs: [AgentToolSpec] = AgentShoppingTools.specs + AgentBusinessTools.specs

    /// 该会话的作用域 —— 进店等场景据此把查询硬限定到某个商家。
    private let scope: AIToolScope
    /// 当前活跃身份。用闭包而不是快照：身份可能在会话存续期间被切换。
    private let activeIdentity: () -> String
    /// 页面建议的工具子集（`AIContext.tools`）。nil = 该身份的全量。
    private let suggested: Set<AIToolName>?

    public init(scope: AIToolScope,
                suggested: Set<AIToolName>?,
                activeIdentity: @escaping () -> String) {
        self.scope = scope
        self.suggested = suggested
        self.activeIdentity = activeIdentity
    }

    private func spec(_ name: String) -> AgentToolSpec? {
        guard let toolName = AIToolName(rawValue: name) else { return nil }
        return Self.allSpecs.first { $0.name == toolName }
    }

    // MARK: - AgentToolExecuting

    /// 下发给模型的工具集 = 身份可用集 ∩ 页面建议集。
    ///
    /// 取交集而不是并集：页面与身份本就同层布局，交集通常是无损的，
    /// 但守住「换身份后残留的页面上下文越权」这条缝。
    public func availableTools() async -> [AgentToolDefinition] {
        let identity = activeIdentity()
        return Self.allSpecs
            .filter { $0.name.isAllowed(for: identity) }
            .filter { suggested?.contains($0.name) ?? true }
            .map(\.definition)
    }

    public func exists(_ name: String) async -> Bool {
        spec(name) != nil
    }

    public func isAvailable(_ name: String) async -> Bool {
        guard let spec = spec(name) else { return false }
        return spec.name.isAllowed(for: activeIdentity())
    }

    /// 不可用时给模型的说明。
    ///
    /// 必须写清「需要什么身份」「去哪切换」「不要重试」—— 只说「不可用」
    /// 模型会当成偶发失败反复重试，撞满整个轮次预算。
    public func unavailableMessage(_ name: String) async -> String {
        guard let spec = spec(name) else {
            return "工具 \(name) 不存在。请从当前可用的工具中选择。"
        }
        let identity = activeIdentity()
        let needed = spec.name.allowedIdentities
            .map(AIToolName.identityLabel)
            .sorted()
            .joined(separator: "或")
        return "工具 \(name) 在当前身份（\(AIToolName.identityLabel(identity))）下不可用，"
            + "此操作需要\(needed)身份。请直接告知用户：到「我的」页切换身份后再试，不要重试本工具。"
    }

    public func isMutation(_ name: String) async -> Bool {
        spec(name)?.kind == .mutation
    }

    public func prepare(_ name: String, input: AgentToolInput) async throws -> AgentPreparedMutation {
        guard let spec = spec(name) else {
            return .abort("工具 \(name) 不存在。")
        }
        // 有 prepare 的走执行期解析（确认与执行共用同一份快照）；
        // 没有的用 intentSummary 生成摘要，执行时才跑 run。
        if let prepare = spec.prepare {
            return try await prepare(input, scope)
        }
        let summary = spec.intentSummary?(input) ?? "执行 \(name)"
        return .ready(
            intent: AgentMutationIntent(
                id: UUID().uuidString,
                toolName: name,
                summary: summary,
                details: Self.displayDetails(input)
            ),
            execute: { [scope] in try await spec.run(input, scope) }
        )
    }

    public func execute(_ name: String, input: AgentToolInput) async throws -> String {
        guard let spec = spec(name) else {
            return "工具 \(name) 不存在。请从当前可用的工具中选择。"
        }
        return try await spec.run(input, scope)
    }

    // MARK: - 确认框的参数展示

    /// 把工具参数转成给用户看的键值对。
    ///
    /// 跳过 `tool_title` —— 它是模型写给用户看的说明，已经在摘要里了，
    /// 再作为一个参数列出来是重复。
    static func displayDetails(_ input: AgentToolInput) -> [String: String] {
        var out: [String: String] = [:]
        for key in input.keys where key != AgentToolDefinition.toolTitleKey {
            guard let value = input[key], !value.isBlank else { continue }
            out[key] = value.stringValue ?? ""
        }
        return out
    }
}
