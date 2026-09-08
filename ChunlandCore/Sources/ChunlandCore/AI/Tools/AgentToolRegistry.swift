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
    /// 该会话见过的 id。只读工具登记，变更工具受它约束。
    private let provenance: ProvenanceRecorder
    /// 当前活跃身份。用闭包而不是快照：身份可能在会话存续期间被切换。
    private let activeIdentity: () -> String
    /// 页面建议的工具子集（`AIContext.tools`）。nil = 该身份的全量。
    private let suggested: Set<AIToolName>?

    public init(scope: AIToolScope,
                suggested: Set<AIToolName>?,
                seedProvenance: [AIProvenanceKind: [String]] = [:],
                activeIdentity: @escaping () -> String) {
        self.scope = scope
        self.suggested = suggested
        self.provenance = ProvenanceRecorder(seed: seedProvenance)
        self.activeIdentity = activeIdentity
    }

    /// 工具执行上下文 —— 作用域 + provenance，随会话不变。
    private var toolContext: AIToolContext {
        AIToolContext(scope: scope, provenance: provenance)
    }

    /// 本轮攒下的结构化卡片（R3），由循环在批次执行后取走。
    private var pendingCards: [AgentCard] = []

    /// 从 @Sendable 闭包里回主 actor 攒卡片（commit 的执行体是 Sendable 的）。
    private func collectCards(_ cards: [AgentCard]) {
        pendingCards.append(contentsOf: cards)
    }

    public func drainCards() async -> [AgentCard] {
        defer { pendingCards.removeAll() }
        return pendingCards
    }

    private func spec(_ name: String) -> AgentToolSpec? {
        guard let toolName = AIToolName(rawValue: name) else { return nil }
        return Self.allSpecs.first { $0.name == toolName }
    }

    /// 线上下发的工具。
    ///
    /// **钉死的优先**：名字撞上枚举里已有的，一律当钉死的处理，下发的那份丢弃。
    /// 防的是服务端下发一个叫 `place_order` 的「只读」工具来遮蔽真的那个。
    private func wireSpec(_ name: String) async -> AgentRemoteToolSpec? {
        guard AIToolName(rawValue: name) == nil else { return nil }
        return await AIWireToolCatalog.shared
            .tools(for: activeIdentity())
            .first { $0.name == name }
    }

    // MARK: - AgentToolExecuting

    /// 下发给模型的工具集 = 身份可用集 ∩ 页面建议集。
    ///
    /// 取交集而不是并集：页面与身份本就同层布局，交集通常是无损的，
    /// 但守住「换身份后残留的页面上下文越权」这条缝。
    public func availableTools() async -> [AgentToolDefinition] {
        let identity = activeIdentity()
        let out = Self.allSpecs
            .filter { $0.name.isAllowed(for: identity) }
            .filter { suggested?.contains($0.name) ?? true }
            .map(\.definition)

        // 页面 ✨ 有建议集时**不加下发工具**：那个子集是页面刻意收窄的
        // （「在这个页面只该做这几件事」），而页面根本不知道有哪些下发工具，
        // 塞进去等于替页面做了它没做的决定。tab 主对话（无建议集）才给全。
        guard suggested == nil else { return out }

        return AIWireTools.merge(
            pinned: out,
            pinnedNames: Set(AIToolName.allCases.map(\.rawValue)),
            wire: await AIWireToolCatalog.shared.tools(for: identity),
            identity: identity,
            onCollision: { AppLogger.ai.error("下发工具与钉死的重名，已丢弃：\($0)") }
        )
    }

    public func exists(_ name: String) async -> Bool {
        if spec(name) != nil { return true }
        return await wireSpec(name) != nil
    }

    public func isAvailable(_ name: String) async -> Bool {
        if let spec = spec(name) {
            return spec.name.isAllowed(for: activeIdentity())
        }
        guard let wire = await wireSpec(name) else { return false }
        return wire.isAllowed(for: activeIdentity())
    }

    /// 不可用时给模型的说明。
    ///
    /// 必须写清「需要什么身份」「去哪切换」「不要重试」—— 只说「不可用」
    /// 模型会当成偶发失败反复重试，撞满整个轮次预算。
    public func unavailableMessage(_ name: String) async -> String {
        guard let spec = spec(name) else {
            if let wire = await wireSpec(name) {
                let needed = wire.identities.map(AIToolName.identityLabel).sorted().joined(separator: "或")
                return "工具 \(name) 在当前身份（\(AIToolName.identityLabel(activeIdentity()))）下不可用，"
                    + "此操作需要\(needed)身份。请直接告知用户：到「我的」页切换身份后再试，不要重试本工具。"
            }
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

    /// 下发工具**恒为只读**。
    ///
    /// 不是「查一个字段」——`AgentRemoteToolSpec` 结构上就没有 kind，
    /// 这里返回 false 是唯一可能的结果。HITL 确认框因此不可能被下发内容绕过。
    public func isMutation(_ name: String) async -> Bool {
        spec(name)?.kind == .mutation
    }

    /// 下发工具**恒走服务端**（它本来就没有本地实现）。
    public func isRemote(_ name: String) async -> Bool {
        if let spec = spec(name) { return spec.remote }
        return await wireSpec(name) != nil
    }

    public func prepare(_ name: String, input: AgentToolInput) async throws -> AgentPreparedMutation {
        guard let spec = spec(name) else {
            return .abort("工具 \(name) 不存在。")
        }
        // 执行期解析也在服务端的：拿票据与意图，确认后用票据 commit。
        // 快照在服务端，端上改不了将要执行的内容。
        if spec.remotePrepare {
            switch try await AIToolRemote.shared.prepare(
                name: name, args: input, identity: activeIdentity(), scope: scope
            ) {
            case .abort(let text):
                return .abort(text)
            case .ready(let token, let summary, let details):
                return .ready(
                    intent: AgentMutationIntent(
                        id: UUID().uuidString, toolName: name,
                        summary: summary, details: details
                    ),
                    execute: { [self] in
                        let result = try await AIToolRemote.shared.commit(token: token)
                        for (kind, values) in result.ids { await provenance.record(kind, values) }
                        await collectCards(result.cards)
                        return result.text
                    }
                )
            }
        }
        // 有本地 prepare 的走本地执行期解析；
        // 没有的用 intentSummary 生成摘要，执行时才跑 run。
        if let prepare = spec.prepare {
            return try await prepare(input, toolContext)
        }
        let summary = spec.intentSummary?(input) ?? "执行 \(name)"
        return .ready(
            intent: AgentMutationIntent(
                id: UUID().uuidString,
                toolName: name,
                summary: summary,
                details: Self.displayDetails(input)
            ),
            // 走 execute 而不是直接 spec.run —— 那里才有远端分流。
            // **摘要仍由端上的 intentSummary 生成**：确认框是 UI 语义，
            // 而且摘要只是参数的人话化，没有取数，不值得多一次往返。
            execute: { [self] in try await execute(name, input: input) }
        )
    }

    // MARK: - provenance 守卫
    //
    // **只约束变更工具**。只读工具是模型「去看一眼」的手段，约束它等于让模型
    // 无从获得任何 id —— 用户手打一个商品代码问「这个多少钱」也会被挡。
    //
    // 每条拒绝话术都必须做到两件事：说清**先调哪个只读工具**、明确**禁止原样重试**。
    // 只说「不认识这个 id」，模型会理解成偶发失败反复重试，撞满整个轮次预算。
    public func provenanceRejection(_ name: String, input: AgentToolInput) async -> String? {
        guard let tool = AIToolName(rawValue: name) else { return nil }
        switch tool {

        case .addToCart:
            let code = input.string("product_code") ?? ""
            // 缺参不归这里管 —— preflight 会报，两处都报会让模型收到两种说法
            guard !code.isEmpty, await !provenance.has(.product, code) else { return nil }
            return "商品代码 \(code) 不在本次对话出现过的商品里，很可能记串了或是编的。"
                + "请先用 search_products 搜到它、或用 get_product_detail 确认它存在，"
                + "拿到确切代码后再加购。不要原样重试本次调用。"

        case .assignCategoryProducts:
            if let categoryId = input.int("category_id"),
               await !provenance.has(.category, "\(categoryId)") {
                return "分类 id \(categoryId) 不在本次对话出现过的分类里。"
                    + "请先用 list_category_schemes 拿到本店各分类的 category_id 再归类。"
                    + "不要原样重试本次调用。"
            }
            let codes = AgentSchemeInput.codes(input.string("product_codes") ?? "")
            let unseen = await provenance.unseen(.product, codes)
            guard !unseen.isEmpty else { return nil }
            let listed = unseen.prefix(10).joined(separator: "、")
            return "这些商品代码本次对话没出现过：\(listed)"
                + (unseen.count > 10 ? " 等 \(unseen.count) 个" : "")
                + "。归类只能用 list_store_products 返回过的 code —— 请先调它拿到本店商品清单，"
                + "只归其中出现过的商品。不要原样重试本次调用。"

        case .proposeAdjustment:
            if let orderId = input.int("order_id"),
               await !provenance.has(.order, "\(orderId)") {
                return "订单 id \(orderId) 不在本次对话出现过的订单里。"
                    + "请先用 list_my_claims 查你的接单列表拿到确切的订单 id。不要原样重试本次调用。"
            }
            if let itemId = input.int("order_item_id"),
               await !provenance.has(.orderItem, "\(itemId)") {
                return "商品条目 id \(itemId) 不在本次对话出现过的条目里。"
                    + "请先用 get_order_detail 查这笔订单，它会列出每个商品条目的 id。"
                    + "不要原样重试本次调用。"
            }
            return nil

        default:
            return nil
        }
    }

    public func execute(_ name: String, input: AgentToolInput) async throws -> String {
        guard let spec = spec(name) else {
            // 下发工具：没有本地实现，只能走服务端
            if await wireSpec(name) != nil {
                return try await callRemote(name, input: input)
            }
            return "工具 \(name) 不存在。请从当前可用的工具中选择。"
        }
        // 已搬到服务端的：打端点、登记服务端告知的 id、原样返回它给的文本。
        // **provenance 仍在端上** —— 服务端不持有 AI 会话，只负责告知结果里有哪些 id。
        // 漏登记的后果是静默的：模型看得到 id，下一步用它却被自己拦下。
        if spec.remote {
            return try await callRemote(name, input: input)
        }
        return try await spec.run(input, toolContext)
    }

    /// 打服务端工具体，登记它告知的 id，攒下卡片。钉死与下发两类共用。
    private func callRemote(_ name: String, input: AgentToolInput) async throws -> String {
        let result = try await AIToolRemote.shared.call(
            name: name, args: input,
            identity: activeIdentity(), scope: scope
        )
        for (kind, values) in result.ids {
            await provenance.record(kind, values)
        }
        pendingCards.append(contentsOf: result.cards)
        return result.text
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
