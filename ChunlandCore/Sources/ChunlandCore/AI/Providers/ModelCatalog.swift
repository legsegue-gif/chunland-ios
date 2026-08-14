import Foundation

// MARK: - 从端点拉可用模型列表
//
// 让用户在配置来源时能「选」而不是「背」—— 手打模型名打错了要等到发第一条消息才报错，
// 而且错在哪并不明显。
//
// ⚠️ 这是**锦上添花的能力，不是必经步骤**：OpenAI 兼容只规定了 /chat/completions，
// `/models` 有的端点不实现、有的要求另一套鉴权。所以拉取失败绝不能挡住保存 ——
// 手填那条路必须一直留着。

public enum ModelCatalog {

    public enum FetchError: LocalizedError {
        case unauthorized
        case notSupported
        case badResponse
        case http(Int)

        public var errorDescription: String? {
            switch self {
            case .unauthorized: return "API Key 无效或没有权限"
            case .notSupported: return "这个端点不支持列出模型，请手动填写模型名"
            case .badResponse:  return "返回的内容看不懂，请手动填写模型名"
            case .http(let code): return "获取失败（HTTP \(code)），请手动填写模型名"
            }
        }
    }

    /// 拉取模型 id 列表。`baseURL` 是含 /v1 的完整地址（与 provider 用的是同一个）。
    public static func fetch(baseURL: String, apiKey: String) async throws -> [String] {
        var trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed = String(trimmed.dropLast()) }
        guard let url = URL(string: trimmed + "/models") else { throw FetchError.badResponse }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: break
        case 401, 403: throw FetchError.unauthorized
        case 404, 405: throw FetchError.notSupported
        default: throw FetchError.http(status)
        }

        // 标准形状是 {"object":"list","data":[{"id":...}]}，
        // 但也见过直接返回数组的实现 —— 两种都收，不为一个不规范的端点把功能判死。
        let root = try? JSONSerialization.jsonObject(with: data)
        let rows: [[String: Any]]
        if let obj = root as? [String: Any], let arr = obj["data"] as? [[String: Any]] {
            rows = arr
        } else if let arr = root as? [[String: Any]] {
            rows = arr
        } else {
            throw FetchError.badResponse
        }

        let ids = rows.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
        guard !ids.isEmpty else { throw FetchError.badResponse }
        // 去重后按名字排 —— 端点返回的顺序通常是创建时间，对找模型没帮助
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }.sorted()
    }
}
