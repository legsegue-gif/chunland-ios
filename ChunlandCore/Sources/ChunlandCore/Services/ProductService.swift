import Foundation

public actor ProductService {
    public static let shared = ProductService()
    private let api = APIClient.shared

    public func list(merchant: Int? = nil, category: String? = nil, schemeCategory: Int? = nil,
                     keyword: String? = nil, page: Int = 1, limit: Int = 20) async throws -> ProductListResponse {
        var query = "?page=\(page)&limit=\(limit)"
        if let m = merchant { query += "&merchant=\(m)" }
        if let c = category { query += "&category=\(c)" }
        if let sc = schemeCategory { query += "&schemeCategory=\(sc)" }   // M5 lens 视角过滤
        if let k = keyword, let encoded = k.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            query += "&keyword=\(encoded)"
        }
        return try await api.get("/products\(query)")
    }

    public func detail(code: String) async throws -> ProductDetail {
        try await api.get("/products/\(code)")
    }
}
