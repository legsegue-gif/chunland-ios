import Foundation

// 资金结算。代购人查看自己的待结算账 + 收益聚合。
public actor SettlementService {
    public static let shared = SettlementService()
    private let api = APIClient.shared

    public func mine() async throws -> SettlementSummary {
        try await api.get("/agent-profile/settlements")
    }
}
