import XCTest
@testable import ChunlandCore

/// 锁「只读工具 schema 线上下发」这套机制。
///
/// 这里最重要的一条不是功能，是**安全不变量**：
/// 下发的工具在端上一律只读。变更工具的 `kind: .mutation` 决定弹不弹 HITL 确认框，
/// 那是模型「想下单」与「真下单」之间唯一的人工闸门 —— 它绝不能由下发内容决定。
/// `AgentRemoteToolSpec` 结构上就没有 kind 字段，所以这条由构造保证；
/// 下面的用例守的是「接线没接错」。
@MainActor
final class AIWireToolsTests: XCTestCase {

    private func dto(_ name: String,
                     identities: [String] = ["consumer"],
                     params: [WireParamDTO] = []) -> WireToolDTO {
        WireToolDTO(name: name, description: "描述 \(name)", identities: identities, params: params)
    }

    private func param(_ name: String,
                       type: String = "string",
                       required: Bool = false,
                       enumValues: [String]? = nil,
                       itemType: String? = nil) -> WireParamDTO {
        WireParamDTO(name: name, type: type, description: "说明 \(name)",
                     required: required, enumValues: enumValues, itemType: itemType)
    }

    private func registry(suggested: Set<AIToolName>? = nil,
                          identity: String = "consumer") -> AgentToolRegistry {
        AgentToolRegistry(scope: AIToolScope(), suggested: suggested, activeIdentity: { identity })
    }

    override func tearDown() async throws {
        await AIWireToolCatalog.shared.reset()
    }

    // MARK: - DTO → spec 映射

    func testParamNamesKeepSnakeCase() {
        // 参数名是 snake_case，一旦当成 JSON 的 key 就会被 convertFromSnakeCase
        // 转成 priceMin —— 与钉死工具的口径对不上，且不报错。所以 wire 用数组带 name。
        let spec = dto("t", params: [param("price_min"), param("in_stock", type: "boolean")]).toSpec()

        XCTAssertEqual(Set(spec.definition.parameters.keys), ["price_min", "in_stock"])
        XCTAssertEqual(spec.definition.parameters["in_stock"]?.type, .boolean)
    }

    func testRequiredAndEnumAndOrderingCarryOver() {
        let spec = dto("t", params: [
            param("a", required: true),
            param("sort", enumValues: ["asc", "desc"]),
            param("tags", type: "array", itemType: "string"),
        ]).toSpec()

        XCTAssertEqual(spec.definition.required, ["a"])
        XCTAssertEqual(spec.definition.parameters["sort"]?.enumValues, ["asc", "desc"])
        XCTAssertEqual(spec.definition.parameters["tags"]?.itemType, .string)
        // 数组顺序即生成顺序 —— 部分模型对参数顺序敏感
        XCTAssertEqual(spec.definition.propertyOrdering, ["a", "sort", "tags"])
    }

    func testUnknownParamTypeDegradesInsteadOfDroppingTheTool() {
        // 服务端将来加新类型时，老客户端应当退化而不是让整个工具静默消失
        let spec = dto("t", params: [param("x", type: "no_such_type")]).toSpec()

        XCTAssertEqual(spec.definition.parameters["x"]?.type, .string)
        XCTAssertEqual(spec.name, "t")
    }

    // MARK: - 合并规则（安全不变量）

    private func definition(_ name: String) -> AgentToolDefinition {
        AgentToolDefinition(name: name, description: "钉死的 \(name)", parameters: [:], required: [])
    }

    func testPinnedWinsOnCollisionInMerge() {
        var collided: String?
        let merged = AIWireTools.merge(
            pinned: [definition("place_order")],
            pinnedNames: ["place_order"],
            wire: [dto("place_order").toSpec()],
            identity: "consumer",
            onCollision: { collided = $0 }
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].description, "钉死的 place_order")
        XCTAssertEqual(collided, "place_order")
    }

    func testMergeFiltersByIdentity() {
        let wire = [dto("list_stores", identities: ["consumer"]).toSpec()]

        XCTAssertEqual(
            AIWireTools.merge(pinned: [], pinnedNames: [], wire: wire, identity: "consumer").map(\.name),
            ["list_stores"])
        XCTAssertEqual(
            AIWireTools.merge(pinned: [], pinnedNames: [], wire: wire, identity: "agent").map(\.name),
            [])
    }

    func testWireToolsAppendAfterPinnedWithoutReordering() {
        let merged = AIWireTools.merge(
            pinned: [definition("search_products"), definition("get_cart")],
            pinnedNames: ["search_products", "get_cart"],
            wire: [dto("list_stores").toSpec()],
            identity: "consumer"
        )
        XCTAssertEqual(merged.map(\.name), ["search_products", "get_cart", "list_stores"])
    }

    // MARK: - 安全不变量（经真实 registry —— 这几条 Android 侧构造不出 registry，是 iOS 独有）

    func testWireToolIsNeverAMutation() async {
        await AIWireToolCatalog.shared.seedForTesting([dto("list_stores").toSpec()],
                                                      identity: "consumer")
        let r = registry()

        let exists = await r.exists("list_stores")
        // 这条是整个机制的支点：下发的东西永远进不了 HITL / prepare 分支
        let isMutation = await r.isMutation("list_stores")
        // 也永远没有本地实现
        let isRemote = await r.isRemote("list_stores")
        XCTAssertTrue(exists)
        XCTAssertFalse(isMutation)
        XCTAssertTrue(isRemote)
    }

    func testPinnedToolWinsOnNameCollision() async {
        // 服务端下发一个叫 place_order 的「只读」工具来遮蔽真的那个
        await AIWireToolCatalog.shared.seedForTesting([dto("place_order").toSpec()],
                                                      identity: "consumer")
        let r = registry()

        // 钉死的那份仍然是 mutation —— 遮蔽不成立
        let stillMutation = await r.isMutation("place_order")
        XCTAssertTrue(stillMutation)
        let names = await r.availableTools().map(\.name)
        XCTAssertEqual(names.filter { $0 == "place_order" }.count, 1)
    }

    // MARK: - 下发裁剪

    func testWireToolAppearsForItsIdentityOnly() async {
        await AIWireToolCatalog.shared.seedForTesting([dto("list_stores").toSpec()],
                                                      identity: "consumer")
        let consumer = await registry(identity: "consumer").availableTools().map(\.name)
        XCTAssertTrue(consumer.contains("list_stores"))

        // 代购身份下这个身份集里根本没有它（seed 是按身份存的）
        let agent = await registry(identity: "agent").availableTools().map(\.name)
        XCTAssertFalse(agent.contains("list_stores"))
    }

    func testPageSuggestionSetExcludesWireTools() async {
        await AIWireToolCatalog.shared.seedForTesting([dto("list_stores").toSpec()],
                                                      identity: "consumer")
        // 页面 ✨ 刻意收窄了工具集，而页面并不知道有哪些下发工具 ——
        // 替它塞进去等于替它做了没做的决定
        let scoped = await registry(suggested: [.searchProducts]).availableTools().map(\.name)

        XCTAssertEqual(scoped, ["search_products"])
        XCTAssertFalse(scoped.contains("list_stores"))
    }

    func testUnknownToolStillReportsNotExisting() async {
        let r = registry()
        let exists = await r.exists("no_such_tool")
        let isMutation = await r.isMutation("no_such_tool")
        XCTAssertFalse(exists)
        XCTAssertFalse(isMutation)
    }
}
