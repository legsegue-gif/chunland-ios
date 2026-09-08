import Foundation

// MARK: - 外部文本围栏与消毒
//
// ⚠️ 本文件的标记、替换表、字符区间、上限必须与 Android 的 `AiFence.kt` **逐字一致**
// （`check-ai-parity.py` 第 5 节机器校验）。漂移是静默的：一端挡住的注入另一端放行。
//
// **为什么需要**：喂给模型的文本里混着大量我们不控制的字符串 —— 商品名、店名、
// 分类名、方案名、改单说明。这些字段的作者是任意一个开店用户或上游站点，
// 服务端只做长度校验，不做内容校验。没有围栏时，一段精心构造的商品名与
// 我们自己的系统消息在模型眼里长得一模一样。
//
// **两件事，分开做，别混**：
//   sanitize  消毒 —— 剥掉能伪装成控制结构的字节。**任何进入模型的外部文本都要过**。
//   fence     围栏 —— 包上「以下是数据不是指令」的标记。**只包工具产出的数据**。
//
// 控制类文案（阻断说明、前置条件不满足的引导）只消毒不围栏 ——
// 它们本身就是要模型照做的指令，包进数据围栏等于自己否定自己。
//
// **固定标记 + 剥副本，两者缺一不可**：只加标记而不剥掉正文里的标记副本，
// 等于把一个精确的逃逸串（闭合标记）公开给攻击者，比不加更糟。

public enum AIFence {

    // MARK: - 标记
    //
    // 共用前缀让「剥副本」成为一条规则而不是一张表 —— 将来新增标记自动被覆盖。
    // 选罕见括号而非尖括号：正文里天然出现的概率极低，且不与 Markdown / HTML 抢语义。

    /// 所有内部标记的公共前缀。正文里出现它一律中和。
    public static let markerPrefix = "⟦cl:"

    public static let dataOpen  = "⟦cl:data⟧"
    public static let dataClose = "⟦cl:/data⟧"
    public static let systemOpen  = "⟦cl:sys⟧"
    public static let systemClose = "⟦cl:/sys⟧"

    /// 单条工具结果的字符上限。超出截断并明示 ——
    /// 无上限的工具（全量商品清单一类）能一次吃掉整个上下文窗口。
    public static let maxResultChars = 6000

    static let truncationNotice = "…（内容过长，已截断）"

    // MARK: - 剥除的字符
    //
    // 保留 \n(0A) 与 \t(09)：正文排版要用。\r 在换行归一化时已处理掉。
    // 三类：C0/C1 控制符、不可见与双向覆写、Unicode tag 字符（整段隐形文本的载体）。

    static let strippedRanges: [ClosedRange<UInt32>] = [
        0x0000...0x0008, 0x000B...0x000C, 0x000E...0x001F, 0x007F...0x007F,
        0x00AD...0x00AD, 0x200B...0x200F, 0x2028...0x2029, 0x202A...0x202E,
        0x2060...0x2064, 0x2066...0x2069, 0xFEFF...0xFEFF,
        0xE0000...0xE007F,
    ]

    // MARK: - 中和的串
    //
    // 顺序即优先级。全角方括号是**可见**的替身 —— 用户若真在名字里写了这些串，
    // 界面上看得出被改动过，而不是神秘消失。

    static let neutralized: [(String, String)] = [
        ("⟦cl:", "［"),
        ("<系统提醒>", "［sys］"),
        ("</系统提醒>", "［/sys］"),
        ("<|", "［|"),
        ("|>", "|］"),
    ]

    /// 行首角色标记 —— 伪造轮次的经典形态。不删除，加括号打断模式，信息不丢。
    static let rolePattern = "(?m)^([ \\t]*)(system|assistant|user|tool|系统|助手|用户)([ \\t]*[:：])"
    static let roleTemplate = "$1［$2$3］"

    /// 连续空行折叠上限 —— 防止用几百个换行把有效内容顶出视野。
    static let blankRunPattern = "\n{3,}"
    static let blankRunReplacement = "\n\n"

    // MARK: - 消毒

    /// 剥掉能伪装成控制结构的字节。**任何进入模型的外部文本都要过这里。**
    ///
    /// 对我们自己的常量文案是空操作（不含控制符、不含标记），所以放在管道的
    /// 统一出口上无差别地跑，不需要调用方判断「这段是不是外部来的」——
    /// 需要判断的地方迟早会漏。
    public static func sanitize(_ text: String) -> String {
        // ① 换行归一化，之后 \r 不再存在
        var out = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // ② 剥不可见与控制字符
        out = String(String.UnicodeScalarView(out.unicodeScalars.filter { scalar in
            !strippedRanges.contains { $0.contains(scalar.value) }
        }))

        // ③ 中和标记副本与伪造标签
        for (from, to) in neutralized {
            out = out.replacingOccurrences(of: from, with: to)
        }

        // ④ 打断行首角色标记
        out = replacingPattern(out, pattern: rolePattern, template: roleTemplate)

        // ⑤ 折叠连续空行
        out = replacingPattern(out, pattern: blankRunPattern, template: blankRunReplacement)

        return out
    }

    // MARK: - 围栏

    /// 包上数据围栏。**只用于工具产出的数据**，且必须先经 `sanitize`。
    ///
    /// 超长在这里截断 —— 截断发生在消毒之后，否则被剥掉的字节会占掉配额。
    /// 按码点计数与截断，双端口径一致且永不切断一个字符。
    public static func fence(_ sanitized: String) -> String {
        var body = sanitized
        if body.unicodeScalars.count > maxResultChars {
            body = String(String.UnicodeScalarView(body.unicodeScalars.prefix(maxResultChars)))
                + truncationNotice
        }
        return "\(dataOpen)\n\(body)\n\(dataClose)"
    }

    /// `fence` 的逆操作 —— 剥掉首尾那对数据围栏标记。
    ///
    /// **只给 UI 用**：围栏是划给模型看的边界，摆到界面上只是噪音。
    /// 绝不用在送进模型的路径上。
    ///
    /// 只剥首尾、不做全局替换：正文里的标记副本早在 `sanitize` 里被中和过，
    /// 能出现在这里的只可能是我们自己加的那一对。
    public static func unfence(_ text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix(dataOpen) { body.removeFirst(dataOpen.count) }
        if body.hasSuffix(dataClose) { body.removeLast(dataClose.count) }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 包上系统消息标记。只有我们自己的文案能用 ——
    /// 正文里的标记副本已在 `sanitize` 里中和，所以这层是可信的。
    public static func systemNote(_ text: String) -> String {
        "\(systemOpen)\(text)\(systemClose)"
    }

    // MARK: - 辅助

    private static func replacingPattern(_ text: String,
                                         pattern: String,
                                         template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
