import SwiftUI
import PhotosUI
import UIKit
import ChunlandCore

// 代购工作台（可操作）：收入头卡 + 「接下来」可操作卡片 + 待办分组 + 快捷入口。
// 「接下来」卡片的动作按钮完全由服务端 availableActions 驱动（开始采购/开始配送），
// 唯一例外「传小票」是 凭证要求（非状态转换），按 hasReceipt 判定 —— 不复制状态机。
struct AgentWorkbenchView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var dashboard: AgentDashboard?
    @State private var nextOrders: [OrderSummary] = []     // 接下来要做的单（PAID/PURCHASING）
    @State private var hasLoaded = false
    @State private var error: String?
    @State private var busyOrderIds: Set<Int> = []         // 动作进行中的单（按钮转圈防重复）
    @State private var receiptItem: PhotosPickerItem?      // 传小票选图
    @State private var receiptOrderId: Int?                // 小票归属订单
    @State private var toast: String?
    @Environment(\.horizontalSizeClass) private var hSizeClass

    var body: some View {
        Group {
            if !hasLoaded {
                ProgressView()
            } else if let error, dashboard == nil {
                ScrollView {
                    ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
                        .containerRelativeFrame([.horizontal, .vertical])
                }
                .refreshable { await load() }
            } else if let d = dashboard {
                content(d)
            }
        }
        // iPad（regular）限宽居中，与订单/购物车一致
        .frame(maxWidth: hSizeClass == .regular ? 720 : .infinity)
        .frame(maxWidth: .infinity)
        .navigationTitle("工作台")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                AskAIButton(context: .workbench())
            }
        }
        .overlay(alignment: .top) { toastView }
        .task { await load() }
        // 静默坐标上报：仅已授权定位时（绝不弹窗），15 分钟节流。
        // 让大厅「距离」对没配服务区的代购人也能工作（服务端 last_lat/lng 兜底）。
        .task { await AgentProfileService.shared.reportLocationIfDue() }
        .onAppear {
            // 切 tab / 从列表返回时刷新计数；首次由 .task 负责，hasLoaded gate 防重复
            if hasLoaded { Task { await load() } }
        }
        .onChange(of: receiptItem) { _, item in
            guard let item, let orderId = receiptOrderId else { return }
            Task { await uploadReceipt(item: item, orderId: orderId) }
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private func content(_ d: AgentDashboard) -> some View {
        List {
            earningsSection(d.earnings)
            nextSection
            todoSection(d.counts)
            shortcutsSection
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
    }

    // MARK: - 接下来：待办卡片直接可操作，免逐单钻详情

    @ViewBuilder
    private var nextSection: some View {
        if !nextOrders.isEmpty {
            Section("接下来") {
                ForEach(nextOrders.prefix(3)) { order in
                    nextCard(order)
                }
            }
        }
    }

    private func nextCard(_ order: OrderSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink(destination: OrderDetailView(orderId: order.id).environmentObject(auth)) {
                HStack(spacing: 10) {
                    CachedAsyncImage(url: URL(string: order.firstThumbnail ?? "")) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color(.systemGray5).overlay {
                            Image(systemName: "shippingbox").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if let merchant = order.merchantName, !merchant.isEmpty {
                                Text(merchant).font(.caption).bold().foregroundStyle(Color.accentColor)
                            }
                            StatusBadge(status: order.status)
                        }
                        if let name = order.firstProductName {
                            let extra = (order.itemCount ?? 1) > 1 ? " 等 \(order.itemCount!) 件" : ""
                            Text(name + extra).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            nextAction(order)
        }
        .padding(.vertical, 4)
    }

    // 动作优先级：传小票（凭证要求）> availableActions 里的推进转换（开始采购/开始配送）
    @ViewBuilder
    private func nextAction(_ order: OrderSummary) -> some View {
        let busy = busyOrderIds.contains(order.id)
        if order.status == "PURCHASING" && order.hasReceipt == false {
            // 闭包内只捕获 Sendable 的 busy，视图就地构建（PhotosPicker label 闭包是 @Sendable）
            PhotosPicker(selection: $receiptItem, matching: .images) {
                if busy {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Label("传采购小票", systemImage: "doc.viewfinder")
                        .frame(maxWidth: .infinity)
                        .font(.subheadline)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy)
            .simultaneousGesture(TapGesture().onEnded { receiptOrderId = order.id })
        } else if let action = primaryTransition(order) {
            Button {
                Task { await run(action: action, on: order) }
            } label: {
                actionLabel(action.label, icon: action.action == "startPurchase" ? "cart.fill" : "shippingbox.fill", busy: busy)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy)
        }
    }

    /// 从服务端 availableActions 里挑「推进类」动作（不含 cancel 等破坏性操作 —— 那些留在详情页做二次确认）
    private func primaryTransition(_ order: OrderSummary) -> OrderAction? {
        order.availableActions?.first { $0.action == "startPurchase" || $0.action == "startDeliver" }
    }

    private func actionLabel(_ text: String, icon: String, busy: Bool) -> some View {
        Group {
            if busy {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                Label(text, systemImage: icon).frame(maxWidth: .infinity)
            }
        }
        .font(.subheadline)
    }

    private func run(action: OrderAction, on order: OrderSummary) async {
        busyOrderIds.insert(order.id)
        defer { busyOrderIds.remove(order.id) }
        do {
            try await OrderService.shared.updateStatus(orderId: order.id, status: action.toStatus)
            showToast("\(action.label)完成")
            await load()
        } catch {
            showToast("\(action.label)失败：\(error.localizedDescription)")
        }
    }

    private func uploadReceipt(item: PhotosPickerItem, orderId: Int) async {
        defer { receiptItem = nil; receiptOrderId = nil }
        busyOrderIds.insert(orderId)
        defer { busyOrderIds.remove(orderId) }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let ui = UIImage(data: data),
              let jpeg = ui.jpegData(compressionQuality: 0.7) else {
            showToast("无法读取所选图片"); return
        }
        do {
            _ = try await EvidenceService.shared.upload(orderId: orderId, jpeg: jpeg)
            showToast("小票已上传，可开始配送")
            await load()
        } catch {
            showToast("上传失败：\(error.localizedDescription)")
        }
    }

    // 收入头卡：与结算流水（SettlementsView）同口径，点击进流水页
    private func earningsSection(_ e: AgentDashboard.Earnings) -> some View {
        Section {
            NavigationLink(destination: SettlementsView()) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        earningStat("今日收入", e.today, emphasized: true)
                        earningStat("本月", e.month)
                        Spacer()
                    }
                    HStack {
                        Text("待结算").font(.caption).foregroundStyle(.secondary)
                        Text("¥\(money(e.pendingSettlement))")
                            .font(.subheadline).bold().foregroundStyle(.orange)
                        Spacer()
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func earningStat(_ label: String, _ amount: Decimal, emphasized: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text("¥\(money(amount))")
                .font(emphasized ? .title2 : .title3)
                .bold(emphasized)
                .foregroundStyle(emphasized ? .primary : .secondary)
        }
    }

    // 待办分组：全组常显（计数 0 置灰），布局稳定、一眼看全履约链
    private func todoSection(_ c: AgentDashboard.Counts) -> some View {
        Section("待办") {
            todoRow("待买家支付", count: c.claimed, status: "CLAIMED", icon: "creditcard")
            todoRow("待采购", count: c.paid, status: "PAID", icon: "cart")
            todoRow("采购中", count: c.purchasing, status: "PURCHASING", icon: "basket",
                    warning: purchasingWarning(c))
            todoRow("配送中", count: c.delivering, status: "DELIVERING", icon: "shippingbox")
            todoRow("待买家确认", count: c.delivered, status: "DELIVERED", icon: "checkmark.seal")
        }
    }

    private func purchasingWarning(_ c: AgentDashboard.Counts) -> String? {
        var parts: [String] = []
        if c.purchasingNoReceipt > 0 { parts.append("\(c.purchasingNoReceipt) 单缺小票") }
        if c.purchasingPendingAdjustment > 0 { parts.append("\(c.purchasingPendingAdjustment) 单改单待答复") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func todoRow(_ label: String, count: Int, status: String, icon: String,
                         warning: String? = nil) -> some View {
        NavigationLink(destination: OrderListView(
            title: label,
            scope: "mine",
            status: status,
            emptyTitle: "暂无「\(label)」的订单",
            emptyDescription: "有新进展会出现在这里",
            emptyIcon: icon
        ).environmentObject(auth)) {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label)
                        if let warning {
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                } icon: {
                    Image(systemName: icon)
                        .foregroundStyle(count > 0 ? Color.accentColor : Color.secondary)
                }
                Spacer()
                Text("\(count) 单")
                    .font(.subheadline)
                    .foregroundStyle(count > 0 ? .primary : .tertiary)
            }
        }
    }

    private var shortcutsSection: some View {
        Section {
            NavigationLink(destination: PurchaseListView()) {
                Label("合并采购清单", systemImage: "basket")
            }
            NavigationLink(destination: OrderListView(
                title: "全部接单",
                scope: "mine",
                emptyTitle: "还没接过单",
                emptyDescription: "去接单大厅看看",
                emptyIcon: "list.bullet.clipboard"
            ).environmentObject(auth)) {
                Label("全部接单", systemImage: "list.bullet.clipboard")
            }
            NavigationLink(destination: SettlementsView()) {
                Label("结算流水", systemImage: "yensign.circle")
            }
        }
    }

    // MARK: - 加载

    private func load() async {
        error = nil
        do {
            async let dashboardTask = AgentProfileService.shared.dashboard()
            async let mineTask = OrderService.shared.list(scope: "mine")
            let (d, mine) = try await (dashboardTask, mineTask)
            dashboard = d
            // 「接下来」= 我能推进的单：待采购 → 采购中缺小票 → 采购中可配送
            nextOrders = mine
                .filter { $0.status == "PAID" || $0.status == "PURCHASING" }
                .sorted { rank($0) < rank($1) }
        } catch {
            self.error = error.localizedDescription
        }
        hasLoaded = true
    }

    private func rank(_ o: OrderSummary) -> Int {
        if o.status == "PAID" { return 0 }
        if o.status == "PURCHASING" && o.hasReceipt == false { return 1 }
        return 2
    }

    private func money(_ d: Decimal) -> String {
        String(format: "%.2f", NSDecimalNumber(decimal: d).doubleValue)
    }

    // MARK: - Toast

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func showToast(_ msg: String) {
        withAnimation { toast = msg }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run { if toast == msg { withAnimation { toast = nil } } }
        }
    }
}
