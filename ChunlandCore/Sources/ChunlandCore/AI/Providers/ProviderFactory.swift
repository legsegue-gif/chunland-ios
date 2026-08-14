import Foundation

// MARK: - 从配置条目造 provider
//
// 系统 AI 与用户自配的差别全部收敛在这里：
// 前者的地址与密钥是**运行时动态**的（本机服务端口会变、就绪态会变），
// 每次都要现取；后者是静态配置，读库 + Keychain。
//
// ⚠️ 依赖反转红线：本文件（以及整个 provider 层）**绝不 import 本机 AI 模块**。
// 系统 AI 的地址、密钥、模型名一律经 SystemAIProvider 这个接缝取 ——
// 接缝由 App 层注入，模块不存在时自动降级为「系统 AI 不可用」，一切照常编译。

public struct ProviderFactory: Sendable {

    private let config: ProviderConfigStore
    private let loadImage: (@Sendable (MediaRef) -> Data?)?

    public init(config: ProviderConfigStore,
                loadImage: (@Sendable (MediaRef) -> Data?)? = nil) {
        self.config = config
        self.loadImage = loadImage
    }

    /// 解析出一个可用的 provider。
    ///
    /// 抛错而不是返回 nil：失败原因（未配置 / 系统 AI 未就绪 / 缺密钥）
    /// 各自对应不同的用户提示与降级决策，吞掉就没法区分了。
    public func make(entry: ModelEntry) async throws -> OpenAICompatibleProvider {
        guard let instance = await config.instance(id: entry.instanceId) else {
            throw LLMError.notConfigured
        }

        let baseURL: String
        let apiKey: String

        switch instance.kind {
        case .system:
            // 每次现取：端口与就绪态是动态的，固化到配置里必然过期。
            guard let endpoint = SystemAIProvider.endpoint else {
                throw LLMError.systemProviderUnavailable(reason: Self.systemUnavailableReason())
            }
            baseURL = endpoint.absoluteString
            apiKey = SystemAIProvider.internalKey

        case .openAICompatible:
            guard let url = instance.baseURL, !url.isEmpty else {
                throw LLMError.notConfigured
            }
            guard let key = ProviderCredentials.apiKey(for: instance.id) else {
                throw LLMError.invalidAPIKey(detail: "「\(instance.label)」尚未填写 API Key")
            }
            baseURL = url
            apiKey = key

        case .unsupported:
            throw LLMError.providerError(message: "「\(instance.label)」的来源类型本版本不支持，请升级 App")
        }

        return OpenAICompatibleProvider(
            modelId: entry.modelId,
            baseURL: baseURL,
            apiKey: apiKey,
            maxTokens: entry.maxOutputTokens,
            supportsVision: entry.supportsVision,
            loadImage: loadImage
        )
    }

    /// 系统 AI 不可用时的用户可读原因。
    ///
    /// 措辞刻意保持服务级、不暴露本机实现细节 —— 用户不需要知道
    /// 它是一个跑在本地的服务，只需要知道该等一会儿还是该换来源。
    static func systemUnavailableReason() -> String {
        switch SystemAIProvider.status {
        case .disabled:
            return "系统 AI 暂停服务，可在配置中改用自定义来源"
        case .waitingAuth:
            return "系统 AI 需要先登录"
        case .starting, .stopped, .unreachable, .failed:
            return "系统 AI 正在准备中，请稍候再试"
        case .running, .none:
            return "系统 AI 暂不可用"
        }
    }
}
