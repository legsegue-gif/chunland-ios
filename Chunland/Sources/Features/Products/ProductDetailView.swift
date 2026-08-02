import SwiftUI
import ChunlandCore

struct ProductDetailView: View {
    let code: String
    @State private var product: ProductDetail?
    @State private var isLoading = true
    @State private var error: String?
    @State private var quantity = 1
    @State private var galleryIndex = 0
    @State private var showImageViewer = false
    @State private var selectedSize: String?
    @State private var addingToCart = false
    @State private var toast: String?
    @State private var showReport = false
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var login: LoginCoordinator
    @Environment(\.horizontalSizeClass) private var hSizeClass

    var body: some View {
        ScrollView {
            if isLoading {
                ProgressView().padding(.top, 60)
            } else if let product {
                content(for: product)
            } else if let error {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 收藏（♡/♥）：feed_follows target_type=product，管理在「我的→收藏与关注」
            if product != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    favoriteButton
                }
            }
            if let product {
                ToolbarItem(placement: .topBarTrailing) {
                    AskAIButton(context: .product(code: code, name: product.name))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("举报商品", systemImage: "flag") {
                        login.requireLogin(reason: "登录后即可举报") { showReport = true }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showReport) {
            ReportSheet(targetType: .product, targetKey: code)
        }
        .overlay(alignment: .top) {
            if let toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.subheadline).bold()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.85))
                    .clipShape(Capsule())
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast)
        .task {
            do {
                let p = try await ProductService.shared.detail(code: code)
                product = p
                quantity = orderRange(p).lowerBound   // 起订量对齐（szwego 可能 >1）
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
            // 收藏判态预载（已登录才有关注集；未登录点收藏时 requireLogin 后再加载）
            if auth.isLoggedIn { await FollowStore.shared.loadIfNeeded() }
        }
    }

    // 收藏按钮：读 FollowStore 判态（♥ 实心=已收藏），点击乐观 toggle；未登录先引导登录（intent retry）
    private var favoriteButton: some View {
        let following = FollowStore.shared.isFollowing(type: .product, key: code)
        return Button {
            login.requireLogin(reason: "登录后即可收藏商品") {
                Task {
                    if !FollowStore.shared.isLoaded { await FollowStore.shared.loadIfNeeded() }
                    if let msg = await FollowStore.shared.toggle(type: .product, key: code) {
                        showToast(msg)
                    }
                }
            }
        } label: {
            Image(systemName: following ? "heart.fill" : "heart")
                .foregroundStyle(following ? .red : Color.accentColor)
        }
    }

    // MARK: - Layout

