import SwiftUI
import ChunlandCore

private typealias ProductCategory = ChunlandCore.Category

// 进店页：分类 + 商品都按 merchant 过滤。
// 布局按分类树形状自适应：
//   - 有子级（层级导航树）→ 左侧栏 L1 + 顶部 L2 chips + 商品网格
//   - 全平铺（szwego 品牌）→ 顶部品牌 chips + 全宽商品网格
//   - 方案视角（lens）→ 左侧方案分类栏 + 商品网格（恒定侧栏，与层级布局同型）
struct StoreView: View {
    let merchant: Merchant

    @Environment(\.horizontalSizeClass) private var hSizeClass

    @State private var categories: [ProductCategory] = []
    @State private var selectedL1: ProductCategory?   // nil = 全部
    @State private var selectedL2: ProductCategory?

    @State private var items: [ProductSummary] = []
    @State private var page = 1
    @State private var totalPages = 1
    @State private var isLoadingProducts = false
    @State private var error: String?

    @State private var showSearch = false
    @State private var face: StoreFace = .products    // M4 店铺主页两个面

    // lens：分类方案视角。activeScheme == nil → 官方分类（既有 hierarchical/brand 布局）
    @State private var schemes: [CategoryScheme] = []
    @State private var activeScheme: CategoryScheme?
    @State private var selectedSchemeCat: CategoryScheme.Cat?    // 侧栏选中的一级
    @State private var selectedSchemeL2: CategoryScheme.Cat?     // 一级下选中的二级（chips）

    private var isHierarchical: Bool { categories.contains { !$0.children.isEmpty } }

