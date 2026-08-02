import Foundation

// 依赖反转接缝：让 AIOrchestrator / 配置 UI 用上「本机系统 AI」（由可选的本地 AI 模块提供
// localhost OpenAI 服务），而 ChunlandCore **不 import 该模块**。app 层（Chunland target）
// 启动时注入 endpointProvider + statusProvider + presetProvider。
//
// 未注入时（模块不可用）→ provider 均回 nil → isIntegrated/isAvailable=false →
// 「系统 AI」选项与运行状态行自动隐藏、AIOrchestrator 回退用户自定义配置，一切照常编译运行。
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

    /// 系统 AI 预设（模型 id + 内部 key）。**内容属模块私有知识，接缝只存放注入结果。**
    public struct Preset: Sendable {
        public let model: String
        public let key: String
        public init(model: String, key: String) {
            self.model = model
            self.key = key
        }
    }

    // app 层随模块一起注入；nil = 模块未接入（此时 isIntegrated=false，选项不显示，
    // 下面两个便利访问器的调用路径走不到，空串仅为类型兜底）。
    nonisolated(unsafe) public static var presetProvider: (@Sendable () -> Preset)? = nil

    /// 系统 AI 预设模型 id（模块未接入时空串）。
    public static var defaultModel: String { presetProvider?().model ?? "" }
    /// 系统 AI 内部 key（模块未接入时空串）。
    public static var internalKey: String { presetProvider?().key ?? "" }
}
