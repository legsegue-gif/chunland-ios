import Foundation

public actor CategoryService {
    public static let shared = CategoryService()
    private let api = APIClient.shared

    public func tree(merchant: Int? = nil) async throws -> [Category] {
        let path = merchant.map { "/categories?merchant=\($0)" } ?? "/categories"
        return try await api.get(path)
    }
}
