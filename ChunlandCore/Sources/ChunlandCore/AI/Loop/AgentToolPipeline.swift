import Foundation

// MARK: - 工具执行管道
//
// 单个工具调用的固定处理顺序：
//
//   取消预检 → 循环检测 → 参数修复 → preflight（含身份守卫）→ 执行 → 记录
//
// **任何一条路径都不能跳过最后的记录步骤** —— 漏记会让循环检测器看不到打转，
// 于是熔断永远不触发，放开的轮次上限就成了隐患而不是能力。
// 所以每条 return 路径都产出同一种结果对象，由本管道统一 record。

public struct ToolExecOutcome: Sendable {
    public let toolId: String
    public let toolName: String
    /// 回给模型的工具结果片段。
    public let part: AgentContentPart
    /// 是否因用户取消而中止。
    public let cancelled: Bool
    /// 模型自述的这次调用在做什么（`tool_title`），给 UI 展示。
    public let title: String?
    public let isError: Bool
}

public struct AgentToolPipeline: Sendable {

    private let executor: any AgentToolExecuting
    private let confirmer: any MutationConfirming
    private let detector: ToolLoopDetector
    private let logger = AppLogger(subsystem: AppLogger.subsystem, category: "ai.tool")

    /// 只读工具的并发上限。
    ///
    /// 工具全是自家服务端调用，5 路足够；实际同轮很少超过 3 个。
    public static let maxConcurrent = 5

    public init(executor: any AgentToolExecuting,
                confirmer: any MutationConfirming,
                detector: ToolLoopDetector) {
        self.executor = executor
        self.confirmer = confirmer
        self.detector = detector
    }

    // MARK: - 批次执行

    /// 执行一批工具调用，结果**严格按原顺序**返回。
    ///
    /// 顺序是硬约束：wire 上 `role:"tool"` 帧必须与前一条 assistant 的
    /// `tool_calls` 同序，错位会让模型把 A 的结果当成 B 的。
    public func executeBatch(
        _ entries: [AgentTurnResult.ToolEntry],
        tools: [AgentToolDefinition]
    ) async -> [ToolExecOutcome] {
        guard !entries.isEmpty else { return [] }

        // 先把变更类挑出来做执行期解析，凑成一个批次一次确认。
        var prepared: [Int: AgentPreparedMutation] = [:]
        var intents: [AgentMutationIntent] = []

        for (index, entry) in entries.enumerated() {
            guard await executor.isMutation(entry.name) else { continue }
            // 不可用的工具不必解析 —— 但这里**只判定不记账**：真正的守卫与
            // 循环记账唯一发生在 runOne 的 preCheck。两处都记会让同一次调用
            // 被数两遍，「连续 N 次」的阈值语义就变成了 N/2 轮。
            guard await executor.isAvailable(entry.name) else { continue }
            let repaired = repairInput(entry, tools: tools)
            do {
                let result = try await executor.prepare(entry.name, input: repaired)
                prepared[index] = result
                if case .ready(let intent, _) = result { intents.append(intent) }
            } catch {
                // 解析失败留给下面的执行阶段统一处理成错误结果
                logger.warn("变更解析失败", metadata: ["tool": entry.name])
            }
        }

        // 一次确认整批。用户取消 = 整批取消。
        var approved = true
        if !intents.isEmpty {
            approved = await confirmer.confirm(intents)
            logger.info("批量确认", metadata: ["count": "\(intents.count)", "approved": "\(approved)"])
        }

        // 只读工具并发（无写副作用、同轮之间也没有数据依赖 ——
        // 依赖前一个结果的调用模型只能在下一轮才发得出）。
        // 变更工具按序（同轮「先加购后查车」的因果不能乱）。
        var outcomes = [ToolExecOutcome?](repeating: nil, count: entries.count)

        let readOnlyIndices = await entries.indices.asyncFilter { !(await executor.isMutation(entries[$0].name)) }
        let mutationIndices = entries.indices.filter { !readOnlyIndices.contains($0) }

        await withTaskGroup(of: (Int, ToolExecOutcome).self) { group in
            var launched = 0
            var harvested = 0
            for index in readOnlyIndices {
                while launched - harvested >= Self.maxConcurrent {
                    if let pair = await group.next() {
                        outcomes[pair.0] = pair.1
                        harvested += 1
                    } else { break }
                }
                group.addTask {
                    (index, await self.runOne(entries[index], tools: tools, prepared: nil, approved: true))
                }
                launched += 1
            }
            for await pair in group {
                outcomes[pair.0] = pair.1
            }
        }

        for index in mutationIndices {
            outcomes[index] = await runOne(
                entries[index], tools: tools, prepared: prepared[index], approved: approved
            )
        }

        return outcomes.enumerated().map { index, outcome in
            outcome ?? ToolExecOutcome(
                toolId: entries[index].id,
                toolName: entries[index].name,
                part: .toolResult(id: entries[index].id, name: entries[index].name,
                                  text: "工具未能执行。", isError: true),
                cancelled: false, title: nil, isError: true
            )
        }
    }

