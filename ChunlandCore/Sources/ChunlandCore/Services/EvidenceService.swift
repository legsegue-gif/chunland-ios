import Foundation

// 采购凭证。上传走 raw image 二进制，读图经鉴权代理（带 token 拉 bytes）。
public actor EvidenceService {
    public static let shared = EvidenceService()
    private let api = APIClient.shared

    public func list(orderId: Int) async throws -> [OrderEvidence] {
        try await api.get("/orders/\(orderId)/evidence")
    }

    /// agent 上传凭证（默认小票）。jpeg 为已编码的 JPEG bytes。
    public func upload(orderId: Int, kind: String = "receipt", jpeg: Data) async throws -> OrderEvidence {
        try await api.postData("/orders/\(orderId)/evidence?kind=\(kind)", data: jpeg, contentType: "image/jpeg")
    }

    /// 鉴权拉取凭证图片 bytes（用 id 拼路径，不依赖服务端返回的绝对 url）。
    public func imageData(orderId: Int, evidenceId: Int) async throws -> Data {
        try await api.getData("/orders/\(orderId)/evidence/\(evidenceId)/raw")
    }
}
