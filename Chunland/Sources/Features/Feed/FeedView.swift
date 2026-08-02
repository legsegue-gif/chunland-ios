import SwiftUI
import ChunlandCore

struct FeedView: View {
    @EnvironmentObject private var auth: AuthManager
    @State private var store = FeedStore.shared                       // 为你推荐（共享缓存）
    @State private var followingStore = FeedStore(mode: .following)   // 正在关注（局部）
    @State private var followStore = FollowStore.shared
    @State private var mode: FeedMode = .forYou
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @EnvironmentObject private var tabRouter: TabRouter

    // 双 mode 各自的滚动位置与「是否在顶部」标记（同时只显示一个，但分开避免切 mode 串扰）
    @State private var forYouPosition = ScrollPosition(edge: .top)
    @State private var followingPosition = ScrollPosition(edge: .top)
    @State private var forYouAtTop = true
    @State private var followingAtTop = true
    // 「已在顶部时再点『发现』」触发的手动刷新：顶部露出转圈并把内容下移（模仿 X）
    @State private var isRefreshing = false

    var body: some View {
        Group {
            switch mode {
            case .forYou:    feedScroll(store, position: $forYouPosition, atTop: $forYouAtTop)
            case .following: followingContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationBarTitleDisplayMode(.inline)
        // 「为你推荐/正在关注」切换器放进 navbar principal：复用顶部那条、不再单独占一行（去掉大标题腾内容空间）
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $mode) {
                    Text("为你推荐").tag(FeedMode.forYou)
                    Text("正在关注").tag(FeedMode.following)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
        }
        // 重复点击「发现」tab：不在顶部→回顶；已在顶部→刷新当前 mode
        .onChange(of: tabRouter.reselect) {
            guard tabRouter.reselectedTab == .feed else { return }
            handleReselect()
        }
        // 切换「为你推荐/正在关注」会重建列表（回到顶部），重置标记
        .onChange(of: mode) {
            forYouAtTop = true
            followingAtTop = true
        }
        .task {
            await store.loadIfNeeded()
            if auth.isLoggedIn { await followStore.loadIfNeeded() }
        }
        // 关注集变化时，若正在看「正在关注」流则刷新；否则标记下次进入重拉
        .onChange(of: followStore.keys) {
            Task {
                followingStore.reset()
                if mode == .following { await followingStore.reload() }
            }
        }
        // 登录态切换：换账号/登出清掉关注缓存与关注流，登录后重拉
        .onChange(of: auth.isLoggedIn) { _, loggedIn in
            Task {
                followStore.reset()
                followingStore.reset()
                if loggedIn {
                    await followStore.reload()
                    if mode == .following { await followingStore.reload() }
                }
            }
        }
    }

    // MARK: - 正在关注

    @ViewBuilder
    private var followingContent: some View {
        if !auth.isLoggedIn {
            ContentUnavailableView {
                Label("登录后查看关注", systemImage: "person.crop.circle.badge.questionmark")
            } description: {
                Text("关注感兴趣的频道和商家，在这里集中查看他们的更新")
            }
        } else if followStore.isLoaded && !followStore.hasAnyFollow {
            ContentUnavailableView {
                Label("还没有关注任何对象", systemImage: "heart")
            } description: {
                Text("在内容详情页关注频道、在店铺页关注商家，更新会出现在这里")
            }
        } else {
            feedScroll(followingStore, position: $followingPosition, atTop: $followingAtTop)
                .task { await followingStore.loadIfNeeded() }
        }
    }

    // MARK: - 流渲染（forYou / following 共用）

    // 紧凑宽度（iPhone）单列；常规宽度（iPad）按容器宽度分多列瀑布流。
    @ViewBuilder
    private func feedScroll(_ store: FeedStore, position: Binding<ScrollPosition>, atTop: Binding<Bool>) -> some View {
        if store.isLoading && store.items.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.items.isEmpty, let err = store.errorMessage {
            ContentUnavailableView(err, systemImage: "wifi.exclamationmark")
        } else if store.items.isEmpty {
            ContentUnavailableView("暂无内容", systemImage: "newspaper")
        } else {
            GeometryReader { proxy in
                let columns = feedColumnCount(width: proxy.size.width)
                ScrollView {
                    // 手动刷新（已在顶部再点 tab）时顶部露出转圈，内容随之下移
                    if isRefreshing {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    if columns <= 1 {
                        verticalList(store)
                    } else {
                        masonry(store, columns: columns)
                    }
                    loadMoreFooter(store)
                }
                .scrollPosition(position)
                // 顶部静止时 contentOffset.y == -contentInsets.top，下滑后增大 → 判定是否在顶
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.contentOffset.y <= -geo.contentInsets.top + 1
                } action: { _, newAtTop in
                    atTop.wrappedValue = newAtTop
                }
                .refreshable { await store.reload() }
            }
        }
    }

    // 重复点击「发现」tab 的响应：不在顶部→平滑回顶；已在顶部→刷新当前 mode 的流（顶部转圈）
    private func handleReselect() {
        let isTop = (mode == .forYou) ? forYouAtTop : followingAtTop
        if isTop {
            let target = (mode == .forYou) ? store : followingStore
            Task {
                isRefreshing = true
                let start = Date()
                await target.reload()
                // 保证转圈至少可见 0.5s（数据秒回时也给「已刷新」的明确反馈，对齐 X）
                let elapsed = Date().timeIntervalSince(start)
                if elapsed < 0.5 { try? await Task.sleep(for: .seconds(0.5 - elapsed)) }
                isRefreshing = false
            }
        } else {
            withAnimation {
                if mode == .forYou {
                    forYouPosition.scrollTo(edge: .top)
                } else {
                    followingPosition.scrollTo(edge: .top)
                }
            }
        }
    }

    // regular 宽度按 ~320pt 目标列宽算列数（至少 2 列）；compact 永远单列
    private func feedColumnCount(width: CGFloat) -> Int {
        guard hSizeClass == .regular, width > 0 else { return 1 }
        return max(2, Int(width / 320))
    }

    // 单列：原 iPhone 列表（卡片间 Divider）
    private func verticalList(_ store: FeedStore) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(store.items) { item in
                feedCardLink(item)
                    .onAppear { triggerLoadMoreIfLast(store, item: item) }
                Divider()
            }
        }
    }

    // 瀑布流：items 按 index 轮转分到各列，每列独立 LazyVStack 紧凑堆叠（高低错落无空白）
    private func masonry(_ store: FeedStore, columns: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(0..<columns, id: \.self) { col in
                LazyVStack(spacing: 12) {
                    ForEach(columnItems(store.items, column: col, of: columns)) { item in
                        feedCardLink(item)
                            .onAppear { triggerLoadMoreIfLast(store, item: item) }
                    }
                }
            }
        }
        .padding(12)
    }

    private func columnItems(_ items: [FeedItem], column: Int, of columns: Int) -> [FeedItem] {
        items.enumerated().compactMap { $0.offset % columns == column ? $0.element : nil }
    }

    // 卡片 + 跳转 + 曝光/点击埋点（单列与瀑布流共用）
    @ViewBuilder
    private func feedCardLink(_ item: FeedItem) -> some View {
        NavigationLink {
            destination(for: item)
        } label: {
            FeedCard(item: item)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded {
            FeedImpressionTracker.shared.click(item.id)
        })
        .onAppear { FeedImpressionTracker.shared.impression(item.id) }
    }

    // 翻页触发：最后一条 cell 出现时拉下一页。放在 LazyVStack 内（懒加载、随滚动可靠地
    // 重复触发）—— 不再依赖 footer ProgressView 的 onAppear：那是 ScrollView 的非懒加载
    // 直接子节点，onAppear 只 fire 有限次后就不再触发，曾致翻页加载 ~3 页后永久卡死
    // （spinner 一直转、下面的内容加载不出来）。loadMore 内部已有 canLoadMore/isLoadingMore
    // 守卫，重复触发安全。
    private func triggerLoadMoreIfLast(_ store: FeedStore, item: FeedItem) {
        guard item.id == store.items.last?.id else { return }
        Task { await store.loadMore() }
    }

    @ViewBuilder
    private func loadMoreFooter(_ store: FeedStore) -> some View {
        if store.canLoadMore {
            Group {
                if store.loadMoreFailed {
                    Button {
                        Task { await store.loadMore() }
                    } label: {
                        Label("加载失败，点击重试", systemImage: "arrow.clockwise")
                            .font(.callout)
                    }
                } else {
                    ProgressView()   // 纯视觉指示；翻页触发见 triggerLoadMoreIfLast
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
    }

    // 1.5 source 分流：商家卡→复用商品详情页；内容卡→内容详情页
    @ViewBuilder
    private func destination(for item: FeedItem) -> some View {
        if let code = item.meta?.productCode {
            ProductDetailView(code: code)
        } else {
            FeedDetailView(item: item)
        }
    }
}

// internal：店铺主页动态面（StoreView）复用同一张卡
struct FeedCard: View {
    let item: FeedItem

    private var images: [FeedMedia] {
        item.media.filter { $0.kind == "photo" || $0.kind == "animation" }
    }
    private var hasVideo: Bool { item.media.contains { $0.kind == "video" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: item.source == "merchant" ? "storefront.circle.fill" : "paperplane.circle.fill")
                    .foregroundStyle(item.source == "merchant" ? .orange : .blue)
                Text(item.authorName ?? item.authorHandle ?? "频道")
                    .font(.subheadline).bold()
                    .lineLimit(1)
                if let h = item.authorHandle {
                    Text("@\(h)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(Self.relativeTime(item.publishedAt))
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let text = item.text, !text.isEmpty {
                Text(text).font(.body).lineLimit(8)
            }

            mediaView

            if item.meta?.productCode != nil {   // merchant 可购卡：价格 + 去购买
                HStack(spacing: 4) {
                    if let price = item.meta?.price {
                        Text("¥\(price, specifier: "%.2f")")
                            .font(.headline).foregroundStyle(.orange)
                    }
                    Spacer()
                    Text("去购买").font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
        }
        .padding()
    }

    @ViewBuilder
    private var mediaView: some View {
        if images.count == 1 {
            let m = images[0]
            feedImage(m, mode: .fill)
                .aspectRatio(Self.aspectRatio(m), contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipped()
                .cornerRadius(10)
        } else if images.count > 1 {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                ForEach(images, id: \.url) { m in
                    feedImage(m, mode: .fill)
                        .frame(height: 150)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .cornerRadius(8)
                }
            }
        } else if hasVideo {
            ZStack {
                Rectangle().fill(Color(.systemGray5))
                Image(systemName: "play.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.white)
            }
            .frame(height: 200)
            .frame(maxWidth: .infinity)
            .cornerRadius(10)
        }
    }

    private func feedImage(_ m: FeedMedia, mode: ContentMode) -> some View {
        CachedAsyncImage(url: URL(string: m.url)) { phase in
            switch phase {
            case .success(let img):
                img.resizable().aspectRatio(contentMode: mode)
            case .failure:
                ZStack {
                    Rectangle().fill(Color(.systemGray6))
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            default:
                Rectangle().fill(Color(.systemGray6))
            }
        }
    }

    // 用 media 宽高算比例，限制极端值避免超长图占满屏（无宽高时回退 4:3）
    static func aspectRatio(_ m: FeedMedia) -> CGFloat {
        guard let w = m.width, let h = m.height, w > 0, h > 0 else { return 4.0 / 3.0 }
        return max(0.6, min(CGFloat(w) / CGFloat(h), 1.6))
    }

    // 缓存 Formatter（避免每个 cell 每次刷新都新建）。兼容带/不带小数秒两种 ISO8601。
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let relFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    // ISO8601（带时区，可能含小数秒）→ 相对时间
    static func relativeTime(_ iso: String) -> String {
        guard let date = isoFractional.date(from: iso) ?? isoPlain.date(from: iso) else { return "" }
        return relFormatter.localizedString(for: date, relativeTo: Date())
    }
}
