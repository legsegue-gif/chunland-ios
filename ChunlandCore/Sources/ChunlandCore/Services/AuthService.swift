import Foundation

public actor AuthService {
    public static let shared = AuthService()
    private let api = APIClient.shared

    public func me() async throws -> UserProfile {
        try await api.get("/auth/me")
    }
}
