import Foundation

// 依赖反转接缝：让对话链路 / 配置 UI 用上「本机系统 AI」（由可选的本地 AI 模块提供
// localhost OpenAI 服务），而 ChunlandCore **不 import 该模块**。app 层（Chunland target）
// 启动时注入 endpointProvider + statusProvider + presetProvider。
//
// 未注入时（模块不可用）→ provider 均回 nil → isIntegrated/isAvailable=false →
// 「系统 AI」选项与运行状态行自动隐藏、降级链回落到用户自定义配置，一切照常编译运行。
//
// ⚠️ 本接缝**不得持有任何上游身份信息**（模型 id / key / 厂商名）—— 那属于模块的私有知识，
//    一律经 presetProvider 注入。

/// 系统 AI 运行状态（中性措辞，不暴露具体 proxy 实现）。app 层负责把模块内部状态映射过来。
public enum SystemAIStatus: Sendable, Equatable {
    case stopped                // 未运行
    case starting               // 启动中（首次同步进行中）
    case waitingAuth            // 等待登录
    case unreachable            // 无法获取配置（网络/服务端异常），自动重试中
    case disabled               // 服务端已停用
    case running(port: UInt16)
    case failed                 // 启动失败，自动重试中
}

public enum SystemAIProvider {
    // app 层注入；默认 nil（模块未接入 / 已删除时的安全态）。
    nonisolated(unsafe) public static var endpointProvider: @Sendable () -> URL? = { nil }
    // app 层注入；nil = 模块未接入/已删除（「系统提供」选项与状态行整体隐藏）。
    nonisolated(unsafe) public static var statusProvider: (@Sendable () -> SystemAIStatus)? = nil

    /// 本机 proxy 的 /v1 baseURL（不可用时 nil）。
    public static var endpoint: URL? { endpointProvider() }
    /// 系统 AI 此刻是否可用（proxy 正在运行）。
    public static var isAvailable: Bool { endpointProvider() != nil }
    /// 模块是否接入（决定配置页「系统提供」选项是否显示）。与 isAvailable 的区别：
    /// isIntegrated 只看接缝是否被注入，proxy 未就绪时选项仍显示、由状态行解释原因。
    public static var isIntegrated: Bool { statusProvider != nil }
    /// 当前运行状态（模块未接入时 nil）。
    public static var status: SystemAIStatus? { statusProvider?() }

    /// 系统 AI 预设 —— **模型的全部运行时属性**。内容属模块私有知识，接缝只存放注入结果。
    ///
    /// ⚠️ 这里**只放模型的属性，不放展示文案**。一旦允许 preset 带 displayName，
    /// 上游模型名就会直接出现在配置页上（配置页渲染的正是 displayName）。
    /// 「系统提供的 AI」这个中性称呼永远由 ChunlandCore 侧提供。
    public struct Preset: Sendable {
        public let model: String
        public let key: String
        /// 上下文窗口。决定 ContextPolicy 走哪一档。
        public let contextWindow: Int
        /// 默认最大输出 token。
        public let maxOutputTokens: Int
        /// 是否支持图片输入。**这是「模型能力 ∧ 本端能力」的结果**，由模块注入时算好
        /// —— 端上没有图片上传能力时，模型再能识图也必须是 false。
        public let supportsVision: Bool

        public init(model: String,
                    key: String,
                    contextWindow: Int,
                    maxOutputTokens: Int,
                    supportsVision: Bool) {
            self.model = model
            self.key = key
            self.contextWindow = contextWindow
            self.maxOutputTokens = maxOutputTokens
            self.supportsVision = supportsVision
        }
    }

    // app 层随模块一起注入；nil = 模块未接入（此时 isIntegrated=false，选项不显示，
    // 下面几个便利访问器的调用路径走不到，兜底值仅为类型需要）。
    nonisolated(unsafe) public static var presetProvider: (@Sendable () -> Preset)? = nil

    /// 当前预设（模块未接入时 nil）。**每次现取** —— 服务端可热更模型，快照必然过期。
    public static var preset: Preset? { presetProvider?() }

    // MARK: - 按需唤醒
    //
    // 系统 AI 未就绪是**唯一「前置条件可修」的失败**：模块本来就在轮询，只是下一次轮询
    // 可能还要等一整个周期。用户点了发送却被告知「正在准备中」、干等 60 秒再点一次，
    // 这个体验没必要 —— 催一次即可。
    //
    // ⚠️ 接缝仍不持有任何上游身份：这是个无参无返回值的纯动作，节流与实现都在模块内。

    /// 催一次配置同步。app 层随模块注入；未注入 = 无操作。
    nonisolated(unsafe) public static var syncRequester: (@Sendable () async -> Void)? = nil

    /// 催一次同步，最多等 `seconds` 秒。
    ///
    /// 超时即返回，**但后台那次拉取不取消** —— 它跑完之后系统 AI 就绪，
    /// 用户再点一次就能用上。等待上限存在的意义是不让用户对着转圈干等一次网络超时（15s）。
    public static func requestSync(waitingUpTo seconds: Double) async {
        guard let requester = syncRequester else { return }
        Task.detached { await requester() }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if endpointProvider() != nil { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// 催一次同步但不等 —— 用于「还有下一档可降级」时：本次请求走兜底来源，
    /// 这次催拉是为了让下一次请求能用上系统 AI。
    public static func requestSyncDetached() {
        guard let requester = syncRequester else { return }
        Task.detached { await requester() }
    }

    /// 系统 AI 预设模型 id（模块未接入时空串）。
    public static var defaultModel: String { presetProvider?().model ?? "" }
    /// 系统 AI 内部 key（模块未接入时空串）。
    public static var internalKey: String { presetProvider?().key ?? "" }
}
