import SwiftUI
import ChunlandCore

// 游客占位 CTA：购物车 / 我的 / AI 等「账号类」tab 在未登录时显示。
// 设计意图：不把游客困在弹窗里 —— 仍可切回其他 tab 浏览；点「登录 / 注册」经
// LoginCoordinator 弹登录，登录成功后页面自身（isLoggedIn 翻 true）重渲染加载真实内容。
struct GuestGate: View {
    let title: String
    let message: String
    let systemImage: String

    @EnvironmentObject private var login: LoginCoordinator

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            Button {
                login.requireLogin()
            } label: {
                Text("登录 / 注册")
                    .frame(maxWidth: 220)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
