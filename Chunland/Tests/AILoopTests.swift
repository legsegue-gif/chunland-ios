import XCTest
@testable import ChunlandCore

/// 锁循环层四块契约（与 Android `AiLoopTest.kt` 逐条对应，加用例要两边一起加）：
///
/// 1. **循环检测四策略** —— 这是放开轮次上限（8→30）的前提。检测失效 =
///    打转的模型把 30 轮全烧完，比原来更糟。
/// 2. **参数修复三策略** —— 尤其「数组/字典刻意不转」这条负向约束。
/// 3. **上下文分档与 token 估算**。
/// 4. **prompt 的关键约束句必须在场** —— 执行纪律与压缩规则是行为的直接来源，
///    被误删会静默降低 AI 表现。
final class AILoopTests: XCTestCase {

    private func toolDef(_ required: String...) -> AgentToolDefinition {
        AgentToolDefinition(
            name: "search_products",
            description: "搜索商品",
            parameters: Dictionary(uniqueKeysWithValues: required.map {
                ($0, AgentToolParam(type: .string, description: "参数 \($0)"))
            }),
            required: required
        )
    }

    // MARK: - 循环检测

    func testUnavailableToolTripsAfterThreeStrikes() {
        // 阈值刻意比其它低：拒绝话术已明说要切身份，3 次没听懂再喊也没用
        let d = ToolLoopDetector()
        let input = AgentToolInput.parse(#"{"a":1}"#)
        for _ in 0..<2 { d.record(toolName: "add_to_cart", input: input, result: nil, unavailable: true) }
        let level = d.check(toolName: "add_to_cart", input: input)
        guard case .blocked(let message) = level else {
            return XCTFail("第 3 次应熔断，实际 \(level)")
        }
        XCTAssertTrue(message.contains("切换身份"))
    }

    func testUnknownToolTripsAfterFiveStrikes() {
        let d = ToolLoopDetector()
        let input = AgentToolInput()
        for _ in 0..<4 { d.record(toolName: "no_such_tool", input: input, result: nil, unknown: true) }
        guard case .blocked = d.check(toolName: "no_such_tool", input: input) else {
            return XCTFail("第 5 次应熔断")
        }
    }

    func testChangingResultsCountAsProgress() {
        // 「结果相同」是关键判据：参数一样但结果在变说明确实在推进
        let d = ToolLoopDetector(config: ToolLoopConfig(pollWarningThreshold: 3, pollCriticalThreshold: 5))
        let input = AgentToolInput.parse(#"{"order_id":1}"#)
        d.record(toolName: "get_order_detail", input: input, result: "PENDING")
        d.record(toolName: "get_order_detail", input: input, result: "PAID")        // 变了
        d.record(toolName: "get_order_detail", input: input, result: "PURCHASING")  // 又变了
        XCTAssertEqual(d.check(toolName: "get_order_detail", input: input), .pass)
    }

    func testStalePollingWarnsThenBlocks() {
        let d = ToolLoopDetector(config: ToolLoopConfig(pollWarningThreshold: 3, pollCriticalThreshold: 5))
        let input = AgentToolInput.parse(#"{"order_id":1}"#)
        for _ in 0..<2 { d.record(toolName: "get_order_detail", input: input, result: "PENDING") }

        let warn = d.check(toolName: "get_order_detail", input: input)
        guard case .warning = warn else { return XCTFail("应先警告，实际 \(warn)") }

        for _ in 0..<2 { d.record(toolName: "get_order_detail", input: input, result: "PENDING") }
        guard case .blocked = d.check(toolName: "get_order_detail", input: input) else {
            return XCTFail("越过 critical 应熔断")
        }
    }

    func testSameWarningIsEmittedOnlyOnce() {
        // 反复喊会挤占上下文
        let d = ToolLoopDetector(config: ToolLoopConfig(repeatWarningThreshold: 2))
        let input = AgentToolInput.parse(#"{"keyword":"坚果"}"#)
        for _ in 0..<2 { d.record(toolName: "do_something", input: input, result: "same") }
        guard case .warning = d.check(toolName: "do_something", input: input) else {
            return XCTFail("首次应警告")
        }
        // 第二次同 key 不再警告
        XCTAssertEqual(d.check(toolName: "do_something", input: input), .pass)
    }

    func testEquivalentArgumentsHashTheSame() {
        // 键顺序不同但内容相同，必须判定为「同一次调用」
        let a = AgentToolInput.parse(#"{"a":1,"b":"x"}"#)
        let b = AgentToolInput.parse(#"{"b":"x","a":1}"#)
        XCTAssertEqual(ToolLoopDetector.canonical(a), ToolLoopDetector.canonical(b))
    }

    // MARK: - 参数修复

    func testTruncatedJSONIsCompleted() {
        // 模型偶尔在写完对象前被切断
        let out = ToolArgsRepair.repair(
            name: "search_products",
            input: AgentToolInput(),              // 解析失败 → 空
            rawInput: #"{"keyword":"坚果"#,        // 原始尾巴
            definition: toolDef("keyword")
        )
        XCTAssertTrue(out.didRepair, "应修复，repairs=\(out.repairs)")
        XCTAssertEqual(out.input.string("keyword"), "坚果")
    }

    func testNumbersAreCoercedToString() {
        let out = ToolArgsRepair.repair(
            name: "search_products",
            input: AgentToolInput.parse(#"{"keyword":123}"#),
            rawInput: "",
            definition: toolDef("keyword")
        )
        XCTAssertEqual(out.input.string("keyword"), "123")
    }

    func testArraysAndObjectsAreDeliberatelyNotCoerced() {
        // 转成的调试字符串会被下游当成真实值（把 ["a","b"] 当字面路径），
        // 破坏性远大于直接让 preflight 拒绝
        let out = ToolArgsRepair.repair(
            name: "search_products",
            input: AgentToolInput.parse(#"{"keyword":["a","b"]}"#),
            rawInput: "",
            definition: toolDef("keyword")
        )
        XCTAssertFalse(out.repairs.contains { $0.hasPrefix("类型转换") }, "数组不该被转换")
    }

    func testSingleLetterTypoInKeyIsCorrected() {
        let out = ToolArgsRepair.repair(
            name: "search_products",
            input: AgentToolInput.parse(#"{"keywrd":"坚果"}"#),
            rawInput: "",
            definition: toolDef("keyword")
        )
        XCTAssertEqual(out.input.string("keyword"), "坚果")
        XCTAssertTrue(out.repairs.contains { $0.contains("字段纠错") })
    }

    func testDistantKeysAreNotGuessed() {
        // name→code 距离 4，认了就是在猜
        XCTAssertNil(ToolArgsRepair.nearestKey(to: "code", in: ["name"], maxDistance: 1))
        XCTAssertEqual(ToolArgsRepair.nearestKey(to: "command", in: ["comand"], maxDistance: 1), "comand")
    }

    func testIntactArgumentsAreLeftAlone() {
        let input = AgentToolInput.parse(#"{"keyword":"坚果"}"#)
        let out = ToolArgsRepair.repair(name: "search_products", input: input,
                                        rawInput: "", definition: toolDef("keyword"))
        XCTAssertFalse(out.didRepair)
    }

    // MARK: - 上下文分档

    func testSmallWindowOnlyPromptsForNewSession() {
        // 压缩本身要占掉一大块，小模型上得不偿失
        let p = ContextPolicy(contextWindow: 16_000)
        XCTAssertEqual(p.compactThreshold, 0)
        XCTAssertTrue(p.exhaustedOnly)
        XCTAssertFalse(p.manualCompactAllowed)
        XCTAssertEqual(p.decide(usedTokens: 15_000), .exhausted)
    }

    func testLargeWindowOffloadsBeforeCompacting() {
        let p = ContextPolicy(contextWindow: 200_000)
        XCTAssertEqual(p.offloadThreshold, 160_000)
        XCTAssertEqual(p.compactThreshold, 180_000)
        XCTAssertFalse(p.exhaustedOnly)

        XCTAssertEqual(p.decide(usedTokens: 100_000), .ok)
        XCTAssertTrue(p.shouldOffload(usedTokens: 165_000))
        XCTAssertEqual(p.decide(usedTokens: 185_000), .needsCompact)
    }

    func testTokenEstimateIsWeightedByCharacterClass() {
        // 中文约 1 token/字
        XCTAssertTrue((3...5).contains(TokenEstimator.estimate("你好世界")))
        // 英文约 1 token/4 字符
        XCTAssertTrue((2...4).contains(TokenEstimator.estimate("hello world")))
        // 图片按固定值高估（低估会让上下文悄悄溢出，那是硬失败）
        let withImage = AgentMessage(
            role: .user,
            parts: [.image(MediaRef(id: "i", sha256: "s", relPath: "p",
                                    mime: "image/jpeg", bytes: 100))]
        )
        XCTAssertGreaterThanOrEqual(TokenEstimator.estimate(withImage), 800)
    }

    // MARK: - prompt 关键约束

    func testDisciplineForbidsPromisingFutureActions() {
        // 这是「显得聪明」最直接的来源：模型说「我会持续关注」然后静默，
        // 是通用 agent 上反复出现的失败模式
        let p = AIPrompts.system()
        XCTAssertTrue(p.contains("绝不以") && p.contains("承诺"), "必须禁止承诺未来动作")
        XCTAssertTrue(p.contains("回合一结束"), "必须解释回合结束后什么都不会发生")
        XCTAssertTrue(p.contains("直接调"), "必须要求直接调工具")
    }

    func testCompactionPromptForcesPastTenseAndForbidsTodoList() {
        // 摘要写成 todo 会被模型当成没干完的工单继续执行
        let c = AIPrompts.compaction
        XCTAssertTrue(c.contains("过去时"))
        XCTAssertTrue(c.contains("不要写成待办清单") || c.contains("不要写成待办"))
        XCTAssertTrue(c.contains("已完成的事"))
    }

    func testToolRulesForbidAskingForAddressOrEstimatingFees() {
        // 旧契约让模型收集姓名电话地址，导致 areaCode 丢失 → 距离费静默为 0，
        // 且地址 PII 进了模型上下文
        let p = AIPrompts.system()
        XCTAssertTrue(p.contains("绝不向用户索要姓名、电话、收货地址"))
        XCTAssertTrue(p.contains("不要自己估算费用"))
    }

    func testSystemPromptAppendsContextAndProfileOnDemand() {
        let bare = AIPrompts.system()
        XCTAssertFalse(bare.contains("当前上下文"))

        let full = AIPrompts.system(pageContext: "用户正在逛「测试店」", userProfile: "默认地址在南京")
        XCTAssertTrue(full.contains("当前上下文"))
        XCTAssertTrue(full.contains("测试店"))
        XCTAssertTrue(full.contains("关于当前用户"))
        XCTAssertTrue(full.contains("南京"))
    }

    // MARK: - 管道与检测器的接线
    //
    // 检测器单测过不代表接线对：真正的 bug 出在**管道怎么记账**。
    // 模拟器实测发现「不可用工具连击 3 次熔断」从未生效 —— 被阻断的那次
    // 记成了普通调用，把连击链自己打断，只能等 15 次的全局熔断兜底。

    private final class FakeExecutor: AgentToolExecuting, @unchecked Sendable {
        private let availableTools: Set<String>
        private(set) var executed = 0

        init(availableTools: Set<String>) { self.availableTools = availableTools }

        func availableTools() async -> [AgentToolDefinition] { [] }
        func exists(_ name: String) async -> Bool { true }
        func isAvailable(_ name: String) async -> Bool { availableTools.contains(name) }
        func unavailableMessage(_ name: String) async -> String {
            "工具 \(name) 在当前身份（代购人）下不可用，此操作需要买家身份。不要重试本工具。"
        }
        func isMutation(_ name: String) async -> Bool {
            name.hasPrefix("add_") || name.hasPrefix("place_")
        }
        func prepare(_ name: String, input: AgentToolInput) async throws -> AgentPreparedMutation {
            .ready(intent: AgentMutationIntent(id: "i", toolName: name, summary: "做点什么")) { "ok" }
        }
        func execute(_ name: String, input: AgentToolInput) async throws -> String {
            executed += 1
            return "ok"
        }
    }

    private struct AlwaysApprove: MutationConfirming {
        func confirm(_ batch: [AgentMutationIntent]) async -> Bool { true }
    }

    private var seq = 0

    /// preflight 以传入的 tools 为准：不给定义就会被判成未知工具
    private func def(_ name: String) -> AgentToolDefinition {
        AgentToolDefinition(name: name, description: "", parameters: [:], required: [])
    }

    private func entry(_ name: String) -> AgentTurnResult.ToolEntry {
        seq += 1
        return AgentTurnResult.ToolEntry(id: "call-\(name)-\(seq)", name: name,
                                         input: AgentToolInput(), rawInput: "{}")
    }

    private func resultText(_ outcome: ToolExecOutcome) -> String {
        guard case .toolResult(_, _, let text, _, _, _) = outcome.part else { return "" }
        return text
    }

    func testPipelineTripsUnavailableToolAtThreeWithoutWaitingForGlobalCircuit() async {
        let executor = FakeExecutor(availableTools: [])
        let pipeline = AgentToolPipeline(executor: executor, confirmer: AlwaysApprove(),
                                         detector: ToolLoopDetector())

        var texts: [String] = []
        for _ in 0..<5 {
            let out = await pipeline.executeBatch([entry("add_to_cart")], tools: [def("add_to_cart")])
            texts.append(resultText(out[0]))
        }
        func blocked(_ t: String) -> Bool { t.contains("已连续") && t.contains("不可用的工具") }

        // 前两次是普通的身份拒绝 —— 阈值是「连续 3 次」，早于 3 次熔断说明记账被数重了
        XCTAssertTrue(texts[0].contains("需要买家身份"), "第 1 次应是身份拒绝：\(texts[0])")
        XCTAssertFalse(blocked(texts[1]), "第 2 次不该熔断：\(texts[1])")
        // 第 3 次起熔断，且**必须持续熔断** —— 被阻断的那次若记成普通调用，
        // 连击链会被自己打断，第 4 次又退回普通拒绝（这正是实测发现的 bug）
        XCTAssertTrue(blocked(texts[2]), "第 3 次该熔断：\(texts[2])")
        XCTAssertTrue(blocked(texts[3]), "第 4 次仍应熔断（连击链不能被自己打断）：\(texts[3])")
        XCTAssertTrue(blocked(texts[4]), "第 5 次仍应熔断：\(texts[4])")
        XCTAssertEqual(executor.executed, 0, "不可用的工具一次都不该真执行")
    }

    func testAvailableToolStillRunsNormally() async {
        let executor = FakeExecutor(availableTools: ["get_cart"])
        let pipeline = AgentToolPipeline(executor: executor, confirmer: AlwaysApprove(),
                                         detector: ToolLoopDetector())
        let out = await pipeline.executeBatch([entry("get_cart")], tools: [def("get_cart")])
        XCTAssertEqual(executor.executed, 1)
        XCTAssertTrue(resultText(out[0]).contains("ok"))
    }
}
