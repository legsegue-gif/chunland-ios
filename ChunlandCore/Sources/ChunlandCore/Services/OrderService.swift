import Foundation

public actor OrderService {
    public static let shared = OrderService()
    private let api = APIClient.shared

    public func placeOrder(deliveryAddress: DeliveryAddress, productCodes: [String]? = nil, deliveryNote: String? = nil, remark: String? = nil) async throws -> CheckoutBatch {
        struct Body: Encodable {
            let deliveryAddress: DeliveryAddress
            let productCodes: [String]?
            let deliveryNote: String?
            let remark: String?
        }
        return try await api.post("/orders", body: Body(deliveryAddress: deliveryAddress, productCodes: productCodes, deliveryNote: deliveryNote, remark: remark))
    }

    // 报价（dry-run，不建单）：选中商品 + 收货区县 → 含距离代购费的费用分解。结算页选地址后预览精确总额。
    public func quote(areaCode: String?, productCodes: [String]? = nil) async throws -> OrderQuote {
        struct Body: Encodable {
            let areaCode: String?
            let productCodes: [String]?
        }
        return try await api.post("/orders/quote", body: Body(areaCode: areaCode, productCodes: productCodes))
    }

    public func list(status: String? = nil, scope: String? = nil, sort: String? = nil) async throws -> [OrderSummary] {
        var qs: [String] = []
        if let s = status { qs.append("status=\(s)") }
        if let s = scope { qs.append("scope=\(s)") }
        if let s = sort { qs.append("sort=\(s)") }   // hall 专用："distance" = 按最近距离（A2）
        let path = qs.isEmpty ? "/orders" : "/orders?\(qs.joined(separator: "&"))"
        return try await api.get(path)
    }

    public func detail(id: Int) async throws -> OrderDetail {
        try await api.get("/orders/\(id)")
    }

    public func claim(orderId: Int) async throws -> OrderSummary {
        struct Empty: Encodable {}
        return try await api.post("/orders/\(orderId)/claim", body: Empty())
    }

    public func updateStatus(orderId: Int, status: String) async throws {
        struct Body: Encodable { let status: String }
        struct Resp: Decodable { let id: Int; let status: String }
        let _: Resp = try await api.patch("/orders/\(orderId)/status", body: Body(status: status))
    }
}
