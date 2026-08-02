import Foundation

// 公开配置服务（费率 / 起送金额）。无需 token —— 服务端 /config/* 是公开端点。
public actor ConfigService {
    public static let shared = ConfigService()
    private let api = APIClient.shared

    public func getCheckout(merchant: Int? = nil) async throws -> CheckoutConfig {
        let path = merchant.map { "/config/checkout?merchant=\($0)" } ?? "/config/checkout"
        return try await api.get(path)
    }
}
