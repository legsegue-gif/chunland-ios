import Foundation

public final class AppSettings: @unchecked Sendable {
    public static let shared = AppSettings()
    private init() {}

    private let urlKey = "serverBaseURL"
    // Debug（本地开发）默认连 Mac dev server；Release（TestFlight / App Store）默认连公网 prod。
    // 用户仍可在「开发者 → 服务器地址」覆盖。
    #if DEBUG
    public let defaultServerURL = "http://localhost:3000/api/v1"
    #else
    // prod 主机由 Config.xcconfig (PROD_API_HOST) 注入 Info.plist，运行时读取 ——
    // 源码不含真实域名：默认是占位值，在 Config.xcconfig 里填你自己的后端。
    public let defaultServerURL = "https://\(Bundle.main.object(forInfoDictionaryKey: "ProdAPIHost") as? String ?? "your-server.example.com")/api/v1"
    #endif

    public var serverBaseURL: String {
        // Release（App Store）永远用编译默认（prod 主机），忽略任何遗留 override —— 这样 Debug↔Release
        // 切换重跑即生效、无需删 app 清 UserDefaults；真实用户本就无 override（配置 UI 仅 Debug）。
        // Debug 才允许 override（开发者改服务器地址，连 localhost / 局域网真机调试）。
        get {
            #if DEBUG
            return UserDefaults.standard.string(forKey: urlKey) ?? defaultServerURL
            #else
            return defaultServerURL
            #endif
        }
        set { UserDefaults.standard.set(newValue, forKey: urlKey) }
    }

    /// 清除服务器地址 override，回到随构建走的默认（Debug 配置页「恢复默认」用）。
    public func resetServerBaseURL() {
        UserDefaults.standard.removeObject(forKey: urlKey)
    }

    /// 静态页（隐私政策 / 用户协议 / 支持）基址 —— 即 serverBaseURL 去掉 `/api/v1`
    /// （这些页由 server 挂在根路径 `/privacy` `/terms` `/support`，不在 `/api/v1` 下）。
    public var docsBaseURL: String {
        var s = serverBaseURL
        for suffix in ["/api/v1/", "/api/v1"] where s.hasSuffix(suffix) {
            s.removeLast(suffix.count)
            break
        }
        return s
    }

    // AI HITL 自动确认开关（扩展点）
    //
    // true  —— AI 的 mutation 工具（addToCart / placeOrder）直接执行，方便 dev 测试。
    // false —— 触发 confirmationDialog，让用户先看到意图再决定执行。
    //
    // 默认值按构建分流：Release 恒 false —— AI 变更操作必须真人确认（prepare 解析出的
    // 真实地址/报价就展示在确认弹窗里，跳过弹窗 = 无确认下单）。上线安全不再依赖
    // 人工记得改；DEBUG 默认 true 免打断（Android 无此开关，恒真确认）。
    private let autoConfirmKey = "aiAutoConfirm"
    #if DEBUG
    private static let autoConfirmDefault = true
    #else
    private static let autoConfirmDefault = false
    #endif
    public var aiAutoConfirm: Bool {
        get {
            UserDefaults.standard.object(forKey: autoConfirmKey) as? Bool ?? Self.autoConfirmDefault
        }
        set { UserDefaults.standard.set(newValue, forKey: autoConfirmKey) }
    }

    // 各功能页面「✨ 问 AI」入口的全局开关（kill switch）。
    //
    // true（默认）—— 各页面导航栏显示 AI 入口、可弹出上下文对话面板。
    // false        —— 所有页面入口隐藏、面板不弹（出问题时一处止血，AI tab 不受影响）。
    //
    // 由 AICoordinator.isEnabled 读取；未来可改为服务端下发而页面代码不动。
    private let entryEnabledKey = "aiEntryEnabled"
    public var aiEntryEnabled: Bool {
        get { UserDefaults.standard.object(forKey: entryEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: entryEnabledKey) }
    }
}
