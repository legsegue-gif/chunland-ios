import SwiftUI
import ChunlandCore

// 通用关注按钮（频道 / 商家共用）。读 FollowStore 判态，点击 toggle（乐观更新由 store 完成）。
// 未登录点击 → 提示登录；toggle 失败 → store 回滚 + 本组件 alert。
struct FollowButton: View {
    let type: FollowTargetType
    let key: String

    @EnvironmentObject private var login: LoginCoordinator
    @State private var followStore = FollowStore.shared
    @State private var busy = false
    @State private var alertMsg: String?

    private var following: Bool { followStore.isFollowing(type: type, key: key) }

    var body: some View {
        Button {
            // 游客模式：关注需登录，登录成功后自动续做该关注动作（intent retry）。
            login.requireLogin(reason: "登录后即可关注") {
                guard !busy else { return }
                busy = true
                Task {
                    if !followStore.isLoaded { await followStore.loadIfNeeded() }
                    if let msg = await followStore.toggle(type: type, key: key) { alertMsg = msg }
                    busy = false
                }
            }
        } label: {
            Label(following ? "已关注" : "关注", systemImage: following ? "checkmark" : "plus")
                .font(.caption.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(following ? Color(.systemGray5) : Color.accentColor)
                .foregroundStyle(following ? Color.primary : Color.white)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .alert("提示", isPresented: Binding(get: { alertMsg != nil }, set: { if !$0 { alertMsg = nil } })) {
            Button("好", role: .cancel) { alertMsg = nil }
        } message: { Text(alertMsg ?? "") }
    }
}
