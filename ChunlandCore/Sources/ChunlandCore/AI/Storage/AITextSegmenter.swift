import Foundation

// MARK: - 检索分词（双端逐字一致）
//
// 为什么需要它 —— SQLite 自带的两个分词器对中文都不可用：
//
// · `unicode61`：把「帮我找100元内的坚果」切成**一个** token，搜「坚果」永远命中不了。
//   它按 Unicode 类别切分，连续的中文全是 letter 类，于是整段成词。
// · `trigram`：3 字符滑窗。3 字词、子串、英文、数字都正常，但**2 字词全军覆没**
//   （坚果 / 订单 / 退款 / 天气 …）—— 而中文最常用的恰恰是 2 字词。
//
// 所以走第三条路：**写入与查询都在应用层按字分词**，匹配交给 `LIKE`。
// 「坚果」→ 索引里是 ` 坚 果 `，查询用 `LIKE '% 坚 果 %'`，
// 空格边界要求两个 token 相邻，因此「果坚」不会误命中。
//
// ⚠️ 本文件的分词规则必须与 Android 的 AiTextSegmenter.kt **逐字一致** ——
// 一端改了规则而另一端没改，会导致索引与查询用不同的切法，搜索静默失效。

public enum AITextSegmenter {

    /// 判定为「需要逐字切分」的字符。
    ///
    /// 覆盖中日韩：基本汉字、扩展 A、兼容汉字、日文假名、韩文音节。
    /// 这些文字没有词间空格，必须逐字切；其余文字（拉丁、数字、西里尔等）
    /// 本来就靠空格与标点分词，保持原样即可。
    static func isIdeograph(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,   // 日文平假名 / 片假名
             0x3400...0x4DBF,   // CJK 扩展 A
             0x4E00...0x9FFF,   // CJK 基本
             0xF900...0xFAFF,   // CJK 兼容
             0xAC00...0xD7AF:   // 韩文音节
            return true
        default:
            return false
        }
    }

    /// 建立索引用：表意字逐字成词、字母数字连续成词、其余一律作分隔，**首尾各补一个空格**。
    ///
    ///     「帮我找100元内的坚果」 → 「 帮 我 找 100 元 内 的 坚 果 」
    ///     「[8510974] 夏普」     → 「 8510974 夏 普 」
    ///
    /// 首尾补空是为了让 `LIKE '% 坚 果 %'` 成为**整词匹配** ——
    /// 位于开头或结尾的词也有空格作边界，不必为首尾另写两条模式。
    public static func segment(_ text: String) -> String {
        var tokens: [String] = []
        var buffer = String()

        func flush() {
            if !buffer.isEmpty { tokens.append(buffer); buffer.removeAll(keepingCapacity: true) }
        }

        for ch in text {
            if ch.unicodeScalars.contains(where: isIdeograph) {
                // 表意字单独成词 —— 中文没有词间空格，逐字切是唯一稳妥的切法
                flush()
                tokens.append(String(ch))
            } else if ch.isLetter || ch.isNumber {
                buffer.append(ch)
            } else {
                // 标点、符号、空白一律作分隔并丢弃。
                // 不这么做，`[8510974]`、`search_products、get_cart` 这类
                // 会连着符号成为一个 token，搜商品号或工具名就永远命中不了。
                flush()
            }
        }
        flush()
        return tokens.isEmpty ? "" : " " + tokens.joined(separator: " ") + " "
    }

    /// 用户输入 → 一组 `LIKE` 模式（多个词之间是 AND 关系，调用方逐个加条件）。
    ///
    /// 每个词各自分词后前后包 `%`。因为索引里的 token 以空格分隔且首尾补空，
    /// `% 坚 果 %` 要求两个 token **相邻且对齐边界** —— 既不会命中「果…坚」，
    /// 也不会把「坚」误当成「坚果」的一部分。
    ///
    /// 转义是**冗余防线**：分词已把非字母数字字符全当分隔丢掉，模式里不可能出现元字符。
    /// 留着是为了将来改分词规则时不会悄悄打开 LIKE 注入面。
    public static func likePatterns(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0.isWhitespace })
            .map { segment(String($0)) }
            .filter { !$0.isEmpty }
            .map { "%" + escapeLike($0) + "%" }
    }

    /// LIKE 的转义字符，与 SQL 里的 `ESCAPE` 子句成对使用。
    public static let likeEscape = "\\"

    private static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// 在原文里定位查询词的位置，供 UI 做高亮。
    ///
    /// 不用 FTS 的 `snippet()`：它只能作用在索引列上，返回的是**分词后**的文本
    /// （带一堆空格），拿去显示很难看，还原又会吃掉用户自己打的空格。
    /// 命中的原文本来就要从 message_parts 取，直接在原文里找一遍更简单可靠。
    public static func highlightRanges(in text: String, keyword: String) -> [Range<String.Index>] {
        let terms = keyword
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }

        var ranges: [Range<String.Index>] = []
        for term in terms {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let r = text.range(of: term, options: .caseInsensitive,
                                     range: searchStart..<text.endIndex) {
                ranges.append(r)
                searchStart = r.upperBound
            }
        }
        return ranges.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// 截取包含首个命中词的一段文本，供搜索结果列表展示。
    public static func excerpt(from text: String,
                               keyword: String,
                               maxLength: Int = 60) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > maxLength else { return flat }

        guard let first = highlightRanges(in: flat, keyword: keyword).first else {
            return String(flat.prefix(maxLength)) + "…"
        }
        // 命中词居中：前面留三分之一，后面留三分之二
        let lead = maxLength / 3
        let hitOffset = flat.distance(from: flat.startIndex, to: first.lowerBound)
        let start = max(0, hitOffset - lead)
        let startIdx = flat.index(flat.startIndex, offsetBy: start)
        let endIdx = flat.index(startIdx, offsetBy: maxLength, limitedBy: flat.endIndex) ?? flat.endIndex
        var out = String(flat[startIdx..<endIdx])
        if start > 0 { out = "…" + out }
        if endIdx < flat.endIndex { out += "…" }
        return out
    }
}