    // 按宽度类别组装：常规宽度（iPad）左图右信息分栏；紧凑宽度（iPhone）单列（图上信息下）。
    @ViewBuilder
    private func content(for product: ProductDetail) -> some View {
        if hSizeClass == .regular {
            HStack(alignment: .top, spacing: 24) {
                gallery(product)
                    .aspectRatio(1, contentMode: .fit)   // 左半正方形大图，随列宽自适应
                    .frame(maxWidth: .infinity)
                infoSection(product)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(24)
            .frame(maxWidth: 1100)            // 超宽屏（iPad 横屏）不过度铺散
            .frame(maxWidth: .infinity)       // 居中
        } else {
            VStack(alignment: .leading, spacing: 0) {
                gallery(product)
                    .frame(height: 300)
                infoSection(product)
                    .padding()
            }
        }
    }

    // 图册：可左右滑的图片轮播；图片 scaledToFit 完整显示。尺寸由调用处按布局决定。
    // 分页指示器仿 Reddit（PageDots 胶囊）；点图打开全屏看图器，页码双向同步。
    private func gallery(_ product: ProductDetail) -> some View {
        let images = product.images.filter { $0.format == "product" }
        // 全屏放大用更大的 zoom 渲染（按 galleryIndex 与 product 配对，缺则回退 product）；
        // 内联图册仍用较轻的 product，滑动更省流量。
        let zoomByIndex = Dictionary(
            product.images.filter { $0.format == "zoom" }.map { ($0.galleryIndex, $0.url) },
            uniquingKeysWith: { first, _ in first }
        )
        let zoomUrls = images.map { zoomByIndex[$0.galleryIndex] ?? $0.url }
        return TabView(selection: $galleryIndex) {
            ForEach(Array(images.enumerated()), id: \.element.galleryIndex) { idx, img in
                AsyncImage(url: URL(string: img.url)) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Rectangle().fill(Color(.systemGray5))
                }
                .tag(idx)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))   // 关原生圆点，改用下方自定义胶囊
        .overlay(alignment: .bottom) {
            if images.count > 1 {                        // 单图不显示指示器
                PageDots(count: images.count, current: galleryIndex)
                    .padding(.bottom, 12)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !images.isEmpty { showImageViewer = true }
        }
        .fullScreenCover(isPresented: $showImageViewer) {
            ImageViewerView(urls: zoomUrls, index: $galleryIndex)
        }
    }

    // 商品信息区：标题 / 价格 / 库存 / 尺码 / 数量 / 加购。自身不带 padding，由调用处决定。
    private func infoSection(_ product: ProductDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(product.name).font(.title3).bold()

            if let en = product.englishName {
                Text(en).font(.caption).foregroundStyle(.secondary)
            }

            // 商品编号（products.code，商家货号）；长按可复制
            Text("编号 \(product.code)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("¥\(product.currentPrice?.description ?? "-")")
                    .font(.title2).bold().foregroundStyle(.red)
                if let orig = product.originalPrice, orig != product.currentPrice {
                    Text("¥\(orig.description)").font(.caption)
                        .strikethrough().foregroundStyle(.secondary)
                }
            }

            if product.randomWeight {
                Label("生鲜商品，按实重计价，以实际结算金额为准", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.orange)
            }

            Divider()

            // szwego 商品可能没有库存/单位信息 —— 两者都缺时整行隐藏，避免空白行
            if hasStockOrUnit(product) {
                HStack {
                    stockLabel(tier: product.stockTier, level: product.stockLevel)
                    Spacer()
                    if let unit = product.unitType, !unit.isEmpty {
                        Text(unit).font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                Divider()
            }

            // 尺码选择（有尺码必选才能加购）
            if let sizes = product.sizes, !sizes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("尺码").font(.subheadline).bold()
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 52), spacing: 8)],
                        alignment: .leading, spacing: 8
                    ) {
                        ForEach(sizes, id: \.self) { size in
                            Button {
                                selectedSize = (selectedSize == size) ? nil : size
                            } label: {
                                Text(size)
                                    .font(.subheadline)
                                    .frame(minWidth: 44)
                                    .padding(.vertical, 8).padding(.horizontal, 6)
                                    .background(selectedSize == size ? Color.accentColor : Color(.systemGray6))
                                    .foregroundStyle(selectedSize == size ? .white : .primary)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Divider()
            }

            // Quantity stepper
            HStack {
                Text("数量")
                Spacer()
                Stepper(value: $quantity, in: orderRange(product)) {
                    Text("\(quantity)").frame(minWidth: 32)
                }
            }

            Button {
                // 游客模式：加购需登录，登录成功后自动续做该加购动作（intent retry）。
                login.requireLogin(reason: "登录后即可加入购物车") {
                    Task { await addToCart(product: product) }
                }
            } label: {
                HStack {
                    if addingToCart {
                        ProgressView().tint(.white)
                    } else {
                        Label(needsSizeSelection(product) ? "请选择尺码" : "加入购物车",
                              systemImage: "cart.badge.plus")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(product.isInStock && !needsSizeSelection(product) ? Color.accentColor : Color.gray)
                .foregroundStyle(.white)
                .cornerRadius(12)
            }
            .disabled(!product.isInStock || addingToCart || needsSizeSelection(product))
        }
    }

    // 有尺码却没选 → 不能加购
    private func needsSizeSelection(_ p: ProductDetail) -> Bool {
        (p.sizes?.isEmpty == false) && selectedSize == nil
    }

    // 起订/限购区间，防止 szwego 数据退化（min>max）导致 Stepper 崩溃
    private func orderRange(_ p: ProductDetail) -> ClosedRange<Int> {
        let lo = max(1, p.minOrderQuantity)
        let hi = max(lo, p.maxOrderQuantity)
        return lo...hi
    }

    // 库存或单位至少有一个可显示
    private func hasStockOrUnit(_ p: ProductDetail) -> Bool {
        if case .unknown = p.stockTier {
            return !(p.unitType ?? "").isEmpty
        }
        return true
    }

    @ViewBuilder
    private func stockLabel(tier: StockTier, level: Int?) -> some View {
        switch tier {
        case .inStock:
            Label("有货", systemImage: "checkmark.circle")
                .foregroundStyle(.green).font(.subheadline)
        case .lowStock:
            let text = level.map { "仅剩 \($0) 件" } ?? "库存紧张"
            Label(text, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange).font(.subheadline)
        case .outOfStock:
            Label("已售罄", systemImage: "xmark.circle")
                .foregroundStyle(.red).font(.subheadline)
        case .unknown:
            EmptyView()
        }
    }

    private func addToCart(product: ProductDetail) async {
        addingToCart = true
        defer { addingToCart = false }
        do {
            try await CartService.shared.addItem(productCode: product.code, quantity: quantity, selectedSize: selectedSize)
            showToast("已加入购物车")
        } catch {
            showToast("加入失败：\(error.localizedDescription)")
        }
    }

    private func showToast(_ msg: String) {
        toast = msg
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { if toast == msg { toast = nil } }
        }
    }
}
