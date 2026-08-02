import Foundation

public struct AIConfig: Decodable, Sendable {
    public let provider: String
    public let baseUrl: String
    public let model: String

    public init(provider: String, baseUrl: String, model: String) {
        self.provider = provider
        self.baseUrl = baseUrl
        self.model = model
    }
}
