import UIKit
import UserNotifications
import ChunlandCore

// 推送注册编排：登录后请求通知授权 → registerForRemoteNotifications →
// AppDelegate 收到 token 回调 → 登录态下上报服务端（PushService）。
// token 存 UserDefaults：iOS 可能随时轮换 token、也可能秒回缓存值，两条路都汇到 uploadIfLoggedIn。
// 换账号登录只需重新上报——服务端按 token 唯一 upsert 改绑归属。
@MainActor
enum PushRegistrar {
    private static let tokenKey = "push.lastDeviceToken"

    /// 登录态下调用（幂等）：授权 → 注册远程通知 → 补上报
    static func requestAndRegister() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            guard (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true else { return }
        case .denied:
            return // 用户明确拒绝过：不再打扰（要开去系统设置）
        default:
            break
        }
        UIApplication.shared.registerForRemoteNotifications()
        await uploadIfLoggedIn() // token 若上次启动已拿到，注册回调可能不再来，主动补上报
    }

    /// AppDelegate 的 APNs token 回调入口
    static func tokenReceived(_ deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(hex, forKey: tokenKey)
        Task { await uploadIfLoggedIn() }
    }

    static func uploadIfLoggedIn() async {
        guard AuthManager.shared.isLoggedIn,
              let hex = UserDefaults.standard.string(forKey: tokenKey) else { return }
        do {
            try await PushService.shared.register(token: hex)
        } catch {
            AppLogger.app.warn("PushRegistrar.upload failed", metadata: ["error": String(describing: error)])
        }
    }

    /// 显式退出登录前调用（尽力而为解绑；失败不阻塞登出）
    static func unregisterBeforeLogout() async {
        guard let hex = UserDefaults.standard.string(forKey: tokenKey) else { return }
        await PushService.shared.unregister(token: hex)
    }
}
