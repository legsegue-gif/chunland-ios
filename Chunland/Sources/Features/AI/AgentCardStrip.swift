import SwiftUI
import ChunlandCore

// MARK: - 结构化卡片条（R3）
//
// **模型只报 id，这里每个字段都来自服务端那一次查询的真实行。**
// 模型转述价格迟早会转错一次（尤其被上下文压缩之后），卡片不会 ——
// 它与同一次工具调用的文本同源，两者不会各说各话。
//
// 刻意不做点击进详情之外的交互：卡片是「权威呈现」，不是第二个操作入口。
// 加购下单仍走对话（有 HITL 确认），否则同一件事有两条语义不同的路径。

struct AgentCardStrip: View {

    let cards: [AgentCard]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                switch card.kind {
                case "product":
                    AgentProductCardView(card: card)
                default:
                    // 认不出的 kind 静默跳过 —— 服务端将来加新卡片类型时，
                    // 老客户端不该显示一块空白或崩掉
                    EmptyView()
                }
            }
        }
    }
}

private struct AgentProductCardView: View {

    let card: AgentCard

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 10) {
                thumbnail
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.name ?? "—")
                        .font(.subheadline).fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        if let price = card.price {
                            Text(Self.money(price))
                                .font(.subheadline).fontWeight(.semibold)
                                .foregroundStyle(.primary)
                        }
                        if let original = card.originalPrice, let price = card.price, original > price {
                            Text(Self.money(original))
                                .font(.caption)
                                .strikethrough()
                                .foregroundStyle(.tertiary)
                        }
                        Text(card.inStock == true ? "有货" : "缺货")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background((card.inStock == true ? Color.green : Color.secondary).opacity(0.14))
                            .clipShape(Capsule())
                            .foregroundStyle(card.inStock == true ? .green : .secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    /// 只做展示格式化 —— 一切金额计算在服务端，端上永不复算。
    private static func money(_ v: Double) -> String {
        v == v.rounded() ? "¥\(Int(v))" : "¥\(v)"
    }

    @ViewBuilder
    private var destination: some View {
        if let code = card.code {
            ProductDetailView(code: code)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        // 禁止裸 AsyncImage —— cell 回收会取消下载且无缓存，图片会随机消失
        if let url = card.thumbnail, let parsed = URL(string: url) {
            CachedAsyncImage(url: parsed) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color(.systemGray5)
            }
            .frame(width: 52, height: 52)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.tertiarySystemBackground))
                .frame(width: 52, height: 52)
                .overlay(Image(systemName: "photo").font(.caption).foregroundStyle(.tertiary))
        }
    }
}
