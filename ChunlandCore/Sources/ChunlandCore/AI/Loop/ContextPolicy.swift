import Foundation

// MARK: - 上下文治理策略
//
// 放开轮次上限后的必需品：一个任务展开成十几轮工具调用，历史会迅速撑满窗口。
// 旧实现只有「保留最近 8 个用户轮 + 实时结果折叠」这一招，粗暴且不看实际占用。
//
// 三级手段按代价从低到高：
//   卸载(offload) —— 把大工具结果搬走换成引用。便宜、无损（可取回）
//   压缩(compact) —— 让模型把旧对话总结成一段。贵、有损
//   耗尽(exhaust) —— 两招都用尽还是满，只能让用户新开会话
//
// 阈值按模型窗口分档：小窗口模型压缩一次就没剩多少了，不如早点提示新开。

public struct ContextPolicy: Sendable, Equatable {

    /// 超过这个用量开始卸载。0 = 不启用。
    public let offloadThreshold: Int
    /// 卸载的目标用量（腾到这个水平就停手，不必全卸）。
    public let offloadTarget: Int
    /// 超过这个用量触发压缩。0 = 不启用。
    public let compactThreshold: Int
    /// 该档位是否只提示新开会话（不自动压缩）。
    public let exhaustedOnly: Bool
    /// 是否允许用户手动压缩。
    public let manualCompactAllowed: Bool

    public let contextWindow: Int

    public init(contextWindow: Int) {
        self.contextWindow = contextWindow

        switch contextWindow {
        case ..<32_000:
            // 太小：压缩本身就要占掉一大块，得不偿失。满了直接提示新开。
            offloadThreshold = 0
            offloadTarget = 0
            compactThreshold = 0
            exhaustedOnly = true
            manualCompactAllowed = false

        case ..<64_000:
            // 剩 10K 时卸载，不自动压缩（用户可手动）
            offloadThreshold = contextWindow - 10_000
            offloadTarget = contextWindow - 15_000
            compactThreshold = 0
            exhaustedOnly = true
            manualCompactAllowed = true

        case ..<128_000:
            offloadThreshold = contextWindow - 20_000
            offloadTarget = contextWindow - 30_000
            compactThreshold = contextWindow - 10_000
            exhaustedOnly = false
            manualCompactAllowed = true

        default:
            offloadThreshold = contextWindow - 40_000
            offloadTarget = contextWindow - 60_000
            compactThreshold = contextWindow - 20_000
            exhaustedOnly = false
            manualCompactAllowed = true
        }
    }

    // MARK: - 判定

    public enum Decision: Sendable, Equatable {
        case ok
        /// 该压缩了。
        case needsCompact
        /// 压不动了 —— 提示用户新开会话。
        case exhausted
    }

    public func decide(usedTokens: Int) -> Decision {
        if compactThreshold > 0, usedTokens >= compactThreshold {
            return .needsCompact
        }
        if exhaustedOnly {
            let ceiling = offloadThreshold > 0
                ? offloadThreshold
                : Int(Double(contextWindow) * 0.9)
            if usedTokens >= ceiling { return .exhausted }
        }
        return .ok
    }

    public func shouldOffload(usedTokens: Int) -> Bool {
        offloadThreshold > 0 && usedTokens >= offloadThreshold
    }
}

// MARK: - token 估算
//
// 不打包分词表：一份 BPE 词表几 MB，而我们只需要回答「该不该压缩了」——
// 这个决策容忍 ±15% 的误差。按字符类型加权估算零依赖、零体积，够用。
//
// 权重来自常见分词器的实际表现：
//   CJK 表意文字   ≈ 1 token/字（有时 1.5，取 1 偏保守）
//   拉丁字母/数字  ≈ 1 token/4 字符
//   标点空白       ≈ 1 token/3 字符
//
// 一旦 API 返回了真实的 usage，就以它为准 —— 估算只在没有基线时兜底。

public enum TokenEstimator {

    public static func estimate(_ text: String) -> Int {
        var ideographs = 0
        var alphanumerics = 0
        var others = 0

        for scalar in text.unicodeScalars {
            if isIdeograph(scalar) {
                ideographs += 1
            } else if CharacterSet.alphanumerics.contains(scalar) {
                alphanumerics += 1
            } else {
                others += 1
            }
        }
        return ideographs + (alphanumerics + 3) / 4 + (others + 2) / 3
    }

    /// 一条消息的估算量。
    ///
    /// 每条消息额外加 4 token 的固定开销 —— 角色标记、分隔符等 wire 层结构，
    /// 在多轮长历史里这部分累积起来并不小。
    public static func estimate(_ message: AgentMessage) -> Int {
        var total = 4
        for part in message.parts {
            switch part {
            case .text(let t):
                total += estimate(t)
            case .toolUse(_, let name, let input):
                total += estimate(name) + estimate(input.jsonString())
            case .toolResult(_, let name, let text, _, _, _):
                total += estimate(name) + estimate(text)
            case .image:
                // 图片的实际消耗随分辨率变化很大，取一个中等值。
                // 宁可高估 —— 低估会让上下文悄悄溢出，那是硬失败。
                total += 800
            }
        }
        if let reasoning = message.reasoning {
            total += estimate(reasoning)
        }
        return total
    }

    public static func estimate(_ history: [AgentMessage]) -> Int {
        history.reduce(0) { $0 + estimate($1) }
    }

    private static func isIdeograph(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xF900...0xFAFF, 0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }
}
