import SwiftUI
import UserNotifications
import ChunlandCore

// APNs 注册回调（UIApplicationDelegate 是 @MainActor 协议，方法直通 PushRegistrar）。
// 兼作通知代理：前台不弹横幅（维持既有行为），来电类推送转交 CallCoordinator 自绘来电 UI。
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushRegistrar.tokenReceived(deviceToken)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        AppLogger.app.warn("APNs register failed", metadata: ["error": String(describing: error)])
    }

    // 前台收到通知：维持既有「不弹横幅」行为（返回 []）；来电类推送转交通话协调器。
    // nonisolated：通知代理入参非 Sendable，先在此提炼 Sendable 数据再跨到主 actor。
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        return []
    }

    // 点击通知（后台/锁屏）：来电类推送 → 打开 App 并弹来电 UI。
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
    }
}

@main
struct ChunlandApp: App {
    @StateObject private var auth = AuthManager.shared
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // App init 在主线程，assumeIsolated 安全。下面两块为可选集成，未接入时整块可移除。
        MainActor.assumeIsolated {

        }
    }

    var body: some Scene {
        WindowGroup {
            // 游客模式（Apple 5.1.1）：根永远是 MainTabView，浏览免登录。
            // 登录改为按需弹出（账号类动作/受限 tab 触发），由 MainTabView 内的 LoginCoordinator 呈现。
            MainTabView()
                .environmentObject(auth)
                .onOpenURL { url in
                    // 支付宝回跳（alipay<appid>://safepay）
                    AlipayBridgeManager.shared.handleOpenURL(url)
                }
                // 推送注册：启动时已登录 / 登录成功后各触发一次（task(id:) 随登录态重跑）
                .task(id: auth.isLoggedIn) {
                    guard auth.isLoggedIn else { return }
                    await PushRegistrar.requestAndRegister()
                }
        }
    }
}
