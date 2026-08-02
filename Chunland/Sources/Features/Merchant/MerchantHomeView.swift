import SwiftUI
import ChunlandCore

// 商家「店铺」tab：店铺信息 + 自家商品管理（含已下架）。
// 左滑上/下架；点行编辑；➕ 建品。零资金流 —— 本页只管商品，不涉收款。
struct MerchantHomeView: View {
    @State private var store: MyStore?
    @State private var products: [MerchantProduct] = []
    @State private var stats: MerchantStats?
    @State private var hasLoaded = false
    @State private var error: String?
    @State private var showCreate = false
    @State private var editTarget: MerchantProduct?
    @State private var toast: String?
    @Environment(\.horizontalSizeClass) private var hSizeClass

    var body: some View {
        Group {
            if !hasLoaded {
                ProgressView()
            } else if let error, store == nil {
                ScrollView {
                    ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
                        .containerRelativeFrame([.horizontal, .vertical])
                }
                .refreshable { await load() }
            } else {
                content
            }
        }
        .frame(maxWidth: hSizeClass == .regular ? 720 : .infinity)
        .frame(maxWidth: .infinity)
        .navigationTitle(store?.name ?? "我的店铺")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // AI 分类：✨ 店铺助手（生成分类方案/批量归类，mutation 走确认）
            ToolbarItem(placement: .topBarTrailing) {
                AskAIButton(context: .merchantConsole(storeName: store?.name))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCreate = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("新增商品")
            }
        }
        .sheet(isPresented: $showCreate) {
            ProductFormView(product: nil) { await load() }
        }
        .sheet(item: $editTarget) { p in
            ProductFormView(product: p) { await load() }
        }
        .overlay(alignment: .top) { toastView }
        .task { await load() }
        .onAppear {
            if hasLoaded { Task { await load() } }
        }
    }

    private var content: some View {
        List {
            if let store {
                Section("店铺") {
                    LabeledContent("店铺名", value: store.name)
                    LabeledContent("在售商品", value: "\(products.filter(\.purchasable).count) / \(products.count)")
                    NavigationLink(destination: StoreSettingsView(store: store) { await load() }) {
                        Label("店铺设置", systemImage: "gearshape")
                    }
                    NavigationLink(destination: MerchantPostsView()) {
                        Label("店铺动态", systemImage: "megaphone")
                    }
                    NavigationLink(destination: SchemeManageView()) {
                        Label("分类方案", systemImage: "square.grid.3x1.below.line.grid.1x2")
                    }
                    if store.areaCode == nil {
                        Text("尚未设置发货地，下单时距离代购费按 0 计")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
            }
            statsSection
            Section("商品") {
                if products.isEmpty {
                    Text("还没有商品，点右上角 ➕ 上架第一件")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(products) { p in
                        productRow(p)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
    }

    private func productRow(_ p: MerchantProduct) -> some View {
        Button { editTarget = p } label: {
            HStack(spacing: 10) {
                CachedAsyncImage(url: URL(string: p.thumbnail ?? "")) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color(.systemGray5).overlay {
                        Image(systemName: "photo").foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.name)
                        .font(.subheadline)
                        .lineLimit(2)
                        .foregroundStyle(p.purchasable ? .primary : .secondary)
                    if let price = p.price {
                        Text("¥\(price.description)")
                            .font(.caption).bold()
                            .foregroundStyle(p.purchasable ? Color.accentColor : .secondary)
                    }
                }
                Spacer()
                if !p.purchasable {
                    Text("已下架")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .foregroundStyle(.secondary)
                        .clipShape(Capsule())
                }
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(p.purchasable ? "下架" : "上架") {
                Task { await togglePurchasable(p) }
            }
            .tint(p.purchasable ? .orange : .green)
        }
    }

    // 经营数据：累计/近30天 + 热销 top3
    @ViewBuilder
    private var statsSection: some View {
        if let stats {
            Section("经营数据") {
                HStack {
                    statCell("累计订单", "\(stats.totalOrders)")
                    Divider()
                    statCell("累计成交", "¥\(money(stats.gmv))")
                }
                HStack {
                    statCell("近30天订单", "\(stats.last30dOrders)")
                    Divider()
                    statCell("近30天成交", "¥\(money(stats.last30dGmv))")
                }
                if !stats.topProducts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("热销商品").font(.caption).foregroundStyle(.secondary)
                        ForEach(stats.topProducts.prefix(3)) { t in
                            HStack {
                                Text(t.name).font(.caption).lineLimit(1)
                                Spacer()
                                Text("×\(t.qty)").font(.caption).bold().foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func statCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline).bold()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func money(_ d: Decimal) -> String {
        String(format: "%.2f", NSDecimalNumber(decimal: d).doubleValue)
    }

    private func togglePurchasable(_ p: MerchantProduct) async {
        do {
            _ = try await MerchantConsoleService.shared.updateProduct(code: p.code, purchasable: !p.purchasable)
            await load()
            showToast(p.purchasable ? "已下架" : "已上架")
        } catch {
            showToast("操作失败：\(error.localizedDescription)")
        }
    }

    private func load() async {
        error = nil
        do {
            async let storeTask = MerchantConsoleService.shared.myStore()
            async let productsTask = MerchantConsoleService.shared.products()
            async let statsTask = MerchantConsoleService.shared.stats()
            let (s, ps, st) = try await (storeTask, productsTask, statsTask)
            store = s
            products = ps
            stats = st
        } catch {
            self.error = error.localizedDescription
        }
        hasLoaded = true
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func showToast(_ msg: String) {
        withAnimation { toast = msg }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run { if toast == msg { withAnimation { toast = nil } } }
        }
    }
}
