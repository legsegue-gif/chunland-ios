import XCTest
@testable import ChunlandCore

/// 会话级 provenance —— 锁住「模型只能对本会话真见过的 id 下手」。
///
/// 它挡的不是越权（那是服务端的事），是**模型把 id 记串或凭印象编一个**：
/// 编出来的 code 恰好存在时，服务端会照单全收，因为那确实是个合法商品。
///
/// 「哪个工具约束哪类 id」的规则表由双端一致性校验比对，不在这里重复。
final class AIProvenanceTests: XCTestCase {

    // MARK: - 记录者

    func testRecordedIdsAreFoundAndOthersAreNot() async {
        let r = ProvenanceRecorder()
        await r.record(.product, ["123456", "abcdef"])
        var seen = await r.has(.product, "123456")
        XCTAssertTrue(seen)
        seen = await r.has(.product, "999999")
        XCTAssertFalse(seen)
        // 类别之间互不串味：订单 id 不能拿来当商品 code 用
        seen = await r.has(.order, "123456")
        XCTAssertFalse(seen)
    }

    func testUnseenReturnsOnlyUnknownAndKeepsOrder() async {
        let r = ProvenanceRecorder()
        await r.record(.product, ["b", "d"])
        // 顺序要保留 —— 拒绝话术要把没见过的原样列给模型
        var out = await r.unseen(.product, ["a", "b", "c", "d", "e"])
        XCTAssertEqual(out, ["a", "c", "e"])
        out = await r.unseen(.product, ["b", "d"])
        XCTAssertEqual(out, [])
    }

    func testSeedAppliesAtConstruction() async {
        let r = ProvenanceRecorder(seed: [.product: ["777777"]])
        let seen = await r.has(.product, "777777")
        XCTAssertTrue(seen)
    }

    func testCapEvictsOldestFirst() async {
        let r = ProvenanceRecorder()
        let cap = ProvenanceRecorder.capPerKind
        await r.record(.product, (1...cap).map { "p\($0)" })
        var seen = await r.has(.product, "p1")
        XCTAssertTrue(seen)
        await r.record(.product, ["newest"])
        seen = await r.has(.product, "p1")
        XCTAssertFalse(seen, "最早的应被淘汰")
        seen = await r.has(.product, "newest")
        XCTAssertTrue(seen, "最新的必须在")
        seen = await r.has(.product, "p2")
        XCTAssertTrue(seen, "中间的不受影响")
    }

    func testEmptyStringIsNeverRecorded() async {
        let r = ProvenanceRecorder()
        await r.record(.product, ["", "ok"])
        var seen = await r.has(.product, "")
        XCTAssertFalse(seen, "否则空参数会意外通过守卫")
        seen = await r.has(.product, "ok")
        XCTAssertTrue(seen)
    }

    func testRepeatedRecordingDoesNotGrow() async {
        let r = ProvenanceRecorder()
        for _ in 0..<3 { await r.record(.product, ["same"]) }
        let out = await r.unseen(.product, ["same"])
        XCTAssertEqual(out, [])
    }

    // MARK: - 管道接线
    //
    // 用真的 ProvenanceRecorder + 真的管道，只把「哪个工具查哪类 id」这一步做成假件。

    private final class Executor: AgentToolExecuting, @unchecked Sendable {
        let recorder: ProvenanceRecorder
        private(set) var executed = 0

        init(_ recorder: ProvenanceRecorder) { self.recorder = recorder }

        func availableTools() async -> [AgentToolDefinition] { [] }
        func exists(_ name: String) async -> Bool { true }
        func isAvailable(_ name: String) async -> Bool { true }
        func unavailableMessage(_ name: String) async -> String { "不可用" }
        func isMutation(_ name: String) async -> Bool { name == "add_to_cart" }

