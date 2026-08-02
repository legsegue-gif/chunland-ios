import SwiftUI
import ChunlandCore

// 店铺主页「动态」面：该店的公开动态流（feed?merchant=），复用发现流 FeedCard。
// 可购卡点进商品详情、普通贴点进内容详情 —— 与发现流同一套分流。
struct StorePostsList: View {
    let merchantId: Int

    @State private var items: [FeedItem] = []
    @State private var nextCursor: String?
    @State private var hasLoaded = false
    @State private var isLoadingMore = false
    @State private var error: String?
    @Environment(\.horizontalSizeClass) private var hSizeClass

    var body: some View {
        Group {
            if !hasLoaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ScrollView {
                    emptyOrErrorView
                        .containerRelativeFrame([.horizontal, .vertical])
                }
                .refreshable { await reload() }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            NavigationLink {
                                destination(for: item)
                            } label: {
                                FeedCard(item: item)
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 16)
                        }
                        if nextCursor != nil {
                            ProgressView()
                                .padding()
                                .task { await loadMore() }
                        }
                    }
                    .frame(maxWidth: hSizeClass == .regular ? 720 : .infinity)
                    .frame(maxWidth: .infinity)
                }
                .refreshable { await reload() }
            }
        }
        .task { await reloadIfNeeded() }
    }

    @ViewBuilder
    private var emptyOrErrorView: some View {
        if let error {
            ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
        } else {
            ContentUnavailableView("这家店还没有动态", systemImage: "megaphone",
                description: Text("店铺发布新品、活动后会出现在这里"))
        }
    }

    // 与发现流同一套分流：可购卡 → 商品详情；普通贴 → 内容详情
    @ViewBuilder
    private func destination(for item: FeedItem) -> some View {
        if let code = item.meta?.productCode {
            ProductDetailView(code: code)
        } else {
            FeedDetailView(item: item)
        }
    }

    private func reloadIfNeeded() async {
        if !hasLoaded { await reload() }
    }

    private func reload() async {
        error = nil
        do {
            let page = try await FeedService.shared.list(merchant: merchantId)
            items = page.items
            nextCursor = page.nextCursor
        } catch {
            self.error = error.localizedDescription
        }
        hasLoaded = true
    }

    private func loadMore() async {
        guard let cursor = nextCursor, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await FeedService.shared.list(cursor: cursor, merchant: merchantId)
            items += page.items
            nextCursor = page.nextCursor
        } catch {
            nextCursor = nil   // 加载更多失败：停止追加（下拉刷新可恢复）
        }
    }
}
