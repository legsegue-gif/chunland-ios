import Foundation

/// 举报服务。POST /reports 需登录（APIClient 自动带 token）。
public actor ReportService {
    public static let shared = ReportService()
    private let api = APIClient.shared

    /// 提交举报。`snapshot` 仅 AI 举报传（被举报回复文本快照）；`targetKey` 对 general/aiMessage 可空。
    public func submit(
        targetType: ReportTargetType,
        targetKey: String?,
        reason: ReportReason,
        detail: String?,
        snapshot: String? = nil
    ) async throws {
        struct Body: Encodable {
            let targetType: String
            let targetKey: String?
            let reasonCode: String
            let detail: String?
            let snapshot: String?
        }
        struct Ack: Decodable { let id: Int }

        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let _: Ack = try await api.post("/reports", body: Body(
            targetType: targetType.rawValue,
            targetKey: targetKey,
            reasonCode: reason.rawValue,
            detail: (trimmedDetail?.isEmpty == false) ? trimmedDetail : nil,
            snapshot: snapshot
        ))
    }
}