        func prepare(_ name: String, input: AgentToolInput) async throws -> AgentPreparedMutation {
            .ready(intent: AgentMutationIntent(id: "i", toolName: name, summary: "加购")) { [self] in
                executed += 1
                return "已加入购物车"
            }
        }

        func execute(_ name: String, input: AgentToolInput) async throws -> String {
            executed += 1
            return "ok"
        }

        func provenanceRejection(_ name: String, input: AgentToolInput) async -> String? {
            guard name == "add_to_cart" else { return nil }
            let code = input.string("product_code") ?? ""
            guard !code.isEmpty, await !recorder.has(.product, code) else { return nil }
            return "商品代码 \(code) 不在本次对话出现过的商品里。请先用 search_products 确认。不要原样重试本次调用。"
        }
    }

    private final class CountingConfirmer: MutationConfirming, @unchecked Sendable {
        private(set) var calls = 0
        func confirm(_ batch: [AgentMutationIntent]) async -> Bool {
            calls += 1
            return true
        }
    }

    private func entry(_ code: String) -> AgentTurnResult.ToolEntry {
        AgentTurnResult.ToolEntry(id: "c1", name: "add_to_cart",
                                  input: AgentToolInput(["product_code": .string(code)]),
                                  rawInput: "{\"product_code\":\"\(code)\"}")
    }

    private func definition() -> AgentToolDefinition {
        AgentToolDefinition(name: "add_to_cart", description: "", parameters: [:], required: [])
    }

    private func runBatch(_ code: String,
                          recorder: ProvenanceRecorder) async -> (String, Executor, CountingConfirmer) {
        let executor = Executor(recorder)
        let confirmer = CountingConfirmer()
        let pipeline = AgentToolPipeline(executor: executor, confirmer: confirmer,
                                         detector: ToolLoopDetector())
        let outcomes = await pipeline.executeBatch([entry(code)], tools: [definition()])
        guard case .toolResult(_, _, let text, _, _, _) = outcomes[0].part else {
            return ("", executor, confirmer)
        }
        return (text, executor, confirmer)
    }

    func testUnseenIdIsBlockedAndToolNeverRuns() async {
        let (text, executor, _) = await runBatch("999999", recorder: ProvenanceRecorder())
        XCTAssertTrue(text.contains("search_products"), "要给出可执行的下一步：\(text)")
        XCTAssertTrue(text.contains("不要原样重试"), "要禁止原样重试：\(text)")
        XCTAssertEqual(executor.executed, 0, "被拦下的调用一次都不该执行")
        XCTAssertFalse(text.hasPrefix(AIFence.dataOpen), "阻断说明是指令不是数据，不该进围栏：\(text)")
    }

    func testBlockedMutationNeverShowsConfirmSheet() async {
        let (_, _, confirmer) = await runBatch("999999", recorder: ProvenanceRecorder())
        XCTAssertEqual(confirmer.calls, 0, "否则用户点了确认才被告知没见过")
    }

    func testSeenIdPassesThrough() async {
        let recorder = ProvenanceRecorder()
        await recorder.record(.product, ["123456"])
        let (text, executor, confirmer) = await runBatch("123456", recorder: recorder)
        XCTAssertEqual(executor.executed, 1)
        XCTAssertEqual(confirmer.calls, 1, "放行的变更要正常走确认")
        XCTAssertTrue(text.contains("已加入购物车"))
    }

    func testPageContextSeedLetsCurrentProductBeAddedDirectly() async {
        // 商品详情页 ✨ 一进来就说「加购」—— 这条不通过，provenance 就是个 bug 而不是护栏
        let recorder = ProvenanceRecorder(seed: [.product: ["555555"]])
        let (_, executor, _) = await runBatch("555555", recorder: recorder)
        XCTAssertEqual(executor.executed, 1)
        let rejection = await executor.provenanceRejection(
            "add_to_cart", input: AgentToolInput(["product_code": .string("555555")])
        )
        XCTAssertNil(rejection)
    }
}
