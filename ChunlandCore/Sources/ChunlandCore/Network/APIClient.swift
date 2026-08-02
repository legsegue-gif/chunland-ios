import Foundation
import os

// MARK: - Error types

public struct FieldError: Equatable {
    public let field: String
    public let message: String
    public init(field: String, message: String) {
        self.field = field
        self.message = message
    }
}

public enum APIError: LocalizedError {
    case invalidURL
    case serverError(Int, String)               // httpStatus, message
    case decodingError(Error)
    case networkError(Error)
    case unauthorized
    case forbidden                              // 服务端开启权限校验后由 errorHandler 触发
    case rateLimited(retryAfter: TimeInterval?) // 服务端开启限流后触发
    case validation([FieldError])               // 服务端开启 schema 校验后触发

    public var errorDescription: String? {
        switch self {
        case .invalidURL:               return "无效的请求地址"
        case .serverError(_, let msg):  return msg
        case .decodingError:            return "数据解析失败"
        case .networkError(let e):      return e.localizedDescription
        case .unauthorized:             return "请先登录"
        case .forbidden:                return "无权限"
        case .rateLimited(let retry):
            if let r = retry { return "请求过于频繁，请 \(Int(r))s 后重试" }
            return "请求过于频繁，请稍后重试"
        case .validation(let fields):
            return fields.first.map { "\($0.field): \($0.message)" } ?? "参数校验失败"
        }
    }
}

// AppError 是项目级别的统一错误类型名（项目统一约定）。
public typealias AppError = APIError

// MARK: - APIClient
//
// APIClient 是 final class + OSAllocatedUnfairLock（非 actor）——
// 这样 AuthManager 可以在 init 中同步注入 token providers，消除启动竞态。
// Service 方法签名也不再带 `token: String` —— APIClient 自动从 tokenProvider 取
// 并附加 Authorization。401 时自动调 tokenRefresher 刷新一次重试。
public final class APIClient: @unchecked Sendable {
    public static let shared = APIClient()

    private let session: URLSession
    private let decoder: JSONDecoder

    private struct State: @unchecked Sendable {
        var baseURL: String
        var tokenProvider: (@Sendable () -> String?)?
        var tokenRefresher: (@Sendable () async throws -> String)?
    }
    private let state: OSAllocatedUnfairLock<State>

    public init(baseURL: String = AppSettings.shared.serverBaseURL) {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        // 基础遥测：app 版本/系统/机型，随每个请求发出，服务端 requestAudit 落 api_request_logs。
        config.httpAdditionalHeaders = ["X-Client-Info": ClientInfo.headerValue]
        self.session = URLSession(configuration: config)
        self.decoder = JSONDecoder()
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.state = OSAllocatedUnfairLock(initialState: State(
            baseURL: baseURL,
            tokenProvider: nil,
            tokenRefresher: nil
        ))
    }

    // MARK: - Sync setters (zero startup race)

    public func setBaseURL(_ url: String) {
        state.withLock { $0.baseURL = url }
    }

    // 兼容旧名（ServerConfigSheet 调用）
    public func configure(baseURL: String) {
        setBaseURL(baseURL)
    }

    public func setTokenProvider(_ provider: @escaping @Sendable () -> String?) {
        state.withLock { $0.tokenProvider = provider }
    }

    public func setTokenRefresher(_ refresher: @escaping @Sendable () async throws -> String) {
        state.withLock { $0.tokenRefresher = refresher }
    }

    // MARK: - Core request

    public func request<T: Decodable>(
        _ method: String,
        path: String,
        body: (any Encodable)? = nil
    ) async throws -> T {
        let snapshot = state.withLock { ($0.baseURL, $0.tokenProvider, $0.tokenRefresher) }
        let token = snapshot.1?()
        do {
            return try await _request(method, path: path, body: body, token: token, baseURL: snapshot.0)
        } catch APIError.unauthorized where snapshot.2 != nil {
            // refresh only if we actually had a token (login/register/refresh 自身无 token，不应触发刷新)
            guard token != nil, let refresher = snapshot.2 else { throw APIError.unauthorized }
            let newToken = try await refresher()
            return try await _request(method, path: path, body: body, token: newToken, baseURL: snapshot.0)
        }
    }

    private func _request<T: Decodable>(
        _ method: String,
        path: String,
        body: (any Encodable)?,
        token: String?,
        baseURL: String
    ) async throws -> T {
        guard let url = URL(string: baseURL + path) else { throw APIError.invalidURL }

        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            req.httpBody = try encoder.encode(body)
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.networkError(URLError(.badServerResponse))
        }
        if http.statusCode == 401 { throw APIError.unauthorized }

