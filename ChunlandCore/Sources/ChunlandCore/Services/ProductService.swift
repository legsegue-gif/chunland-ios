import Foundation

/// 商品排序。与服务端 `productRepo.SORT_CLAUSES` 的键一一对应。
public enum ProductSort: String, Sendable, CaseIterable {
    /// 默认：有货优先 → 有折扣 → 折扣大 → 价格低
    case relevance
    case priceAsc = "price_asc"
    case priceDesc = "price_desc"
    case discount
    case newest
}

public actor ProductService {
    public static let shared = ProductService()
    private let api = APIClient.shared

    /// 商品列表 / 结构化查询。
    ///
    /// 后半段参数是给 AI 的结构化查询能力 —— 模型能一次问对
    /// 「100 元以内、有货、按价格从低到高」，不必翻页人工筛。
    /// 服务端对越界参数一律静默归一化（超限截断、区间倒置纠正、未知排序回默认），
    /// 不会因为一个 limit=1000 就报错让模型白烧一轮。
    public func list(merchant: Int? = nil, category: String? = nil, schemeCategory: Int? = nil,
                     keyword: String? = nil, page: Int = 1, limit: Int = 20,
                     priceMin: Double? = nil, priceMax: Double? = nil,
                     inStockOnly: Bool = false, sort: ProductSort? = nil,
                     compact: Bool = false, withStats: Bool = false) async throws -> ProductListResponse {
        var query = "?page=\(page)&limit=\(limit)"
        if let m = merchant { query += "&merchant=\(m)" }
        if let c = category { query += "&category=\(c)" }
        if let sc = schemeCategory { query += "&schemeCategory=\(sc)" }   // M5 lens 视角过滤
        if let k = keyword, let encoded = k.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            query += "&keyword=\(encoded)"
        }
        if let priceMin { query += "&priceMin=\(priceMin)" }
        if let priceMax { query += "&priceMax=\(priceMax)" }
        if inStockOnly { query += "&inStock=true" }
        if let sort { query += "&sort=\(sort.rawValue)" }
        if compact { query += "&fields=compact" }
        if withStats { query += "&withStats=true" }
        return try await api.get("/products\(query)")
    }

    public func detail(code: String) async throws -> ProductDetail {
        try await api.get("/products/\(code)")
    }

    /// 当前用户的画像片段（默认收货地区 + 近三个月常买品类），供拼进 AI 的 system prompt。
    ///
    /// 只聚合用户自己已有的数据，不新增采集。没有可说的内容时返回 nil ——
    /// 调用方不注入，而不是注入一句「暂无信息」白占 token。
    public func profileFragment() async throws -> String? {
        struct Wrapper: Decodable { let fragment: String? }
        let wrapper: Wrapper = try await api.get("/products/profile-fragment")
        guard let fragment = wrapper.fragment, !fragment.isEmpty else { return nil }
        return fragment
    }
}
