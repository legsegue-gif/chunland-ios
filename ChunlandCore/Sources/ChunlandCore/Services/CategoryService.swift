import Foundation

public actor CategoryService {
    public static let shared = CategoryService()
    private let api = APIClient.shared

    /// 分类树。
    ///
    /// `withCounts` 给 AI 用：一并返回每个分类的在售商品数（父节点含子节点），
    /// 模型就不会推荐一个空分类再查一次发现没货。
    public func tree(merchant: Int? = nil, withCounts: Bool = false) async throws -> [Category] {
        var query: [String] = []
        if let merchant { query.append("merchant=\(merchant)") }
        if withCounts { query.append("withCounts=true") }
        let path = query.isEmpty ? "/categories" : "/categories?" + query.joined(separator: "&")
        return try await api.get(path)
    }
}
