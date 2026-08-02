import Foundation

// 商家列表服务（store picker）。无需 token —— /merchants 是公开端点。
public actor MerchantService {
    public static let shared = MerchantService()
    private let api = APIClient.shared

    /// anchor = 用户所在市/区县 region code（可选）。传了则每家店附 distanceKm（server 与报价同口径计算），
    /// 并回显 anchor 所属市（顶栏显示名以 server 解析为准）。
    public func list(anchor: String? = nil) async throws -> (items: [Merchant], anchor: MerchantListAnchor?) {
        struct Resp: Decodable { let items: [Merchant]; let anchor: MerchantListAnchor? }
        let path = anchor.map { "/merchants?anchor=\($0)" } ?? "/merchants"
        let resp: Resp = try await api.get(path)
        return (resp.items, resp.anchor)
    }

    /// 进店页可见分类方案（lens，公开）。空数组 = 该店没有自定义视角。
    public func publicSchemes(merchant: Int) async throws -> [CategoryScheme] {
        let page: CategorySchemePage = try await api.get("/merchants/\(merchant)/schemes")
        return page.items
    }
}
