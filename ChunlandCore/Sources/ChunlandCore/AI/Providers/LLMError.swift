import Foundation

// MARK: - LLM 错误分类
//
// 整套重试与降级机制的地基。核心是两个**正交**的判定：
//
//   isRetryable    —— 同一个模型重试有意义吗？（网络抖动、上游 5xx）
//   isFallbackable —— 这个 provider 根本服务不了，该换一个吗？（限流、密钥无效、拒绝）
//
// 它们不是「两类错误」而是「两个独立提问」：瞬时错误先在当前模型重试，
// 重试耗尽后同样要进降级路径。把两者混成一个枚举会让「重试几次后换模型」
// 这个最常见的策略无法表达。

public enum LLMError: LocalizedError, Sendable, Equatable {

    /// 密钥无效 / 未授权（401、403）。
    case invalidAPIKey(detail: String)

    /// 网络层失败（连不上、超时、连接中断）。
    case networkError(message: String)

    /// 上游明确拒绝了这个请求（4xx，非鉴权类）。
    case providerError(message: String)

    /// 上游临时不可用（500/502/503/504/529）。重试有意义。
    case transientError(message: String)

    /// 被限流（429）。
    case rateLimited(retryAfterSeconds: Int?)

    /// 响应解析失败（返回了非预期的结构）。
    case decodingError(message: String)

    /// 用户主动取消。
    case cancelled

    /// 未配置可用的模型。
    case notConfigured

    /// 系统 AI 暂不可用（本机服务未就绪 / 已停用）。
    case systemProviderUnavailable(reason: String)

    case unknown(message: String)

    // MARK: - 两个正交判定

    /// 同一模型重试有意义 —— 走递增倒计时重试。
    public var isRetryable: Bool {
        switch self {
        case .networkError, .transientError:
            return true
        case .invalidAPIKey, .providerError, .rateLimited, .decodingError,
             .cancelled, .notConfigured, .systemProviderUnavailable, .unknown:
            return false
        }
    }

    /// 这个 provider 服务不了 —— 立刻换下一个模型，不在当前模型重试。
    ///
    /// 注意 `transientError` / `networkError` **不在此列**，但它们在
    /// 自动重试耗尽后同样会进入降级 —— 那是调用方的策略，不是错误本身的属性。
    public var isFallbackable: Bool {
        switch self {
        case .rateLimited, .invalidAPIKey, .providerError, .systemProviderUnavailable:
            return true
        case .transientError, .networkError, .decodingError,
             .cancelled, .notConfigured, .unknown:
            return false
        }
    }

    /// 用户主动取消不该被当成失败上报。
    public var isCancellation: Bool {
        if case .cancelled = self { return true }
        return false
    }

    /// 降级时记录的原因，最终会展示给用户（「模型 A 限流 → 已切到模型 B」）。
    public var fallbackReason: String {
        switch self {
        case .rateLimited: return "请求过于频繁"
        case .invalidAPIKey: return "密钥无效"
        case .providerError(let m): return "服务拒绝：\(m.prefix(40))"
        case .transientError: return "服务暂时不可用"
        case .networkError: return "网络异常"
        case .systemProviderUnavailable(let r): return r
        default: return "调用失败"
        }
    }

    // MARK: - 用户可见文案
    //
    // 错误原样透传对用户是天书（「HTTP 429」）。这里统一成人话，
    // 原始细节由调用方记日志，排查不受影响。

    public var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "AI 服务鉴权失败，请到「AI 配置」检查来源或 API Key。"
        case .networkError:
            return "网络连接不可用，请检查网络后重试。"
        case .providerError(let m):
            return m.isEmpty ? "AI 服务拒绝了这次请求。" : "AI 服务拒绝了这次请求：\(m)"
        case .transientError:
            return "AI 服务暂时不可用，请稍后再试。"
        case .rateLimited(let after):
            if let after { return "请求过于频繁，请 \(after) 秒后再试。" }
            return "AI 服务当前请求较多，请稍等片刻再试。"
        case .decodingError:
            return "AI 返回了无法识别的内容，请重试。"
        case .cancelled:
            return "已取消。"
        case .notConfigured:
            return "尚未配置可用的 AI 模型，请到「AI 配置」选择。"
        case .systemProviderUnavailable(let reason):
            return reason
        case .unknown(let m):
            return m.isEmpty ? "AI 请求失败，请重试。" : "AI 请求失败：\(m)"
        }
    }

    // MARK: - 从传输层错误归一化

    /// HTTP 状态码 → 错误分类。
    ///
    /// 分类的依据是**该怎么处置**，不是状态码本身：
    /// 401/403 要用户去改配置，429 要等或换号，5xx 等一会儿多半自己好，
    /// 其余 4xx 是请求本身有问题、重试没用。
    public static func fromHTTPStatus(_ status: Int, body: String = "") -> LLMError {
        let detail = String(body.prefix(200))
        switch status {
        case 401, 403:
            return .invalidAPIKey(detail: detail)
        case 429:
            return .rateLimited(retryAfterSeconds: nil)
        case 500, 502, 503, 504, 529:
            return .transientError(message: "HTTP \(status)")
        case 400...499:
            return .providerError(message: detail.isEmpty ? "HTTP \(status)" : detail)
        default:
            return .unknown(message: "HTTP \(status)")
        }
    }

    /// URLSession 错误 → 错误分类。
    public static func fromURLError(_ error: Error) -> LLMError {
        if error is CancellationError { return .cancelled }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else {
            return .unknown(message: error.localizedDescription)
        }
        switch ns.code {
        case NSURLErrorCancelled:
            return .cancelled
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
             NSURLErrorTimedOut, NSURLErrorCannotConnectToHost,
             NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
             NSURLErrorSecureConnectionFailed:
            return .networkError(message: ns.localizedDescription)
        default:
            return .networkError(message: ns.localizedDescription)
        }
    }
}