    enum StoreFace { case products, posts }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $face) {
                Text("商品").tag(StoreFace.products)
                Text("动态").tag(StoreFace.posts)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Group {
                switch face {
                case .products:
                    if !schemes.isEmpty { viewModeBar }
                    if let scheme = activeScheme {
                        schemeBody(scheme)
                    } else if isHierarchical {
                        hierarchicalBody
                    } else {
                        brandBody
                    }
                case .posts:
                    StorePostsList(merchantId: merchant.id)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(merchant.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                FollowButton(type: .merchant, key: String(merchant.id))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSearch = true } label: {
                    Image(systemName: "magnifyingglass")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                AskAIButton(context: .store(merchantId: merchant.id, merchantName: merchant.name))
            }
        }
        .task {
            MerchantStore.shared.currentMerchant = merchant
            await ConfigStore.shared.loadIfNeeded(merchant: merchant.id)
            if schemes.isEmpty { await loadSchemes() }   // 先于首屏商品：默认方案决定初始视角
            if categories.isEmpty { await loadCategories() }
            if items.isEmpty { await reload() }
        }
        .sheet(isPresented: $showSearch) {
            StoreSearchSheet(merchant: merchant)
        }
    }

    // MARK: - 分类方案视角（lens）

    /// 视角切换行：官方分类（有则显示）与各方案之间切换
    private var viewModeBar: some View {
        HStack {
            Menu {
                Picker("视角", selection: Binding(
                    get: { activeScheme?.id ?? -1 },
                    set: { newId in switchViewMode(schemeId: newId) }
                )) {
                    ForEach(schemes) { s in
                        Label(s.name, systemImage: "square.grid.2x2").tag(s.id)
                    }
                    // 官方分类视角（无 legacy 分类的自建店 = 「全部商品」）
                    Label(categories.isEmpty ? "全部商品" : "官方分类", systemImage: "list.bullet").tag(-1)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text(activeScheme?.name ?? (categories.isEmpty ? "全部商品" : "官方分类"))
                        .font(.footnote.weight(.medium))
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .foregroundStyle(Color.accentColor)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func switchViewMode(schemeId: Int) {
        activeScheme = schemes.first { $0.id == schemeId }   // -1 → nil = 官方视角
        selectedSchemeCat = nil
        selectedSchemeL2 = nil
        selectedL1 = nil
        selectedL2 = nil
        Task { await reload() }
    }

    /// 方案视角布局：左侧方案分类栏 + 商品网格（恒定侧栏，与官方层级布局同型）。
    /// 一级有二级时顶部出 L2 chips（选一级 = 本级 + 全部二级，服务端展开）。
    private func schemeBody(_ scheme: CategoryScheme) -> some View {
        HStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    sidebarItem(name: "全部", isSelected: selectedSchemeCat == nil) {
                        selectedSchemeCat = nil
                        selectedSchemeL2 = nil
                        Task { await reload() }
                    }
                    ForEach(scheme.categories) { cat in
                        sidebarItem(name: cat.name, isSelected: selectedSchemeCat?.id == cat.id) {
                            selectedSchemeCat = cat
                            selectedSchemeL2 = nil
                            Task { await reload() }
                        }
                    }
                }
            }
            .frame(width: 84)
            .background(Color(.systemGroupedBackground))
            Divider()
            VStack(spacing: 0) {
                if let l1 = selectedSchemeCat, !l1.subcategories.isEmpty {
                    schemeL2Strip(children: l1.subcategories)
                    Divider()
                }
                productArea
            }
        }
    }

    private func schemeL2Strip(children: [CategoryScheme.Cat]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(name: "全部", isSelected: selectedSchemeL2 == nil) {
                    selectedSchemeL2 = nil
                    Task { await reload() }
                }
                ForEach(children) { sub in
                    chip(name: sub.name, isSelected: selectedSchemeL2?.id == sub.id) {
                        selectedSchemeL2 = sub
                        Task { await reload() }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private func loadSchemes() async {
        schemes = (try? await MerchantService.shared.publicSchemes(merchant: merchant.id)) ?? []
        // 默认方案 = 进店初始视角（服务端已把默认排最前）
        activeScheme = schemes.first { $0.isDefault }
    }

    // MARK: - Hierarchical

    private var hierarchicalBody: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                if let l1 = selectedL1, !l1.children.isEmpty {
                    l2Strip(children: l1.children)
                    Divider()
                }
                productArea
            }
        }
    }

    private var sidebar: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 0) {
                sidebarItem(name: "全部", isSelected: selectedL1 == nil) { selectAll() }
                ForEach(categories) { cat in
                    sidebarItem(name: cat.name, isSelected: selectedL1?.code == cat.code) {
                        select(l1: cat)
                    }
                }
            }
        }
        .frame(width: 84)
        .background(Color(.systemGroupedBackground))
    }

    private func sidebarItem(name: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                if isSelected {
                    Rectangle().fill(Color.accentColor).frame(width: 3)
                }
                Text(name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 6)
                    .background(isSelected ? Color(.systemBackground) : Color.clear)
            }
        }
        .buttonStyle(.plain)
    }

    private func l2Strip(children: [ProductCategory]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(name: "全部", isSelected: selectedL2 == nil) {
                    selectedL2 = nil
                    Task { await reload() }
                }
                ForEach(children) { l2 in
                    chip(name: l2.name, isSelected: selectedL2?.code == l2.code) {
                        selectedL2 = l2
                        Task { await reload() }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Brand (szwego)

    private var brandBody: some View {
        VStack(spacing: 0) {
            if !categories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip(name: "全部", isSelected: selectedL1 == nil) { selectAll() }
                        ForEach(categories) { brand in
                            chip(name: brand.name, isSelected: selectedL1?.code == brand.code) {
                                select(l1: brand)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                Divider()
            }
            productArea
        }
    }

    private func chip(name: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(name)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color(.systemGray6))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Product grid

    private var productArea: some View {
        Group {
            if isLoadingProducts && items.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error, items.isEmpty {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            } else if items.isEmpty {
                ContentUnavailableView("暂无商品", systemImage: "tray")
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: productGridColumns(for: hSizeClass, spacing: 8),
                        spacing: 8
                    ) {
                        ForEach(items) { product in
                            NavigationLink(destination: ProductDetailView(code: product.code)) {
                                ProductCard(product: product)
                            }
                            .buttonStyle(.plain)
                        }
                        if page < totalPages {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .gridCellColumns(2)
                                .padding(.vertical, 8)
                                .onAppear { Task { await loadMore() } }
                        }
                    }
                    .padding(8)
                }
                .refreshable { await reload() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data

    private func loadCategories() async {
        do {
            let tree = try await CategoryService.shared.tree(merchant: merchant.id)
            categories = tree
                .filter { $0.level == 1 }
                .sorted { ($0.sequence ?? 999) < ($1.sequence ?? 999) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func selectAll() {
        selectedL1 = nil
        selectedL2 = nil
        Task { await reload() }
    }

    private func select(l1: ProductCategory) {
        selectedL1 = l1
        selectedL2 = nil
        Task { await reload() }
    }

    private func reload() async {
        page = 1
        items = []
        error = nil
        await load()
    }

    private func loadMore() async {
        guard page < totalPages, !isLoadingProducts else { return }
        page += 1
        await load()
    }

    private func load() async {
        guard !isLoadingProducts else { return }
        isLoadingProducts = true
        let activeCode = selectedL2?.code ?? selectedL1?.code   // nil = 全部
        do {
            // lens：方案视角走 schemeCategory 过滤，官方视角走既有 category
            let resp = try await ProductService.shared.list(
                merchant: merchant.id,
                category: activeScheme == nil ? activeCode : nil,
                schemeCategory: activeScheme != nil ? (selectedSchemeL2 ?? selectedSchemeCat)?.id : nil,
                page: page
            )
            // 按 code 去重再累加：ProductSummary.id == code，ForEach 出现重复 id 会让
            // SwiftUI 身份 diff 错乱、随机把 cell 渲染成空白/错位（即"图片消失"）。
            // 服务端分页已加唯一 tiebreaker，这里再兜一道，防数据在滚动间变动产生瞬时重复。
            var seen = Set(items.map(\.code))
            items += resp.items.filter { seen.insert($0.code).inserted }
            totalPages = resp.pagination.totalPages
        } catch {
            self.error = error.localizedDescription
        }
        isLoadingProducts = false
    }
}

// MARK: - 店内搜索（按 merchant 过滤）

private struct StoreSearchSheet: View {
    let merchant: Merchant

    @State private var localText = ""
    @State private var items: [ProductSummary] = []
    @State private var isLoading = false
    @State private var hasSearched = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSizeClass

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索「\(merchant.name)」商品", text: $localText)
                        .submitLabel(.search)
                        .onSubmit { Task { await search() } }
                    if !localText.isEmpty {
                        Button {
                            localText = ""
                            items = []
                            hasSearched = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)
                .padding(.top, 8)

                Divider().padding(.top, 8)

                Group {
                    if isLoading {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if hasSearched && items.isEmpty {
                        ContentUnavailableView("没有结果", systemImage: "magnifyingglass")
                    } else if !items.isEmpty {
                        ScrollView {
                            LazyVGrid(
                                columns: productGridColumns(for: hSizeClass, spacing: 8),
                                spacing: 8
                            ) {
                                ForEach(items) { product in
                                    NavigationLink(destination: ProductDetailView(code: product.code)) {
                                        ProductCard(product: product)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(8)
                        }
                    } else {
                        Spacer()
                    }
                }
            }
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func search() async {
        let kw = localText.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return }
        isLoading = true
        hasSearched = true
        do {
            let resp = try await ProductService.shared.list(merchant: merchant.id, keyword: kw, page: 1, limit: 30)
            items = resp.items
        } catch {
            items = []
        }
        isLoading = false
    }
}
