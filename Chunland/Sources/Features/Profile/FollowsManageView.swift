import SwiftUI
import ChunlandCore

// 「收藏与关注」统一管理页：商品收藏 / 店铺 / 频道 分组展示，
// 行 = 跳转（商品→详情页、店铺→进店页；频道无主页仅展示）+ 左滑取消。
// 数据来自 GET /feed/follows/detail（服务端已带展示数据，按关注时间倒序）；
// 取消走 FollowStore.toggle（与关注按钮同一乐观更新链路，全端判态即时同步）。
struct FollowsManageView: View {
    @State private var items: [FollowDetailItem] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var merchantStore = MerchantStore.shared

    private var products: [FollowDetailItem] { items.filter { $0.type == .product } }
    private var merchants: [FollowDetailItem] { items.filter { $0.type == .merchant } }
    private var channels: [FollowDetailItem] { items.filter { $0.type == .channel } }

    var body: some View {
        Group {
            if isLoading && items.isEmpty {
                ProgressView()
            } else if let error, items.isEmpty {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            } else if items.isEmpty {
                ContentUnavailableView(
                    "还没有收藏或关注",
                    systemImage: "heart",
                    description: Text("商品详情页点 ♡ 收藏商品；进店页、发现页可关注店铺与频道")
                )
            } else {
                List {
                    section("商品收藏", products)
                    section("店铺", merchants)
                    section("频道", channels)
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("收藏与关注")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func section(_ title: String, _ group: [FollowDetailItem]) -> some View {
        if !group.isEmpty {
            Section(title) {
                ForEach(group) { item in
                    row(item)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                Task { await remove(item) }
                            } label: {
                                Label(item.type == .product ? "取消收藏" : "取消关注", systemImage: "heart.slash")
                            }
                        }
                }
            }
        }
    }

    // 商品 → 详情页；店铺 → 进店页（picker 列表命中才可跳；停用店不在列表 → 仅展示）；频道无主页仅展示
    @ViewBuilder
    private func row(_ item: FollowDetailItem) -> some View {
        switch item.type {
        case .product:
            NavigationLink(destination: ProductDetailView(code: item.targetKey)) {
                rowLabel(item, icon: "bag", subtitle: item.price.map { "¥\($0)" })
            }
        case .merchant:
            if let merchant = merchantStore.merchants.first(where: { String($0.id) == item.targetKey }) {
                NavigationLink(destination: StoreView(merchant: merchant)) {
                    rowLabel(item, icon: "storefront", subtitle: nil)
                }
            } else {
                rowLabel(item, icon: "storefront", subtitle: nil)
            }
        default:
            rowLabel(item, icon: "megaphone", subtitle: item.handle.map { "@\($0)" })
        }
    }

    private func rowLabel(_ item: FollowDetailItem, icon: String, subtitle: String?) -> some View {
        HStack(spacing: 12) {
            Color(.systemGray6)
                .frame(width: 48, height: 48)
                .overlay {
                    if let thumb = item.thumbnail, !thumb.isEmpty {
                        CachedAsyncImage(url: URL(string: thumb)) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color(.systemGray6)
                        }
                    } else {
                        Image(systemName: icon).foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name ?? "对象已失效")
                    .font(.subheadline)
                    .lineLimit(2)
                    .foregroundStyle(item.name == nil ? .secondary : .primary)
                HStack(spacing: 6) {
                    if let subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(item.type == .product ? .red : .secondary)
                    }
                    if item.available == false {
                        Text(item.type == .product ? "已下架" : "已失效")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color(.systemGray5), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        await merchantStore.loadIfNeeded()   // 店铺行跳转要 Merchant 对象
        do {
            items = try await FeedService.shared.followsDetail()
            error = nil
        } catch {
            self.error = "加载失败，下拉重试"
        }
        isLoading = false
    }

    // 乐观移除 + FollowStore 同步（失败 reload 兜底恢复）
    private func remove(_ item: FollowDetailItem) async {
        guard let type = item.type else { return }
        items.removeAll { $0.id == item.id }
        if !FollowStore.shared.isLoaded { await FollowStore.shared.loadIfNeeded() }
        if FollowStore.shared.isFollowing(type: type, key: item.targetKey),
           await FollowStore.shared.toggle(type: type, key: item.targetKey) != nil {
            await load()
        }
    }
}
