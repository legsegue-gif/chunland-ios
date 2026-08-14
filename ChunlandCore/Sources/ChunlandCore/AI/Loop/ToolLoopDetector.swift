import Foundation
import CryptoKit

// MARK: - 工具循环检测
//
// 放开轮次上限（8 → 30）的**前提条件**。没有它，一个打转的模型会把 30 轮全烧完，
// 用户等半天拿到一句「轮次过多」。
//
// 四种打转形态各有不同的处置：
//   身份不可用工具连击 → 模型没听懂「切身份」的提示，再喊也没用，直接熔断
//   未知工具连击      → 工具名不存在，重试永远失败
//   相同调用无进展    → 同参数同结果反复出现，卡在一个点上
//   轮询无进展        → 反复查同一个状态，什么都没变
//
// 两级处置：
//   警告 —— 把提示**塞进工具结果**让模型自己纠正，不阻断（多数情况这就够了）
//   熔断 —— 直接返回阻断说明，不执行（模型已经证明自己纠正不了）

public struct ToolLoopConfig: Sendable {
    /// 保留多少条历史用于判定。
    public var historySize: Int
    /// 身份不可用工具连击几次熔断。
    ///
    /// 比其它阈值低得多：拒绝话术已经明确写了「到『我的』页切换身份后再试，
    /// 不要重试本工具」，3 次仍在撞说明模型没听懂，再喊也没用。
    public var unavailableToolThreshold: Int
    /// 未知工具（名字都不存在）连击几次熔断。
    public var unknownToolThreshold: Int
    /// 同工具同参数重复几次发警告。
    public var repeatWarningThreshold: Int
    /// 轮询类工具无进展几次发警告 / 几次熔断。
    public var pollWarningThreshold: Int
    public var pollCriticalThreshold: Int
    /// 全局熔断：同工具同参数同结果反复出现。
    public var globalCircuitThreshold: Int

    public init(historySize: Int = 30,
                unavailableToolThreshold: Int = 3,
                unknownToolThreshold: Int = 5,
                repeatWarningThreshold: Int = 5,
                pollWarningThreshold: Int = 5,
                pollCriticalThreshold: Int = 10,
                globalCircuitThreshold: Int = 15) {
        self.unavailableToolThreshold = max(1, unavailableToolThreshold)
        self.unknownToolThreshold = max(1, unknownToolThreshold)
        self.repeatWarningThreshold = max(1, repeatWarningThreshold)
        self.pollWarningThreshold = max(1, pollWarningThreshold)
        self.pollCriticalThreshold = max(pollWarningThreshold + 1, pollCriticalThreshold)
        self.globalCircuitThreshold = max(pollCriticalThreshold + 1, globalCircuitThreshold)
        self.historySize = max(historySize, self.globalCircuitThreshold)
    }
}

public enum LoopLevel: Sendable, Equatable {
    case pass
    /// 提示塞进工具结果，仍然执行。
    case warning(String)
    /// 阻断执行，把说明当作工具结果返回。
    case blocked(String)
}

/// 检测器。
///
/// 每个会话一个实例，随会话生命周期存活。
public final class ToolLoopDetector: @unchecked Sendable {

    private struct Record {
        let toolName: String
        let argsHash: String
        var resultHash: String?
        /// 这次调用是否因为工具不可用（身份不匹配）而被拒。
        let unavailable: Bool
        /// 工具名是否根本不存在。
        let unknown: Bool
    }

    private let config: ToolLoopConfig
    private var history: [Record] = []
    /// 已发过的警告 key —— 同一个问题只提醒一次，反复喊会挤占上下文。
    private var warnedKeys: Set<String> = []
    private let lock = NSLock()

    public init(config: ToolLoopConfig = ToolLoopConfig()) {
        self.config = config
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        history.removeAll()
        warnedKeys.removeAll()
    }

    // MARK: - 执行前

