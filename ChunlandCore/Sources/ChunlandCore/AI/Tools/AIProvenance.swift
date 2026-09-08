import Foundation

// MARK: - 会话级 provenance
//
// ⚠️ 规则与阈值必须与另一端客户端 **逐字一致**（有双端一致性校验兜底）。
//
// **它挡的是哪一档**：服务端已经挡住了「不存在 / 不属于本店 / 不可购买」——
// 那是所有权与合法性。挡不住的是**「有效、但我从没给你看过」**：模型把上一轮
// 看到的 A 商品代码记串成 B，或者干脆凭印象编一个恰好存在的 code。服务端照单全收，
// 因为那确实是一个合法商品。
//
// 所以这一层的判据不是「合不合法」而是「**这个 id 是不是本次对话里某个工具真的
// 返回过**」。它是模型可靠性的护栏，**不是安全边界** —— 真正的越权仍由服务端挡，
// 两者不可互相替代（改客户端就能绕过这里，但绕过后服务端照样拒）。

/// 受 provenance 约束的 id 类别。
public enum AIProvenanceKind: String, Sendable, CaseIterable {
    case product
    case order
    case orderItem
    case category
}

/// 一个会话「见过哪些 id」的记录者。
///
/// 每个会话一个实例，随会话消亡。用 actor 而不是加锁的 class ——
/// 只读工具是并发执行的（管道 5 路），登记会真的并发发生。
public actor ProvenanceRecorder {

    /// 每类最多记多少个。超出按先进先出淘汰。
    ///
    /// 30 轮循环里一个会话能见到的 id 有上限但不小（每次搜索 20 条），
    /// 500 足够覆盖整场对话，又不至于让长会话无限涨。
    public static let capPerKind = 500

    private var order: [AIProvenanceKind: [String]] = [:]
    private var index: [AIProvenanceKind: Set<String>] = [:]

    public init(seed: [AIProvenanceKind: [String]] = [:]) {
        // actor 的同步 init 是 nonisolated 的，不能调隔离方法 ——
        // 合并逻辑收在 nonisolated 的静态函数里，init 与 record 共用。
        for (kind, values) in seed {
            Self.merge(values, into: &order[kind, default: []], &index[kind, default: []])
        }
    }

    /// 登记本会话见过的 id。工具在拿到 DTO 时调用 —— **用 DTO 里的字段，
    /// 不要从拼好的文本里反解**（文本格式一改，provenance 就会静默失效）。
    public func record(_ kind: AIProvenanceKind, _ values: [String]) {
        Self.merge(values, into: &order[kind, default: []], &index[kind, default: []])
    }

    public func has(_ kind: AIProvenanceKind, _ value: String) -> Bool {
        index[kind]?.contains(value) ?? false
    }

    /// 返回 values 里**没见过**的那些，保持原顺序（拒绝话术要能原样列出来）。
    public func unseen(_ kind: AIProvenanceKind, _ values: [String]) -> [String] {
        let known = index[kind] ?? []
        return values.filter { !known.contains($0) }
    }

    private nonisolated static func merge(_ values: [String],
                                          into list: inout [String],
                                          _ set: inout Set<String>) {
        for value in values where !value.isEmpty && !set.contains(value) {
            list.append(value)
            set.insert(value)
        }
        while list.count > capPerKind {
            set.remove(list.removeFirst())
        }
    }
}

// MARK: - 工具执行上下文
//
// 工具执行需要的、来自会话而不是来自参数的那些东西。
// 从前这里只有 `AIToolScope`（进店限定），provenance 加进来后升成一个上下文 ——
// 把「会话给工具的东西」收在一个类型里，以后再加不必再改 16 个闭包签名。

public struct AIToolContext: Sendable {
    /// 结构化硬约束（进店时圈定 merchantId）。
    public let scope: AIToolScope
    /// 本会话见过的 id。只读工具登记，变更工具受它约束。
    public let provenance: ProvenanceRecorder

    public init(scope: AIToolScope, provenance: ProvenanceRecorder) {
        self.scope = scope
        self.provenance = provenance
    }
}
