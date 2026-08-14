import Foundation

// MARK: - 循环与业务工具之间的接缝
//
// 循环层不知道有哪些工具、怎么执行、谁能用 —— 它只认这个协议。
// 业务侧（工具注册表）实现它，于是「加一个工具」不需要动循环一行代码。

/// 一次变更操作的意图 —— 给用户看的确认内容。
public struct AgentMutationIntent: Sendable, Identifiable, Equatable {
    public let id: String
    /// 工具名（内部标识）。
    public let toolName: String
    /// 一句话说明要做什么（「加入购物车：坚果礼盒 ×2」）。
    public let summary: String
    /// 关键参数的展示形式（金额、数量、地址等）。
    public let details: [String: String]

    public init(id: String, toolName: String, summary: String, details: [String: String] = [:]) {
        self.id = id
        self.toolName = toolName
        self.summary = summary
        self.details = details
    }
}

/// 变更工具的执行期解析产物。
///
/// **确认弹窗展示的内容与随后实际执行的动作必须来自同一份快照** ——
/// 这是「确认里看到的 = 实际执行的」由构造保证，而不是靠模型转述参数。
/// 地址、价格这类系统已有的数据由代码在执行期解析，绝不让模型重新收集。
public enum AgentPreparedMutation: Sendable {
    /// 前置条件不满足（地址簿为空、未达起送额）：不弹确认，文本直接作为工具结果回给模型。
    case abort(String)
    /// 解析完成：intent 给用户确认，通过后执行 execute。
    case ready(intent: AgentMutationIntent, execute: @Sendable () async throws -> String)
}

/// 业务工具的执行接缝。
public protocol AgentToolExecuting: Sendable {
    /// 当前身份可用的工具定义（下发给模型的那一份）。
    func availableTools() async -> [AgentToolDefinition]

    /// 工具是否存在（名字对不对）。
    func exists(_ name: String) async -> Bool

    /// 工具在**当前活跃身份**下是否可用。
    ///
    /// 与 `availableTools` 分开是必需的：会话跨身份留存，模型会从历史里
    /// 复调旧身份的工具 —— 「看不到」不等于「调不到」。
    func isAvailable(_ name: String) async -> Bool

    /// 不可用时给模型的说明（要写清需要什么身份、去哪切换）。
    func unavailableMessage(_ name: String) async -> String

    /// 是否是变更类工具（决定要不要走确认）。
    func isMutation(_ name: String) async -> Bool

    /// 变更类工具的执行期解析。
    func prepare(_ name: String, input: AgentToolInput) async throws -> AgentPreparedMutation

    /// 只读工具的执行。
    func execute(_ name: String, input: AgentToolInput) async throws -> String
}

/// 确认接缝 —— 由 UI 层实现。
public protocol MutationConfirming: Sendable {
    /// 一次确认**一批**变更。返回 true = 全部执行，false = 全部取消。
    ///
    /// 批量而不是逐个：放开轮次后一个任务可能产生 5-10 个变更
    /// （商家归类每个分类调一次），逐个弹窗用户会疯。
    /// 批量不削弱安全性 —— 用户仍看到每一项的完整摘要，只是把 N 次点击压成 1 次。
    func confirm(_ batch: [AgentMutationIntent]) async -> Bool
}