    // MARK: - 单个执行

    private func runOne(
        _ entry: AgentTurnResult.ToolEntry,
        tools: [AgentToolDefinition],
        prepared: AgentPreparedMutation?,
        approved: Bool
    ) async -> ToolExecOutcome {

        let title = entry.input.string(AgentToolDefinition.toolTitleKey)

        // ① 取消预检 —— 用户点了停止之后才轮到的调用，直接短路，
        //    但仍要产出结果片段，否则历史里会留下没有结果的调用（孤儿）。
        if Task.isCancelled {
            return finish(entry, title: title, text: "用户已取消操作。", isError: true, cancelled: true)
        }

        // ② 循环检测 + ③ 身份守卫 + ④ 未知工具
        switch await preCheck(entry, tools: tools) {
        case .pass:
            break
        case .blocked(let message):
            return finish(entry, title: title, text: message, isError: true, cancelled: false)
        case .warningAttached(let note):
            // 警告不阻断，执行后把提示附在结果后面让模型自纠
            return await execute(entry, tools: tools, prepared: prepared,
                                 approved: approved, title: title, warning: note)
        }

        return await execute(entry, tools: tools, prepared: prepared,
                             approved: approved, title: title, warning: nil)
    }

    private enum PreCheck {
        case pass
        case blocked(String)
        case warningAttached(String)
    }

    private func preCheck(_ entry: AgentTurnResult.ToolEntry,
                          tools: [AgentToolDefinition]) async -> PreCheck {
        // 先定这次调用属于哪一类（存在？当前身份可用？）——
        // 必须在 detector.check 之前拿到：被熔断阻断的那次同样要按**原本的类别**
        // 记账。若记成普通调用，连击链会被自己打断，于是「不可用工具连击」
        // 这类低阈值保护永远数不到阈值，只能等全局熔断（阈值高得多）兜底。
        // `&&` 的右侧是 autoclosure，塞不进 await —— 拆成显式分支。
        let exists = await executor.exists(entry.name)
        var available = false
        if exists { available = await executor.isAvailable(entry.name) }

        // 循环检测放在最前：模型已经在打转时，连参数修复都不必做了。
        switch detector.check(toolName: entry.name, input: entry.input) {
        case .blocked(let message):
            detector.record(toolName: entry.name, input: entry.input, result: nil,
                            unavailable: exists && !available, unknown: !exists)
            return .blocked(message)
        case .warning(let note):
            return .warningAttached(note)
        case .pass:
            break
        }

        guard exists else {
            detector.record(toolName: entry.name, input: entry.input, result: nil, unknown: true)
            return .blocked("工具「\(entry.name)」不存在，请从可用工具中选择。")
        }

        // 身份守卫并入 preflight 阶段：这样它天然享受「拒绝话术禁止原样重试」
        // 的规范，也会被循环检测器记录 —— 模型反复撞同一堵墙会被熔断，
        // 而不是一轮轮撞满整个轮次预算。
        guard available else {
            let message = await executor.unavailableMessage(entry.name)
            detector.record(toolName: entry.name, input: entry.input, result: nil, unavailable: true)
            return .blocked(message)
        }

        return .pass
    }

