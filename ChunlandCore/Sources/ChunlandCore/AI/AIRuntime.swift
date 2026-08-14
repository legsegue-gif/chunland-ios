import Foundation
import Observation

// MARK: - AI 子系统的装配点
//
// 把「谁依赖谁」集中在一处：库 → 配置 → 会话注册表。
// 之前这些散在各个视图的 @StateObject 里，导致同一份配置被多处各读一遍。
//
// 单例而不是注入：AI 的存储与配置是进程级的（一个库文件、一份来源配置），
// 每个视图各建一份只会打架。会话实例本身是多个 —— 那由注册表管。

@MainActor
@Observable
public final class AIRuntime {

    public static let shared = AIRuntime()

    public let database: AIDatabase
    public let config: ProviderConfigStore
    public let sessions: AISessionRegistry

    /// 是否已完成初始化。UI 据此决定显示加载态还是内容。
    public private(set) var isReady = false
    /// 初始化失败的原因（库打不开等）。非 nil 时 AI 整体不可用。
    public private(set) var bootstrapError: String?

    private let logger = AppLogger(subsystem: AppLogger.subsystem, category: "ai.runtime")

    private init() {
        let db = AIDatabase()
        self.database = db
        let config = ProviderConfigStore(db: db)
        self.config = config
        self.sessions = AISessionRegistry(
            db: db,
            config: config,
            executorFactory: { context in
                AgentToolRegistry(
                    scope: context.scope,
                    suggested: context.tools,
                    // 用闭包而不是快照：身份可能在会话存续期间被切换，
                    // 工具可用集必须跟着变
                    activeIdentity: { AuthManager.shared.activeIdentity }
                )
            },
            ownerUserId: { AuthManager.shared.currentUserId }
        )
    }

    /// 开库 + 加载配置。幂等，可重复调用。
    ///
    /// App 启动时调一次即可 —— 但每个 AI 入口也会调，因为用户可能从任意
    /// 入口第一次进 AI（冷启动直接点 ✨），不能假设 tab 一定先被访问过。
    public func bootstrap() async {
        guard !isReady else { return }
        do {
            try await database.open()
            try await config.loadIfNeeded()
            isReady = true
            bootstrapError = nil
            logger.info("AI 运行时就绪")
        } catch {
            bootstrapError = error.localizedDescription
            logger.error("AI 运行时初始化失败", metadata: ["error": "\(error)"])
        }
    }

    /// 降级链首选那一档的名字（「我的」页的一行摘要用）。
    ///
    /// 给的是**首选**而不是全链 —— 一行放不下全链，而用户想知道的是「现在用的是哪个」。
    /// 全链与各档可用性在配置页里展示。
    public func preferredSourceLabel() async -> String {
        await bootstrap()
        guard isReady,
              let group = await config.defaultGroup(),
              let entry = await config.usableEntries(in: group).first,
              let instance = await config.instance(id: entry.instanceId)
        else { return "未配置" }
        return "\(instance.label) · \(entry.displayName)"
    }

    /// 换账号 / 登出。
    ///
    /// 会话实例必须一并丢弃 —— 库里按 owner 过滤只挡住了读路径，
    /// 内存里那些已经装载了上一个账号消息的实例不会自己消失。
    public func resetForAccountChange() {
        sessions.reset()
        logger.info("已重置 AI 会话（账号变更）")
    }

    /// 后台维护：回收没有任何消息引用的媒体文件。
    ///
    /// 删会话时不立即删文件（同一张图可能被别的会话引用），
    /// 所以需要这个低频清理。失败无所谓，下次再扫。
    public func collectGarbage() async {
        guard isReady else { return }
        let count = (try? await MediaStore(db: database).collectGarbage()) ?? 0
        if count > 0 { logger.info("回收媒体文件", metadata: ["count": "\(count)"]) }
    }
}
