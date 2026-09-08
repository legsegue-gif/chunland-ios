import XCTest
@testable import ChunlandCore

/// 锁「重开会话后工具块的终态与摘要」。
///
/// 回归背景：曾出过一个 bug —— 重开会话后**每一个**历史工具调用都停在「执行中」
/// 转圈、且展不开结果。`display(from:)` 把 `.toolResult` 直接 `continue` 掉了，
/// `addTool` 建块默认 `.running`，此后无人补状态；旁边注释提到用来补状态的
/// `mergeToolResults` 当时并不存在。编译与单测都不报，只有真的重开一次会话才看得见 ——
/// 所以这里必须有测试，否则下次照样静默退回去。
@MainActor
final class AIToolBlockTests: XCTestCase {

    private func toolUseMessage(_ id: String) -> AgentMessage {
        AgentMessage(role: .assistant, parts: [
            .toolUse(id: id, name: "search_products",
                     input: AgentToolInput.parse(#"{"tool_title":"搜索牛奶商品"}"#)),
        ])
    }

    /// 结果挂在 user 消息上 —— domain 里只有 user/assistant 两个角色，
    /// wire 编码时才拆出独立的 `role:"tool"` 帧。
    private func toolResultMessage(_ id: String, _ text: String, isError: Bool = false) -> AgentMessage {
        AgentMessage(role: .user, parts: [
            .toolResult(id: id, name: "search_products", text: text, isError: isError),
        ])
    }

    private func toolBlocks(_ displays: [ChatDisplayMessage]) -> [ChatToolBlock] {
        displays.flatMap(\.blocks).compactMap {
            if case .tool(let block) = $0 { return block }
            return nil
        }
    }

    // MARK: - 跨消息补状态（核心回归守卫）

    func testRestoredToolBlockIsTerminalNotSpinningForever() {
        let history = [
            toolUseMessage("call_1"),
            toolResultMessage("call_1", AIFence.fence("找到 29 个商品")),
        ]

        let blocks = toolBlocks(AIChatSession.displays(from: history))

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].status, .success)
        XCTAssertEqual(blocks[0].resultPreview, "找到 29 个商品")
    }

    func testFailedToolBecomesFailed() {
        let history = [
            toolUseMessage("call_1"),
            toolResultMessage("call_1", AIFence.fence("商品不存在"), isError: true),
        ]

        XCTAssertEqual(toolBlocks(AIChatSession.displays(from: history))[0].status, .failed)
    }

    func testToolWithoutResultIsCancelledNotRunning() {
        let blocks = toolBlocks(AIChatSession.displays(from: [toolUseMessage("call_1")]))

        // 关键是「不为 running」：留在 running 就又是一个转不完的圈
        XCTAssertEqual(blocks[0].status, .cancelled)
    }

    func testMultipleToolsEachGetTheirOwnResult() {
        let history = [
            toolUseMessage("call_a"),
            toolResultMessage("call_a", AIFence.fence("A 的结果")),
            toolUseMessage("call_b"),
            toolResultMessage("call_b", AIFence.fence("B 的结果"), isError: true),
        ]

        let blocks = toolBlocks(AIChatSession.displays(from: history))
        XCTAssertEqual(blocks.count, 2)
        let a = try! XCTUnwrap(blocks.first { $0.id == "call_a" })
        let b = try! XCTUnwrap(blocks.first { $0.id == "call_b" })
        XCTAssertEqual(a.resultPreview, "A 的结果")
        XCTAssertEqual(a.status, .success)
        XCTAssertEqual(b.resultPreview, "B 的结果")
        XCTAssertEqual(b.status, .failed)
    }

    func testPureToolResultMessageDoesNotBecomeItsOwnBubble() {
        let history = [
            toolUseMessage("call_1"),
            toolResultMessage("call_1", AIFence.fence("x")),
        ]
        // 结果只是补到上一条 assistant 的块上，自己不占一条消息
        XCTAssertEqual(AIChatSession.displays(from: history).count, 1)
    }

    // MARK: - 摘要成型

    func testPreviewStripsFenceMarkers() {
        let preview = ChatDisplayMessage.toolPreview(AIFence.fence("找到 3 个商品"))

        XCTAssertEqual(preview, "找到 3 个商品")
        XCTAssertFalse(preview!.contains(AIFence.dataOpen))
        XCTAssertFalse(preview!.contains(AIFence.dataClose))
    }

    func testUnfencedTextKeptAsIs() {
        // 阻断说明这类控制文案只消毒不围栏，摘要里要原样看得到
        XCTAssertEqual(ChatDisplayMessage.toolPreview("该商品你还没看过"), "该商品你还没看过")
    }

    func testEmptyResultHasNoPreview() {
        XCTAssertNil(ChatDisplayMessage.toolPreview(nil))
        XCTAssertNil(ChatDisplayMessage.toolPreview(""))
        XCTAssertNil(ChatDisplayMessage.toolPreview("   "))
        XCTAssertNil(ChatDisplayMessage.toolPreview(AIFence.fence("")))
    }

    func testLongPreviewTruncatedByCodePoints() {
        let body = String(repeating: "商", count: ChatDisplayMessage.toolPreviewMaxChars + 50)
        let preview = try! XCTUnwrap(ChatDisplayMessage.toolPreview(AIFence.fence(body)))
        let kept = String(preview.dropLast())

        XCTAssertTrue(preview.hasSuffix(ChatDisplayMessage.toolPreviewEllipsis))
        XCTAssertEqual(kept.unicodeScalars.count, ChatDisplayMessage.toolPreviewMaxChars)
    }

    func testTruncationNeverSplitsAnAboveBMPCharacter() {
        let body = String(repeating: "🍼", count: ChatDisplayMessage.toolPreviewMaxChars + 20)
        let preview = try! XCTUnwrap(ChatDisplayMessage.toolPreview(AIFence.fence(body)))
        let kept = String(preview.dropLast())

        // 逐字相等即证明没切出半个字符
        XCTAssertEqual(kept, String(repeating: "🍼", count: ChatDisplayMessage.toolPreviewMaxChars))
    }
}
