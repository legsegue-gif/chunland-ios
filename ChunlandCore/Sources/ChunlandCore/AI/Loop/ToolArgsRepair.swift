import Foundation

// MARK: - 工具参数修复
//
// 模型发来的参数残缺是**常态而非异常**：流被截断、字段名打错、把字符串发成数字。
// 直接让 preflight 拒掉是最差的处理 —— 用户看到「执行失败」，模型收到一句
// 「参数无效」多半原样再发一次，白烧两轮。
//
// 三个策略按代价从低到高排，能修就修，修不了再交给 preflight 拒绝。

public enum ToolArgsRepair {

    public struct Outcome: Sendable {
        public let input: AgentToolInput
        /// 用了哪些策略（空 = 没动过）。记日志用。
        public let repairs: [String]

        public var didRepair: Bool { !repairs.isEmpty }
    }

    /// 尝试修复。只在**确实需要**时才动手 —— 参数本来就完好时零开销。
    public static func repair(name: String,
                              input: AgentToolInput,
                              rawInput: String,
                              definition: AgentToolDefinition?) -> Outcome {
        guard let def = definition, needsRepair(input: input, definition: def) else {
            return Outcome(input: input, repairs: [])
        }

        var working = input
        var repairs: [String] = []

        // ① 截断修复：参数整体没解析出来，但原始流尾巴还在。
        //    模型偶尔在写完对象前被切断，补上闭合符号就能救回来。
        if working.isEmpty {
            let tail = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty, let fixed = tryClose(tail) {
                working = fixed.input
                repairs.append("截断补全(\(fixed.suffix.isEmpty ? "原样" : fixed.suffix))")
            }
        }

        // ② 类型强转：必填字段有值但类型不对。
        for field in def.required {
            guard let value = working[field] else { continue }
            switch value {
            case .string:
                continue
            case .null:
                // null 视为缺失 —— 清掉，让策略③ 有机会用同名近似字段填上
                working.remove(field)
                repairs.append("清空null:\(field)")
            case .number, .bool:
                if let s = value.stringValue {
                    working.set(field, .string(s))
                    repairs.append("类型转换:\(field)")
                }
            case .array, .object:
                // **刻意不转**：数组/字典转成的调试字符串会被下游当成真实值
                // （比如把 ["a","b"] 当成一个字面路径），破坏性远大于直接拒绝。
                continue
            }
        }

        // ③ 字段名纠错：必填字段缺失，但同级有个名字很像的。
        for field in def.required where working[field] == nil {
            guard let candidate = nearestKey(to: field, in: working.keys, maxDistance: 1) else { continue }
            // 不能抢走另一个必填字段的值
            guard !def.required.contains(candidate) else { continue }
            working.rename(candidate, to: field)
            repairs.append("字段纠错:\(candidate)→\(field)")
        }

        return Outcome(input: working, repairs: repairs)
    }

    // MARK: - 判定

    static func needsRepair(input: AgentToolInput, definition: AgentToolDefinition) -> Bool {
        if input.isEmpty && !definition.required.isEmpty { return true }
        for field in definition.required {
            guard let value = input[field] else { return true }
            if value.isBlank { return true }
            if case .string = value { continue }
            if case .array = value { continue }
            if case .object = value { continue }
            return true   // number / bool → 需要转成字符串
        }
        return false
    }

    // MARK: - 截断补全

    private struct Closed {
        let input: AgentToolInput
        let suffix: String
    }

    /// 依次尝试补上常见的闭合组合。
    ///
    /// 顺序按出现频率排：最常见的是字符串没收尾（`"key":"val`），
    /// 其次是对象没收尾，再次是嵌套结构。
    private static func tryClose(_ tail: String) -> Closed? {
        let suffixes = ["", "\"}", "\"", "}", "\"]}", "]}", "}}", "\"}}", "]", "]]"]
        for suffix in suffixes {
            let candidate = tail + suffix
            guard let data = candidate.data(using: .utf8),
                  let dict = try? JSONDecoder().decode([String: AgentJSONValue].self, from: data),
                  !dict.isEmpty else { continue }
            return Closed(input: AgentToolInput(dict), suffix: suffix)
        }
        return nil
    }

    // MARK: - 字段名近似

    /// 在候选里找与 target 编辑距离 ≤ maxDistance 的键。
    ///
    /// 距离阈值刻意只给 1：`comand`→`command` 该修，
    /// 但 `name`→`code` 这种距离 4 的绝不能乱认，那是在猜。
    static func nearestKey(to target: String, in keys: [String], maxDistance: Int) -> String? {
        var best: (key: String, distance: Int)?
        for key in keys where key != target {
            let d = levenshtein(key, target)
            guard d <= maxDistance else { continue }
            if best == nil || d < best!.distance {
                best = (key, d)
            }
        }
        return best?.key
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        // 长度差已经超过 1 的直接判负，省掉整个矩阵
        if abs(x.count - y.count) > 1 { return max(x.count, y.count) }

        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }
}
