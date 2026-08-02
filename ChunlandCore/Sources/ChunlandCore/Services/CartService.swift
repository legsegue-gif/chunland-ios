import Foundation

public actor CartService {
    public static let shared = CartService()
    private let api = APIClient.shared

    public func get() async throws -> Cart {
        try await api.get("/cart")
    }

    public func addItem(productCode: String, quantity: Int, selectedSize: String? = nil) async throws {
        struct Body: Encodable { let productCode: String; let quantity: Int; let selectedSize: String? }
        struct Resp: Decodable { let id: Int; let quantity: Int }
        let _: Resp = try await api.post("/cart/items", body: Body(productCode: productCode, quantity: quantity, selectedSize: selectedSize))
    }

    public func updateItem(productCode: String, quantity: Int, selectedSize: String? = nil) async throws {
        struct Body: Encodable { let quantity: Int; let selectedSize: String? }
        struct Resp: Decodable { let id: Int; let quantity: Int }
        let _: Resp = try await api.patch("/cart/items/\(productCode)", body: Body(quantity: quantity, selectedSize: selectedSize))
    }

    public func removeItem(productCode: String, selectedSize: String? = nil) async throws {
        var path = "/cart/items/\(productCode)"
        if let s = selectedSize, !s.isEmpty,
           let enc = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "?size=\(enc)"
        }
        try await api.deleteVoid(path)
    }

    public func clear() async throws {
        try await api.deleteVoid("/cart")
    }
}