    private func execute(
        _ entry: AgentTurnResult.ToolEntry,
        tools: [AgentToolDefinition],
        prepared: AgentPreparedMutation?,
        approved: Bool,
        title: String?,
        warning: String?
    ) async -> ToolExecOutcome {

        let repaired = repairInput(entry, tools: tools)

        // preflight：必填校验。拒绝话术必须明确禁止原样重试，
        // 否则模型收到「参数无效」会理解成「再发一次试试」。
        let definition = tools.first { $0.name == entry.name }
        if let rejection = AgentToolPreflight.validate(
            name: entry.name, input: repaired, definition: definition
        ) {
            detector.record(toolName: entry.name, input: repaired, result: nil)
            logger.warn("preflight 拒绝", metadata: ["tool": entry.name, "reason": rejection.reason])
            return finish(entry, title: title, text: rejection.modelMessage, isError: true, cancelled: false)
        }

        do {
            let text: String
            if let prepared {
                switch prepared {
                case .abort(let message):
                    // 前置条件不满足 —— 不是错误，是要告诉模型「换个做法」
                    detector.record(toolName: entry.name, input: repaired, result: message)
                    return finish(entry, title: title, text: message, isError: false, cancelled: false)
                case .ready(_, let run):
                    guard approved else {
                        detector.record(toolName: entry.name, input: repaired, result: nil)
                        return finish(entry, title: title, text: "用户取消了这次操作。",
                                      isError: false, cancelled: true)
                    }
                    text = try await run()
                }
            } else {
                text = try await executor.execute(entry.name, input: repaired)
            }

            detector.record(toolName: entry.name, input: repaired, result: text)
            let body = warning.map { "\(text)\n\n<系统提醒>\($0)</系统提醒>" } ?? text
            return finish(entry, title: title, text: body, isError: false, cancelled: false)

        } catch {
            let message = "执行「\(entry.name)」时出错：\(error.localizedDescription)"
            detector.record(toolName: entry.name, input: repaired, result: message)
            logger.error("工具执行失败", metadata: ["tool": entry.name, "error": "\(error)"])
            return finish(entry, title: title, text: message, isError: true, cancelled: false)
        }
    }

    // MARK: - 辅助

    private func repairInput(_ entry: AgentTurnResult.ToolEntry,
                             tools: [AgentToolDefinition]) -> AgentToolInput {
        let definition = tools.first { $0.name == entry.name }
        let outcome = ToolArgsRepair.repair(
            name: entry.name, input: entry.input,
            rawInput: entry.rawInput, definition: definition
        )
        if outcome.didRepair {
            logger.info("参数已修复", metadata: [
                "tool": entry.name,
                "repairs": outcome.repairs.joined(separator: ","),
            ])
        }
        return outcome.input
    }

    private func finish(_ entry: AgentTurnResult.ToolEntry,
                        title: String?,
                        text: String,
                        isError: Bool,
                        cancelled: Bool) -> ToolExecOutcome {
        ToolExecOutcome(
            toolId: entry.id,
            toolName: entry.name,
            part: .toolResult(id: entry.id, name: entry.name, text: text, isError: isError),
            cancelled: cancelled,
            title: title,
            isError: isError
        )
    }
}

// MARK: - 异步过滤

private extension Collection {
    func asyncFilter(_ predicate: (Element) async -> Bool) async -> [Element] {
        var out: [Element] = []
        for element in self where await predicate(element) {
            out.append(element)
        }
        return out
    }
}
