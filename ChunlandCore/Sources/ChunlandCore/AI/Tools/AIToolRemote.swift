import Foundation

// MARK: - 服务端工具体的调用侧（R5）
//
// 工具体从端上搬到服务端后，端上只做三件事：把参数发过去、把文本原样喂回模型、
// 把服务端告知的 id 登记进会话 provenance。
//
// **为什么搬**：拼装逻辑此前双端各写一份，改一行文案要发两次版、过一次审核。
// **什么没搬**：provenance 留在端上（会话是端上概念）；确认弹窗留在端上（UI 语义）；
// **变更工具的 schema 钉死在端上** —— `kind: .mutation` 决定弹不弹 HITL 确认框，
// 那道闸门不能由下发内容决定。只读工具的 schema 现在可以下发（见 `AIWireTools`）。
//
// ⚠️ 服务端返回的 `text` **已经消毒并包好数据围栏**，端上绝不能再过一次
// `AIFence.sanitize` —— 那会把服务端加的标记一并中和掉，围栏就白做了。
// 管道据此把这类结果标成「已处理」直接透传。

/// 服务端工具体的返回。
public struct AIToolRemoteResult: Sendable {
    /// 已消毒 + 已围栏的文本，原样喂回模型。
    public let text: String
    /// 结果里出现的 id，按类别分组 —— 端上据此登记会话 provenance。
    public let ids: [AIProvenanceKind: [String]]
    /// 结构化卡片（R3）—— **给用户看的那一份，不喂给模型**。
    public let cards: [AgentCard]
}

public actor AIToolRemote {

    public static let shared = AIToolRemote()
    private let api = APIClient.shared

    private struct Payload: Encodable {
        let name: String
        let identity: String
        let args: AgentToolInput
        let scope: Scope

        struct Scope: Encodable {
            let merchantId: Int?
            let merchantName: String?
        }
    }

    private struct Response: Decodable {
        let text: String
        // 服务端按类别分组返回；键是 AIProvenanceKind 的 rawValue。
        // 用 [String: [String]] 收而不是强类型 —— 服务端将来加新类别时，
        // 老客户端应当**静默忽略**而不是整条解码失败。
        let ids: [String: [String]]?
        // 老服务端不返这个字段；新 kind 的卡片老客户端解不出来时也不该整条失败
        let cards: [AgentCard]?
    }

    // MARK: - 执行期解析（prepare / commit 两段式）

    /// 服务端解析的结果。
    public enum RemotePrepared: Sendable {
        /// 前置条件不满足（地址簿空、未达起送）。**不是错误** ——
        /// 文本直接作为工具结果回给模型，让它换个做法。
        case abort(String)
        /// 解析完成：intent 给用户确认，通过后拿 token 去 commit。
        case ready(token: String, summary: String, details: [String: String])
    }

    private struct PrepareResponse: Decodable {
        let kind: String
        let text: String?
        let token: String?
        let intent: Intent?
        struct Intent: Decodable {
            let summary: String
            let details: [String: String]?
        }
    }

    private struct CommitPayload: Encodable { let token: String }

    /// 执行期解析：解析好的快照留在服务端，端上只拿到票据与给用户看的意图。
    ///
    /// **「确认里看到的 = 实际执行的」由服务端持有快照来保证** ——
    /// 端上在确认前后发什么都改不了将要执行的内容，比纯端上实现还严一点。
    public func prepare(name: String,
                        args: AgentToolInput,
                        identity: String,
                        scope: AIToolScope) async throws -> RemotePrepared {
        let payload = Payload(
            name: name, identity: identity, args: args,
            scope: .init(merchantId: scope.merchantId, merchantName: scope.merchantName)
        )
        let response: PrepareResponse = try await api.post("/ai/tools/prepare", body: payload)
        if response.kind == "abort" {
            return .abort(response.text ?? "无法执行这个操作。")
        }
        guard let token = response.token, let intent = response.intent else {
            throw APIError.serverError(500, "确认信息不完整")
        }
        return .ready(token: token, summary: intent.summary, details: intent.details ?? [:])
    }

    /// 用户确认后执行那份快照。票据一次性 —— 重试或连点得到「票据已失效」而不是执行两次。
    public func commit(token: String) async throws -> AIToolRemoteResult {
        let response: Response = try await api.post("/ai/tools/commit", body: CommitPayload(token: token))
        var ids: [AIProvenanceKind: [String]] = [:]
        for (raw, values) in response.ids ?? [:] {
            guard let kind = AIProvenanceKind(rawValue: raw) else { continue }
            ids[kind] = values
        }
        return AIToolRemoteResult(text: response.text, ids: ids, cards: response.cards ?? [])
    }

    /// 调用一个已搬到服务端的工具。
    ///
    /// 抛错交给管道统一处理成错误结果（会被消毒、不进围栏 —— 那是控制文案）。
    public func call(name: String,
                     args: AgentToolInput,
                     identity: String,
                     scope: AIToolScope) async throws -> AIToolRemoteResult {
        let payload = Payload(
            name: name,
            identity: identity,
            args: args,
            scope: .init(merchantId: scope.merchantId, merchantName: scope.merchantName)
        )
        let response: Response = try await api.post("/ai/tools/call", body: payload)
        var ids: [AIProvenanceKind: [String]] = [:]
        for (raw, values) in response.ids ?? [:] {
            guard let kind = AIProvenanceKind(rawValue: raw) else { continue }
            ids[kind] = values
        }
        return AIToolRemoteResult(text: response.text, ids: ids, cards: response.cards ?? [])
    }
}
