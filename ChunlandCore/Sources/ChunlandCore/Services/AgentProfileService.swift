import Foundation

public actor AgentProfileService {
    public static let shared = AgentProfileService()
    private let api = APIClient.shared

    public func fetch() async throws -> AgentProfile {
        try await api.get("/agent-profile")
    }

    // 工作台聚合：待办计数 + 收入汇总，一次请求供首屏。
    public func dashboard() async throws -> AgentDashboard {
        try await api.get("/agent-profile/dashboard")
    }

    // 合并采购清单：按商家分组、同商品跨单聚合。
    public func purchaseList() async throws -> PurchaseList {
        try await api.get("/agent-profile/purchase-list")
    }

    // 坐标上报：供大厅距离在未配服务区时兜底。节流由调用方负责（reportLocationIfDue）。
    public func reportLocation(lat: Double, lng: Double) async throws {
        struct Body: Encodable { let lastLat: Double; let lastLng: Double }
        let _: AgentProfile = try await api.patch("/agent-profile", body: Body(lastLat: lat, lastLng: lng))
    }

    /// 静默上报当前坐标（15 分钟节流 + 仅已授权定位，不弹窗、失败无感）。
    /// 挂在工作台/大厅出现时调用 —— 让「距离」对没配服务区的代购人也能工作。
    public func reportLocationIfDue() async {
        let key = "agent_location_reported_at"
        let last = UserDefaults.standard.double(forKey: key)
        guard Date().timeIntervalSince1970 - last > 15 * 60 else { return }
        guard let coord = await LocationService.shared.coordinateIfAuthorized() else { return }
        do {
            try await reportLocation(lat: coord.lat, lng: coord.lng)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)
        } catch {
            // 静默路径：失败不打扰（下次进入再试）
        }
    }

    public func update(serviceFee: Int? = nil, bio: String? = nil, isAvailable: Bool? = nil,
                       serviceAreaCodes: [String]? = nil) async throws -> AgentProfile {
        struct Body: Encodable {
            let serviceFee: Int?
            let bio: String?
            let isAvailable: Bool?
            let serviceAreaCodes: [String]?
        }
        return try await api.patch(
            "/agent-profile",
            body: Body(serviceFee: serviceFee, bio: bio, isAvailable: isAvailable, serviceAreaCodes: serviceAreaCodes)
        )
    }
}
