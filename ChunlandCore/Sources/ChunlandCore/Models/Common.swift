import Foundation

// MARK: - API Response Envelope

public struct APIResponse<T: Decodable>: Decodable, @unchecked Sendable {
    public let code: Int
    public let message: String
    public let data: T?
}

// MARK: - Pagination

public struct Pagination: Decodable, Sendable {
    public let page: Int
    public let limit: Int
    public let total: Int
    public let totalPages: Int
}
