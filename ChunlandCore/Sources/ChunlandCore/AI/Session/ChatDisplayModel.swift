import Foundation
import Observation

// MARK: - 消息在 UI 上的表现
//
// 与 `AgentMessage`（domain）分开：domain 关心「发给模型的是什么」，
// 这里关心「用户看到的是什么」。两者刻意不同 ——
//   · 工具调用与结果在 domain 里是两条消息，在 UI 上是**一个块**（调用中 → 有结果）
//   · 流式文本在 domain 里只有最终态，在 UI 上要能逐字追加
//   · 系统提示（降级通知、轮次上限说明）在 UI 上是消息，但绝不进 domain 历史
//
// 用 class + @Observable 而不是 struct：流式追加时只需要改一个块的内容，
// 值类型会让整条消息（乃至整个数组）在每个 token 上重建。

@MainActor
@Observable
public final class ChatTextBlock: Identifiable {
    public let id = UUID()
    public var text: String
    /// 思考内容（灰字展示，可折叠），非正文。
    public let isThinking: Bool

    init(text: String = "", isThinking: Bool = false) {
        self.text = text
        self.isThinking = isThinking
    }
}

@MainActor
@Observable
public final class ChatToolBlock: Identifiable {
    public enum Status: Sendable, Equatable {
        case running
        case success
        case failed
        case cancelled
    }

    public let id: String
    public let name: String
    /// 模型自述的「这次调用在做什么」（`tool_title`）。
    ///
    /// 有它就显示它 —— 「在本店找 100 元内的坚果」比「搜索商品」有用得多。
    /// 模型没给才回落到工具的中文名。
    public var title: String?
    public var status: Status
    /// 结果摘要（折叠态显示一行）。
    public var resultPreview: String?
    /// 用户是否展开了详情。
    public var isExpanded: Bool = false

    init(id: String, name: String, title: String? = nil, status: Status = .running) {
        self.id = id
        self.name = name
        self.title = title
        self.status = status
    }

    /// 折叠态那一行的文案。
    public var headline: String {
        title ?? ChatToolBlock.friendlyName(name)
    }

    /// 工具名 → 中文。模型没给 `tool_title` 时的兜底。
    static func friendlyName(_ raw: String) -> String {
        AIToolName(rawValue: raw)?.friendlyName ?? raw
    }
}

@MainActor
public enum ChatBlock: Identifiable {
    case text(ChatTextBlock)
    case tool(ChatToolBlock)

    // `nonisolated`：`Identifiable.id` 的协议要求不带隔离，而本 enum 是 @MainActor，
    // 计算属性会继承隔离 → 跨隔离域，Swift 6 语言模式下是错误。
    // 这里只读两个 `let`（UUID / String，均 Sendable），非隔离读取无数据竞争。
    public nonisolated var id: String {
        switch self {
        case .text(let b): return "t:\(b.id.uuidString)"
        case .tool(let b): return "x:\(b.id)"
        }
    }
}

/// 一条消息在 UI 上的表现。
@MainActor
@Observable
public final class ChatDisplayMessage: Identifiable {

    public enum Role: Sendable {
        case user
        case assistant
        /// 系统提示：降级通知、轮次上限说明、上下文已压缩等。
        /// **绝不进 domain 历史** —— 它是讲给用户听的，不是讲给模型听的。
        case system
    }

    public let id = UUID()
    public let role: Role
    public var blocks: [ChatBlock]
    /// 用户附带的图片。
    public var media: [MediaRef]
    /// 出错时的说明（渲染在气泡下方）。
    public var error: String?
    /// 这条消息是否还在流式生成。
    public var isStreaming: Bool
    /// 可以从这条消息继续跑（触到轮次上限 / 被截断 / 被取消）。
    public var isResumable: Bool = false

    init(role: Role,
         blocks: [ChatBlock] = [],
         media: [MediaRef] = [],
         isStreaming: Bool = false) {
        self.role = role
        self.blocks = blocks
        self.media = media
        self.isStreaming = isStreaming
    }

    /// 纯文本内容（复制、朗读、搜索预览用）。
    public var plainText: String {
        blocks.compactMap {
            if case .text(let b) = $0, !b.isThinking { return b.text }
            return nil
        }.joined(separator: "\n")
    }

    public var isEmpty: Bool {
        blocks.isEmpty && media.isEmpty && error == nil
    }

    // MARK: - 流式构建

    /// 追加文本增量。同一段连续文本累积到同一个块里，避免每个 token 建一个块。
    func appendText(_ delta: String, thinking: Bool = false) {
        if case .text(let last)? = blocks.last, last.isThinking == thinking {
            last.text += delta
            return
        }
        blocks.append(.text(ChatTextBlock(text: delta, isThinking: thinking)))
    }

    func addTool(id: String, name: String, title: String?) {
        // 同一个工具 id 只建一个块 —— 事件可能重放（重试路径）
        if findTool(id) != nil { return }
        blocks.append(.tool(ChatToolBlock(id: id, name: name, title: title)))
    }

    func finishTool(id: String, isError: Bool, preview: String?) {
        guard let block = findTool(id) else { return }
        block.status = isError ? .failed : .success
        block.resultPreview = preview
    }

    /// 收尾时把仍在 running 的工具块强制关掉。
    ///
    /// 安全网：流中断、取消、异常退出都可能让某个块永远停在「执行中」，
    /// UI 上就是一个转不完的圈。
    func closeDanglingTools() {
        for block in blocks {
            if case .tool(let t) = block, t.status == .running {
                t.status = .cancelled
            }
        }
    }

    private func findTool(_ id: String) -> ChatToolBlock? {
        for block in blocks {
            if case .tool(let t) = block, t.id == id { return t }
        }
        return nil
    }
}