        do {
            let envelope = try decoder.decode(APIResponse<T>.self, from: data)
            if envelope.code != 0 {
                throw APIError.serverError(http.statusCode, envelope.message)
            }
            guard let result = envelope.data else {
                throw APIError.serverError(http.statusCode, "空响应")
            }
            return result
        } catch let e as APIError {
            throw e
        } catch {
            AppLogger.network.error("decoding_failed", metadata: [
                "path": path, "error": String(describing: error),
            ])
            throw APIError.decodingError(error)
        }
    }

    // MARK: - Convenience wrappers

    public func get<T: Decodable>(_ path: String) async throws -> T {
        try await request("GET", path: path)
    }
    public func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        try await request("POST", path: path, body: body)
    }
    public func put<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        try await request("PUT", path: path, body: body)
    }
    public func patch<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        try await request("PATCH", path: path, body: body)
    }
    public func delete<T: Decodable>(_ path: String) async throws -> T {
        try await request("DELETE", path: path)
    }

    // MARK: - Void variants（服务端 data:null 的接口）

    public func requestVoid(
        _ method: String,
        path: String,
        body: (any Encodable)? = nil
    ) async throws {
        let snapshot = state.withLock { ($0.baseURL, $0.tokenProvider, $0.tokenRefresher) }
        let token = snapshot.1?()
        do {
            try await _requestVoid(method, path: path, body: body, token: token, baseURL: snapshot.0)
        } catch APIError.unauthorized where snapshot.2 != nil {
            guard token != nil, let refresher = snapshot.2 else { throw APIError.unauthorized }
            let newToken = try await refresher()
            try await _requestVoid(method, path: path, body: body, token: newToken, baseURL: snapshot.0)
        }
    }

    private func _requestVoid(
        _ method: String, path: String, body: (any Encodable)?,
        token: String?, baseURL: String
    ) async throws {
        guard let url = URL(string: baseURL + path) else { throw APIError.invalidURL }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            req.httpBody = try encoder.encode(body)
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.networkError(URLError(.badServerResponse))
        }
        if http.statusCode == 401 { throw APIError.unauthorized }
        do {
            let env = try decoder.decode(EmptyEnvelope.self, from: data)
            if env.code != 0 {
                throw APIError.serverError(http.statusCode, env.message ?? "")
            }
        } catch let e as APIError { throw e }
        catch {
            AppLogger.network.error("decoding_failed_void", metadata: [
                "path": path, "error": String(describing: error),
            ])
            throw APIError.decodingError(error)
        }
    }

    public func deleteVoid(_ path: String) async throws {
        try await requestVoid("DELETE", path: path)
    }
    public func patchVoid<B: Encodable>(_ path: String, body: B) async throws {
        try await requestVoid("PATCH", path: path, body: body)
    }

    // MARK: - Raw 二进制（采购凭证：上传 image / 拉鉴权图片）
    //
    // 复用 token 注入 + 401 自动刷新；与 JSON 路径区别只在 body/Content-Type。

    /// POST raw 二进制 body（自定义 Content-Type），返回解码后的信封 data。
    public func postData<T: Decodable>(_ path: String, data: Data, contentType: String) async throws -> T {
        let snapshot = state.withLock { ($0.baseURL, $0.tokenProvider, $0.tokenRefresher) }
        let token = snapshot.1?()
        do {
            return try await _postData(path: path, data: data, contentType: contentType, token: token, baseURL: snapshot.0)
        } catch APIError.unauthorized where snapshot.2 != nil {
            guard token != nil, let refresher = snapshot.2 else { throw APIError.unauthorized }
            let newToken = try await refresher()
            return try await _postData(path: path, data: data, contentType: contentType, token: newToken, baseURL: snapshot.0)
        }
    }

    private func _postData<T: Decodable>(path: String, data: Data, contentType: String, token: String?, baseURL: String) async throws -> T {
        guard let url = URL(string: baseURL + path) else { throw APIError.invalidURL }
        var req = URLRequest(url: url, timeoutInterval: 60)  // 图片上传给宽点超时
        req.httpMethod = "POST"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = data

        let (respData, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.networkError(URLError(.badServerResponse))
        }
        if http.statusCode == 401 { throw APIError.unauthorized }
        do {
            let envelope = try decoder.decode(APIResponse<T>.self, from: respData)
            if envelope.code != 0 { throw APIError.serverError(http.statusCode, envelope.message) }
            guard let result = envelope.data else { throw APIError.serverError(http.statusCode, "空响应") }
            return result
        } catch let e as APIError { throw e }
        catch {
            AppLogger.network.error("decoding_failed", metadata: ["path": path, "error": String(describing: error)])
            throw APIError.decodingError(error)
        }
    }

    /// GET raw 二进制（鉴权图片代理）。返回原始 bytes（非信封）。
    public func getData(_ path: String) async throws -> Data {
        let snapshot = state.withLock { ($0.baseURL, $0.tokenProvider, $0.tokenRefresher) }
        let token = snapshot.1?()
        do {
            return try await _getData(path: path, token: token, baseURL: snapshot.0)
        } catch APIError.unauthorized where snapshot.2 != nil {
            guard token != nil, let refresher = snapshot.2 else { throw APIError.unauthorized }
            let newToken = try await refresher()
            return try await _getData(path: path, token: newToken, baseURL: snapshot.0)
        }
    }

    private func _getData(path: String, token: String?, baseURL: String) async throws -> Data {
        guard let url = URL(string: baseURL + path) else { throw APIError.invalidURL }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "GET"
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.networkError(URLError(.badServerResponse))
        }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.serverError(http.statusCode, "请求失败")
        }
        return data
    }
}

private struct EmptyEnvelope: Decodable {
    let code: Int
    let message: String?
}
