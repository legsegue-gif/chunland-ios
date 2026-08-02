import SwiftUI
import UIKit

// MARK: - MarkdownText —— AI 回复的轻量 Markdown 渲染（零第三方依赖）
//
// LLM 天然输出 markdown，而 SwiftUI `Text(变量)` 走 verbatim 语义完全不解析（星号裸奔）。
// 系统 `AttributedString(markdown:)` 只缺块级支持 —— 这里补一层按行拆块：
//   段落 / 有序·无序列表（支持缩进嵌套）/ 标题 / 引用 / 代码围栏 / 分隔线，
// 块内 inline（粗体/斜体/行内代码/链接）交给系统 API。
// 刻意不做表格、脚注等全功能 —— 购物助手的输出形态就是「段落 + 列表 + 粗体价格」。
//
// 流式期间整段重解析：纯函数、无内部状态，token 合批后每 ~80ms 一次，成本可控。
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlockParser.parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let s):
            Text(inline(s)).font(.callout)

        case .heading(let level, let s):
            Text(inline(s))
                .font(level <= 2 ? .headline : .subheadline)
                .fontWeight(.semibold)
                .padding(.top, 2)

        case .bullet(let indent, let s):
            HStack(alignment: .top, spacing: 6) {
                Text("•").font(.callout).foregroundStyle(.secondary)
                Text(inline(s)).font(.callout)
            }
            .padding(.leading, CGFloat(indent) * 14)

        case .ordered(let indent, let number, let s):
            HStack(alignment: .top, spacing: 6) {
                // 用原文序号而非重新计数 —— 被段落打断的接续列表（4. 5. 6.）不会归一
                Text("\(number).").font(.callout).foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(inline(s)).font(.callout)
            }
            .padding(.leading, CGFloat(indent) * 14)

        case .quote(let s):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(.systemGray4))
                    .frame(width: 3)
                Text(inline(s)).font(.callout).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .code(let s):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(s)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(10)
            }
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case .rule:
            Divider()
        }
    }

    // inline 解析失败（理论上 inlineOnly 不会 throw）回退原文，绝不丢内容
    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }
}

// MARK: - 块级解析

enum MarkdownBlock {
    case paragraph(String)
    case heading(level: Int, text: String)
    case bullet(indent: Int, text: String)
    case ordered(indent: Int, number: String, text: String)
    case quote(String)
    case code(String)
    case rule
}

enum MarkdownBlockParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraphLines: [String] = []
        var codeLines: [String]?          // 非 nil = 在代码围栏内
        var quoteLines: [String] = []

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
            paragraphLines = []
        }
        func flushQuote() {
            guard !quoteLines.isEmpty else { return }
            blocks.append(.quote(quoteLines.joined(separator: "\n")))
            quoteLines = []
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 代码围栏：``` 开/闭之间原样收集（流式中途未闭合 → 结尾统一 flush，内容不丢）
            if var lines = codeLines {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    codeLines = nil
                } else {
                    lines.append(line)
                    codeLines = lines
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flushParagraph(); flushQuote()
                codeLines = []
                continue
            }

            // 空行 = 块分隔
            if trimmed.isEmpty {
                flushParagraph(); flushQuote()
                continue
            }

            // 引用（连续 > 行合并为一块）
            if trimmed.hasPrefix(">") {
                flushParagraph()
                quoteLines.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            flushQuote()

            // 分隔线
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.rule)
                continue
            }

            // 标题
            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                continue
            }

            // 列表项（缩进层级 = 前导空格 / 2，封顶 3 层防深缩进把文本挤没）
            let leadingSpaces = line.prefix(while: { $0 == " " }).count
            let indent = min(leadingSpaces / 2, 3)
            if let bulletText = parseBullet(trimmed) {
                flushParagraph()
                blocks.append(.bullet(indent: indent, text: bulletText))
                continue
            }
            if let (number, itemText) = parseOrdered(trimmed) {
                flushParagraph()
                blocks.append(.ordered(indent: indent, number: number, text: itemText))
                continue
            }

            // 普通行 → 归入当前段落
            paragraphLines.append(trimmed)
        }

        flushParagraph()
        flushQuote()
        if let lines = codeLines {
            blocks.append(.code(lines.joined(separator: "\n")))
        }
        return blocks
    }

    private static func parseHeading(_ s: String) -> MarkdownBlock? {
        guard s.hasPrefix("#") else { return nil }
        let hashes = s.prefix(while: { $0 == "#" })
        guard hashes.count <= 6 else { return nil }
        let rest = s.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        return .heading(level: hashes.count, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func parseBullet(_ s: String) -> String? {
        for marker in ["- ", "* ", "+ "] where s.hasPrefix(marker) {
            return String(s.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func parseOrdered(_ s: String) -> (number: String, text: String)? {
        let digits = s.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = s.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix("、") else { return nil }
        let text = rest.hasPrefix(". ") ? rest.dropFirst(2) : rest.dropFirst(1)
        return (String(digits), text.trimmingCharacters(in: .whitespaces))
    }
}
