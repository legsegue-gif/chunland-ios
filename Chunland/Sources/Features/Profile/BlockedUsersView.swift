import SwiftUI
import ChunlandCore

// 黑名单管理（App Store 1.2 ③）。拉黑入口在订单会话页；此处集中查看与解除。
// 生效面在服务端：订单会话冻结 + 对方无法再接我的订单。
struct BlockedUsersView: View {
    @State private var items: [BlockedUser] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        Group {
            if isLoading && items.isEmpty {
                ProgressView()
            } else if let error, items.isEmpty {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            } else if items.isEmpty {
                ContentUnavailableView(
                    "黑名单为空",
                    systemImage: "person.crop.circle.badge.checkmark",
                    description: Text("在订单会话中可拉黑对方；被拉黑的用户无法与你沟通或接你的订单")
                )
            } else {
                List(items) { item in
                    HStack {
                        Image(systemName: "person.crop.circle.badge.xmark")
                            .foregroundStyle(.secondary)
                        Text(item.displayName)
                        Spacer()
                    }
                    .swipeActions(edge: .trailing) {
                        Button("解除") {
                            Task { await unblock(item) }
                        }
                        .tint(.blue)
                    }
                }
            }
        }
        .navigationTitle("黑名单")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            items = try await BlockService.shared.list()
            error = nil
        } catch {
            self.error = "加载失败，下拉重试"
        }
        isLoading = false
    }

    private func unblock(_ item: BlockedUser) async {
        items.removeAll { $0.userId == item.userId } // 乐观移除，失败 reload 兜底
        do {
            try await BlockService.shared.unblock(userId: item.userId)
        } catch {
            await load()
        }
    }
}
