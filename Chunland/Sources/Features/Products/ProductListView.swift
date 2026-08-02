import SwiftUI
import ChunlandCore

/// 商品网格列定义：紧凑宽度（iPhone 竖屏 / iPad 窄分屏）固定 2 列；常规宽度（iPad 全屏）
/// 用 adaptive 排多列大图。避免进店页左侧 84pt 分类栏挤占商品区后，在 iPhone 窄屏退化成 1 列。
func productGridColumns(for sizeClass: UserInterfaceSizeClass?, spacing: CGFloat) -> [GridItem] {
    sizeClass == .regular
        ? [GridItem(.adaptive(minimum: 180), spacing: spacing)]
        : [GridItem(.flexible(), spacing: spacing), GridItem(.flexible(), spacing: spacing)]
}

struct ProductListView: View {
    @State private var items: [ProductSummary] = []
    @State private var page = 1
    @State private var totalPages = 1
    @State private var isLoading = false
    @State private var keyword = ""
    @State private var searchText = ""
    @State private var error: String?
    @Environment(\.horizontalSizeClass) private var hSizeClass

    let category: String?
    let title: String

    init(category: String? = nil, title: String = "商品") {
        self.category = category
        self.title = title
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && items.isEmpty {
                    ProgressView()
                } else if let error {
                    ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
                } else {
                    ScrollView {
                        LazyVGrid(columns: productGridColumns(for: hSizeClass, spacing: 12), spacing: 12) {
                            ForEach(items) { product in
                                NavigationLink(destination: ProductDetailView(code: product.code)) {
                                    ProductCard(product: product)
                                }
                                .buttonStyle(.plain)
                            }
                            if page < totalPages {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                                    .onAppear { Task { await loadMore() } }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle(title)
            .searchable(text: $searchText, prompt: "搜索商品")
            .onSubmit(of: .search) {
                keyword = searchText
                Task { await reload() }
            }
            .onChange(of: searchText) { _, new in
                if new.isEmpty { keyword = ""; Task { await reload() } }
            }
            .task { await reload() }
        }
    }

    private func reload() async {
        page = 1
        items = []
        await load()
    }

    private func loadMore() async {
        guard page < totalPages else { return }
        page += 1
        await load()
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        do {
            let resp = try await ProductService.shared.list(
                category: category,
                keyword: keyword.isEmpty ? nil : keyword,
                page: page
            )
            // 按 code 去重再累加（ProductSummary.id == code）：ForEach 重复 id 会让
            // SwiftUI 渲染错乱、cell 空白（即"图片消失"）。详见 StoreView 同名守卫。
            var seen = Set(items.map(\.code))
            items += resp.items.filter { seen.insert($0.code).inserted }
            totalPages = resp.pagination.totalPages
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

struct ProductCard: View {
    let product: ProductSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 商品图固定 1:1 正方形：Color 盒子用 aspectRatio(1,.fit) 在列宽下产生方框，
            // 图片 scaledToFill 填满后由 clipped 裁到正方形。卡片高度 = 方图 + 文字，
            // 随列宽自适应；不再用 frame(height:) 硬压（那会与 aspectRatio 打架，在 iPad
            // 宽列下把卡片撑成大正方形，令 NavigationLink 命中区膨胀重叠、只有中间可点）。
            Color(.systemGray5)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    CachedAsyncImage(url: URL(string: product.thumbnail ?? "")) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color(.systemGray5)
                    }
                }
                .clipped()
                .cornerRadius(8)

            Text(product.name)
                .font(.caption)
                .lineLimit(2)
                .foregroundStyle(.primary)

            HStack(alignment: .firstTextBaseline) {
                Text("¥\(product.currentPrice?.description ?? "-")")
                    .font(.subheadline).bold()
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                stockBadge(tier: product.stockTier)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func stockBadge(tier: StockTier) -> some View {
        switch tier {
        case .lowStock:
            Text("少量")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .outOfStock:
            Text("售罄")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .inStock, .unknown:
            EmptyView()
        }
    }
}
