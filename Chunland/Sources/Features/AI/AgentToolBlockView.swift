import SwiftUI
import ChunlandCore

// MARK: - 工具调用块
//
// 旧实现只有一行「正在搜索商品…」的灰字指示器，调用完就消失，
// 用户既不知道 AI 查了什么，也无从判断结果对不对。
//
// 新的三点改进：
//   · 显示模型自述的 `tool_title`（「在本店找 100 元内的坚果」而不是「搜索商品」）
//   · 保留终态（成功/失败/取消都留在对话里，可回看）
//   · 可展开看结果摘要 —— 默认折叠，不打断阅读

struct AgentToolBlockView: View {
    @Bindable var block: ChatToolBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if block.isExpanded, let preview = block.resultPreview, !preview.isEmpty {
                Divider().padding(.leading, 30)
                Text(preview)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        Button {
            guard block.resultPreview?.isEmpty == false else { return }
            withAnimation(.easeInOut(duration: 0.15)) { block.isExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                statusIcon
                Text(block.headline)
                    .font(.footnote)
                    .foregroundStyle(block.status == .failed ? Color.red : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if block.resultPreview?.isEmpty == false {
                    Image(systemName: block.isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 没有可展开内容时不接受点击，避免给出「能点」的错误暗示
        .disabled(block.resultPreview?.isEmpty != false)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch block.status {
        case .running:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 14, height: 14)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .frame(width: 14, height: 14)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .frame(width: 14, height: 14)
        case .cancelled:
            Image(systemName: "minus.circle.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 14, height: 14)
        }
    }
}

// MARK: - 思考块
//
// 部分模型会输出推理过程。默认折叠 —— 它对结果没有约束力，
// 展开只是给好奇的用户看，不该占据正文的注意力。

struct AgentThinkingBlockView: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.caption2)
                    Text(isExpanded ? "收起思考过程" : "查看思考过程")
                        .font(.caption)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(.tertiarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