    /// 执行前检查。`.blocked` 时调用方必须短路，把消息当作工具结果返回。
    public func check(toolName: String, input: AgentToolInput) -> LoopLevel {
        lock.lock(); defer { lock.unlock() }

        let hash = Self.hash(toolName: toolName, input: input)

        // ① 身份不可用工具连击 —— 最高优先级
        let unavailableStreak = tailStreak { $0.toolName == toolName && $0.unavailable }
        if unavailableStreak >= config.unavailableToolThreshold {
            return .blocked(
                "已连续 \(unavailableStreak) 次尝试当前身份不可用的工具「\(toolName)」。"
                + "请停止重试，直接告诉用户需要切换身份，然后基于现有信息作答。"
            )
        }

        // ② 未知工具连击
        let unknownStreak = tailStreak { $0.toolName == toolName && $0.unknown }
        if unknownStreak >= config.unknownToolThreshold {
            return .blocked(
                "工具「\(toolName)」不存在，已连续尝试 \(unknownStreak) 次。"
                + "请从当前可用的工具列表中选择，或不使用工具直接作答。"
            )
        }

        // ③ 全局熔断：同工具同参数同结果反复出现
        let noProgress = noProgressStreak(toolName: toolName, argsHash: hash)
        if noProgress >= config.globalCircuitThreshold {
            return .blocked(
                "「\(toolName)」已用相同参数得到相同结果 \(noProgress) 次，没有任何进展。"
                + "请停止调用，基于已有结果作答，或告诉用户这件事暂时做不到。"
            )
        }

        // ④ 轮询类：低阈值警告、高阈值熔断
        if Self.isPollingTool(toolName) {
            if noProgress >= config.pollCriticalThreshold {
                return .blocked(
                    "「\(toolName)」已查询 \(noProgress) 次且状态始终未变。"
                    + "请停止轮询，把当前状态告诉用户。"
                )
            }
            if noProgress >= config.pollWarningThreshold {
                return warnOnce(key: "poll:\(toolName):\(hash)",
                    "你已经查询「\(toolName)」\(noProgress) 次，状态没有变化。"
                    + "不要继续轮询 —— 把当前状态告诉用户，让他稍后再问。")
            }
        }

        // ⑤ 相同参数重复（非轮询工具）
        let repeats = history.reduce(0) { $0 + (($1.toolName == toolName && $1.argsHash == hash) ? 1 : 0) }
        if repeats >= config.repeatWarningThreshold {
            return warnOnce(key: "repeat:\(toolName):\(hash)",
                "你已用完全相同的参数调用「\(toolName)」\(repeats) 次。"
                + "如果结果不是你想要的，请换参数或换个思路，不要重复同一次调用。")
        }

        return .pass
    }

    // MARK: - 执行后

    /// 记录一次调用。**每条路径都必须调用**（包括被阻断、被拒绝、执行失败），
    /// 漏记会让检测器看不到打转。
    public func record(toolName: String,
                       input: AgentToolInput,
                       result: String?,
                       unavailable: Bool = false,
                       unknown: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        var record = Record(
            toolName: toolName,
            argsHash: Self.hash(toolName: toolName, input: input),
            resultHash: nil,
            unavailable: unavailable,
            unknown: unknown
        )
        record.resultHash = result.map { Self.sha($0) }
        history.append(record)
        if history.count > config.historySize {
            history.removeFirst(history.count - config.historySize)
        }
    }

    // MARK: - 内部

    /// 从尾部数连续满足条件的记录数。
    private func tailStreak(_ predicate: (Record) -> Bool) -> Int {
        var n = 0
        for record in history.reversed() {
            guard predicate(record) else { break }
            n += 1
        }
        // +1 是把「当前这次调用」算进去 —— check 发生在 record 之前。
        return n > 0 ? n + 1 : 0
    }

    /// 同工具同参数、且结果也相同的连续次数。
    ///
    /// 「结果相同」是关键：参数一样但结果在变，说明确实在推进（比如轮询到状态变了）。
    private func noProgressStreak(toolName: String, argsHash: String) -> Int {
        var n = 0
        var expected: String??
        for record in history.reversed() {
            guard record.toolName == toolName, record.argsHash == argsHash else { break }
            if expected == nil { expected = record.resultHash }
            guard record.resultHash == expected else { break }
            n += 1
        }
        return n > 0 ? n + 1 : 0
    }

    private func warnOnce(key: String, _ message: String) -> LoopLevel {
        guard warnedKeys.insert(key).inserted else { return .pass }
        return .warning(message)
    }

    /// 哪些工具算「轮询」—— 反复查同一个状态。
    ///
    /// 用后缀/前缀判定而不是硬编码工具名清单：新增同类工具时不必改这里，
    /// 而工具命名本来就有约定（查询类以 get_/list_ 开头）。
    static func isPollingTool(_ name: String) -> Bool {
        name.hasPrefix("get_") || name.hasPrefix("list_")
    }

    static func hash(toolName: String, input: AgentToolInput) -> String {
        sha(toolName + "|" + canonical(input))
    }

    /// 参数的规范化表示 —— 键排序后拼接，保证等价参数得到同一个哈希。
    static func canonical(_ input: AgentToolInput) -> String {
        input.keys.sorted().map { key in
            "\(key)=\(input[key].map(Self.describe) ?? "")"
        }.joined(separator: "&")
    }

    private static func describe(_ value: AgentJSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .string(let s): return s
        case .array(let a): return "[" + a.map(describe).joined(separator: ",") + "]"
        case .object(let o): return "{" + o.keys.sorted().map { "\($0):\(describe(o[$0]!))" }.joined(separator: ",") + "}"
        }
    }

    static func sha(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
