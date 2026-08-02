import SwiftUI
import PhotosUI
import UIKit
import ChunlandCore

struct OrderListView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var orders: [OrderSummary] = []
    @State private var hasLoaded = false
    @State private var error: String?
    @State private var sortByDistance = false   // 大厅专用（A2）：按最近距离排序
    @Environment(\.horizontalSizeClass) private var hSizeClass

    var title: String = "我的订单"
    var scope: String? = nil
    var status: String? = nil
    var emptyTitle: String = "暂无订单"
    var emptyDescription: String = "下单后会在这里显示"
    var emptyIcon: String = "list.bullet.clipboard"

    var body: some View {
        Group {
            if !hasLoaded {
                ProgressView()
            } else if orders.isEmpty {
                ScrollView {
                    emptyOrErrorView
                        .containerRelativeFrame([.horizontal, .vertical])
                }
                .refreshable { await load() }
            } else {
                List(orders) { order in
                    NavigationLink(destination: OrderDetailView(orderId: order.id)
                        .environmentObject(auth)) {
                        OrderRow(order: order, isHall: scope == "hall")
                    }
                }
                .listStyle(.plain)
                .refreshable { await load() }
            }
        }
        // iPad（regular）限宽居中，避免订单行拉满宽屏过于稀疏
        .frame(maxWidth: hSizeClass == .regular ? 720 : .infinity)
        .frame(maxWidth: .infinity)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 仅消费者「我的订单」(scope==nil) 显示 AI 入口；agent 大厅/接单(scope=hall/mine)不挂。
            if scope == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    AskAIButton(context: .orders())
                }
            }
            // 大厅排序：最新 / 最近距离
            if scope == "hall" {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("排序", selection: $sortByDistance) {
                            Label("最新优先", systemImage: "clock").tag(false)
                            Label("最近优先", systemImage: "location").tag(true)
                        }
                    } label: {
                        Image(systemName: sortByDistance ? "location" : "arrow.up.arrow.down")
                    }
                }
            }
        }
        .onChange(of: sortByDistance) { _, _ in
            Task { await load() }
        }
        .task { await load() }
        .onAppear {
            // 切 tab / 从详情返回时刷新（接单大厅看到最新单）；首次由 .task 负责，hasLoaded gate 防重复
            if hasLoaded { Task { await load() } }
        }
    }

    @ViewBuilder
    private var emptyOrErrorView: some View {
        if let error {
            ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
        } else {
            ContentUnavailableView(emptyTitle, systemImage: emptyIcon,
                description: Text(emptyDescription))
        }
    }

    private func load() async {
        error = nil
        do {
            orders = try await OrderService.shared.list(
                status: status, scope: scope,
                sort: (scope == "hall" && sortByDistance) ? "distance" : nil
            )
        } catch {
            self.error = error.localizedDescription
        }
        hasLoaded = true
    }
}

// MARK: - OrderRow

private struct OrderRow: View {
    let order: OrderSummary
    var isHall: Bool = false

    var body: some View {
        if isHall {
            hallBody     // 代购人视角（D2）：预计收入置顶、商品直观、免状态徽章（大厅全是待接单）
        } else {
            defaultBody
        }
    }

    // 大厅卡片：一眼三要素 —— 买什么（缩略图+首商品+件数）、赚多少（agent_fee）、跑多远（距离/顺路）
    private var hallBody: some View {
        HStack(spacing: 10) {
            CachedAsyncImage(url: URL(string: order.firstThumbnail ?? "")) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color(.systemGray5).overlay {
                    Image(systemName: "shippingbox").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let merchant = order.merchantName, !merchant.isEmpty {
                        Text(merchant)
                            .font(.caption2).bold()
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    }
                    if order.onTheWay == true {
                        // 真距离：绕路>0 时标注公里数（同商家/同区县中心 = 纯顺路不带数字）
                        let detourText = (order.detourKm ?? 0) > 0
                            ? String(format: "顺路·绕%.1fkm", order.detourKm!)
                            : "顺路"
                        Text(detourText)
                            .font(.caption2).bold()
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    }
                    if let km = order.distanceKm {
                        Label(km < 10 ? String(format: "%.1fkm", km) : String(format: "%.0fkm", km),
                              systemImage: "location")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                if let name = order.firstProductName {
                    let extra = (order.itemCount ?? 1) > 1 ? " 等 \(order.itemCount!) 件" : ""
                    Text(name + extra)
                        .font(.subheadline)
                        .lineLimit(1)
                } else if let count = order.itemCount {
                    Text("共 \(count) 件商品").font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("接单赚 ¥\(order.agentFee.description)")
                        .font(.subheadline).bold()
                        .foregroundStyle(.orange)
                    Text("货值 ¥\(order.itemsTotal.description)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formatDate(order.createdAt)).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var defaultBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let merchant = order.merchantName, !merchant.isEmpty {
                    Text(merchant)
                        .font(.caption2).bold()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Capsule())
                }
                Text(order.orderNumber).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).layoutPriority(-1)
                Spacer()
                StatusBadge(status: order.status)
            }
            HStack {
                Text("¥\(order.totalAmount.description)").font(.headline).bold()
                Spacer()
                Text(formatDate(order.createdAt)).font(.caption2).foregroundStyle(.tertiary)
            }
            if let count = order.itemCount {
                Text("共 \(count) 件商品").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func formatDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.dateStyle = .short
        out.timeStyle = .short
        return out.string(from: d)
    }
}

// MARK: - StatusBadge

struct StatusBadge: View {
    let status: String

    private var label: String {
        switch status {
        case "PENDING":    return "待接单"
        case "CLAIMED":    return "已接单"
        case "PAID":       return "已付款"
        case "PURCHASING": return "代购中"
        case "DELIVERING": return "派送中"
        case "DELIVERED":  return "待确认"
        case "COMPLETED":  return "已完成"
        case "CANCELLED":  return "已取消"
        case "REFUNDED":   return "已退款"
        default:           return status
        }
    }

    private var color: Color {
        switch status {
        case "PENDING":    return .orange
        case "CLAIMED", "PAID", "PURCHASING": return .blue
        case "DELIVERING": return .purple
        case "DELIVERED":  return .teal
        case "COMPLETED":  return .green
        case "CANCELLED":  return .gray
        case "REFUNDED":   return .pink
        default:           return .secondary
        }
    }

    var body: some View {
        Text(label)
            .font(.caption2).bold()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .cornerRadius(8)
    }
}

// MARK: - OrderDetailView

struct OrderDetailView: View {
    let orderId: Int
    @State private var store: OrderDetailStore

    @State private var pendingCancel = false
    @State private var pendingComplete = false
    @State private var pendingRefund = false
    @State private var toast: String?
    @State private var receiptItem: PhotosPickerItem?     // F2 小票选取
    @State private var preview: EvidencePreviewTarget?     // F2 凭证放大预览
    @State private var showAdjustForm = false             // F3 代购人发起改单
    @State private var decideTarget: AdjustDecision?       // F3 消费者接受/拒绝确认
    @State private var showReport = false                  // 举报代购人
    @EnvironmentObject private var login: LoginCoordinator
    @Environment(\.scenePhase) private var scenePhase

    init(orderId: Int) {
        self.orderId = orderId
        _store = State(initialValue: OrderDetailStore(orderId: orderId))
    }

    var body: some View {
        mainContent
            .onChange(of: receiptItem) { _, item in
                guard let item else { return }
                Task {
                    defer { receiptItem = nil }
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let ui = UIImage(data: data),
                          let jpeg = ui.jpegData(compressionQuality: 0.7) else {
                        showToast("无法读取所选图片"); return
                    }
                    if let err = await store.uploadReceipt(jpeg: jpeg) { showToast(err) }
                    else { showToast("小票已上传") }
                }
            }
            .sheet(item: $preview) { target in
                EvidenceFullScreen(orderId: target.orderId, evidenceId: target.id)
            }
            .sheet(isPresented: $showAdjustForm) {
                if let order = store.order {
                    AdjustmentFormView(order: order, store: store)
                }
            }
            .sheet(isPresented: $showReport) {
                if let agentId = store.order?.agentId {
                    ReportSheet(targetType: .agent, targetKey: String(agentId))
                }
            }
            .confirmationDialog(
                decideTarget?.accept == true ? "确认接受此改单调整？" : "确认拒绝此改单？",
                isPresented: Binding(get: { decideTarget != nil }, set: { if !$0 { decideTarget = nil } }),
                titleVisibility: .visible,
                presenting: decideTarget
            ) { target in
                Button(target.accept ? "接受调整" : "拒绝", role: target.accept ? nil : .destructive) {
                    Task {
                        let err = await store.decideAdjustment(target.id, accept: target.accept)
                        showToast(err ?? (target.accept ? "已接受调整" : "已拒绝改单"))
                    }
                }
                Button("取消", role: .cancel) {}
            } message: { target in
                Text(target.accept ? "接受后将按新金额结算，差额原路退回" : "拒绝后代购人可重新协商，或你可整单取消退款")
            }
    }

    private var mainContent: some View {
        Group {
            if store.isLoading {
                ProgressView()
            } else if let error = store.error {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            } else if let order = store.order {
                orderContent(order)
            }
        }
        .navigationTitle("订单详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                AskAIButton(context: .order(id: orderId, number: store.order?.orderNumber))
            }
            if store.isOwnerConsumer, store.order?.agentId != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("举报代购人", systemImage: "flag") {
                            login.requireLogin(reason: "登录后即可举报") { showReport = true }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .overlay(alignment: .top) {
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
        .animation(.easeInOut(duration: 0.2), value: toast)
        .confirmationDialog("确定取消此订单？", isPresented: $pendingCancel, titleVisibility: .visible) {
            Button("确定取消", role: .destructive) {
                Task {
                    if let err = await store.transition(toStatus: "CANCELLED", label: "取消订单") {
                        showToast(err)
                    }
                }
            }
            Button("再想想", role: .cancel) {}
        }
        .confirmationDialog("确认已收到商品？", isPresented: $pendingComplete, titleVisibility: .visible) {
            Button("确认收货") {
                Task {
                    if let err = await store.transition(toStatus: "COMPLETED", label: "确认收货") {
                        showToast(err)
                    }
                }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("确认为此订单退款？", isPresented: $pendingRefund, titleVisibility: .visible) {
            Button("确认退款", role: .destructive) {
                Task {
                    if let err = await store.refund() {
                        showToast(err)
                    } else {
                        showToast("已退款")
                    }
                }
            }
            Button("再想想", role: .cancel) {}
        }
        .task { await store.load() }
        .onChange(of: scenePhase) { _, phase in
            // 从支付宝回前台时，若仍在等支付（CLAIMED）则刷新看是否已转 PAID
            if phase == .active, store.order?.status == "CLAIMED" {
                Task { await store.load() }
            }
        }
    }

    @ViewBuilder
    private func orderContent(_ order: OrderDetail) -> some View {
        List {
            Section {
                LabeledContent("订单号", value: order.orderNumber)
                HStack { Text("状态"); Spacer(); StatusBadge(status: order.status) }
                LabeledContent("下单时间", value: formatDate(order.createdAt))
            }

            Section("商品") {
                ForEach(order.items) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.productSnapshot.name).font(.subheadline)
                            HStack(spacing: 6) {
                                if let size = item.selectedSize, !size.isEmpty {
                                    Text("尺码 \(size)").font(.caption).foregroundStyle(.secondary)
                                }
                                Text("× \(item.quantity)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text("¥\(item.totalPrice.description)").font(.subheadline).bold()
                    }
                }
            }

            Section("费用") {
                LabeledContent("商品合计", value: "¥\(order.itemsTotal)")
                LabeledContent("平台服务费", value: "¥\(order.platformFee)")
                LabeledContent("代购费", value: "¥\(order.agentFee)")
                LabeledContent("实付金额", value: "¥\(order.totalAmount)")
                    .bold()
            }

            Section("收货信息") {
                LabeledContent("收货人", value: order.deliveryAddress.name)
                LabeledContent("电话", value: order.deliveryAddress.phone)
                LabeledContent("地址", value: order.deliveryAddress.address)
                if let note = order.deliveryAddress.note, !note.isEmpty {
                    LabeledContent("备注", value: note)
                }
            }

            adjustmentSection(order: order)

            evidenceSection(order: order)

            actionsSection(order: order)
        }
        .listStyle(.insetGrouped)
    }


    // 按钮 / 状态文案 / 角色判断完全由服务端 availableActions 驱动。
    // iOS 不再硬编码状态转换；新增/调整 transition 只需改服务端状态机。
    @ViewBuilder
    private func actionsSection(order: OrderDetail) -> some View {
        if let actions = order.availableActions, !actions.isEmpty {
            Section {
                ForEach(actions) { a in
                    Button(role: a.style == "destructive" ? .destructive : nil) {
                        handle(action: a)
                    } label: {
                        actionLabel(a.label, icon: icon(for: a.action))
                    }
                    .disabled(store.actionLoading)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func icon(for action: String) -> String {
        switch action {
        case "claim":           return "hand.raised"
        case "pay":             return "creditcard.fill"
        case "startPurchase":   return "cart.fill"
        case "startDeliver":    return "shippingbox.fill"
        case "confirmDelivery": return "checkmark.seal"
        case "complete":        return "checkmark.circle"
        case "cancel":          return "xmark.circle"
        case "refund":          return "arrow.uturn.left.circle"
        default:                return "arrow.right.circle"
        }
    }

    private func handle(action a: OrderAction) {
        switch a.action {
        case "claim":
            Task {
                if let err = await store.claim() {
                    showToast(err)
                }
            }
        case "cancel":   pendingCancel = true       // 二次确认 UX
        case "complete": pendingComplete = true     // 二次确认 UX
        case "refund":   pendingRefund = true        // 二次确认 UX
        case "pay":
            Task {
                if let err = await store.pay() { showToast(err) }
            }
        default:
            Task {
                if let err = await store.transition(toStatus: a.toStatus, label: a.label) {
                    showToast(err)
                }
            }
        }
    }

    @ViewBuilder
    private func actionLabel(_ text: String, icon: String) -> some View {
        if store.actionLoading {
            ProgressView()
        } else {
            Label(text, systemImage: icon).frame(maxWidth: .infinity)
        }
    }

    // MARK: - 缺货改单

    @ViewBuilder
    private func adjustmentSection(order: OrderDetail) -> some View {
        // 代购人发起入口
        if store.canProposeAdjustment {
            Section {
                Button {
                    showAdjustForm = true
                } label: {
                    Label("发起改单（缺货 / 降价）", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                }
            } footer: {
                Text("采购中遇到缺货或差价时，提交改单由消费者确认")
            }
        }

        // 消费者决策卡
        if store.showsAdjustmentCardForConsumer, let adj = store.pendingAdjustment {
            Section("待确认改单") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("代购人调整了订单，请确认").font(.subheadline).bold()
                    ForEach(adj.detail.items) { c in
                        Text("• " + describeChange(c, in: order)).font(.callout)
                    }
                    if let n = adj.note, !n.isEmpty {
                        Text("备注：\(n)").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    HStack {
                        Text("合计")
                        Spacer()
                        Text("¥\(money(order.totalAmount)) → ¥\(money(order.totalAmount + adj.amountDelta))").bold()
                    }
                    if adj.refundAmount > 0 {
                        HStack {
                            Text("预计退款").foregroundStyle(.secondary)
                            Spacer()
                            Text("¥\(money(adj.refundAmount))").foregroundStyle(.green)
                        }
                    }
                    HStack(spacing: 12) {
                        Button("接受调整") { decideTarget = AdjustDecision(id: adj.id, accept: true) }
                            .buttonStyle(.borderedProminent)
                        Button("拒绝", role: .destructive) { decideTarget = AdjustDecision(id: adj.id, accept: false) }
                            .buttonStyle(.bordered)
                        Spacer()
                    }
                    .disabled(store.actionLoading)
                    .padding(.top, 2)
                }
                .padding(.vertical, 4)
            }
        } else if store.hasPendingProposalAsAgent, let adj = store.pendingAdjustment {
            // 代购人：自己发起的改单待确认（只读）
            Section("改单待确认") {
                ForEach(adj.detail.items) { c in
                    Text("• " + describeChange(c, in: order)).font(.callout)
                }
                Text("等待消费者确认…").font(.caption).foregroundStyle(.secondary)
            }
        }

        // 已决定的改单记录
        let decided = store.adjustments.filter { !$0.isPending }
        if !decided.isEmpty {
            Section("改单记录") {
                ForEach(decided) { adj in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(adj.detail.items) { c in
                                Text(describeChange(c, in: order)).font(.caption)
                            }
                        }
                        Spacer()
                        Text(adj.status == "ACCEPTED" ? "已接受" : "已拒绝")
                            .font(.caption)
                            .foregroundStyle(adj.status == "ACCEPTED" ? .green : .secondary)
                    }
                }
            }
        }
    }

    private func describeChange(_ c: AdjustmentItem, in order: OrderDetail) -> String {
        let item = order.items.first { $0.id == c.orderItemId }
        let name = item?.productSnapshot.name ?? "商品#\(c.orderItemId)"
        switch c.action {
        case "remove":
            return "\(name)：缺货移除"
        case "reduce_qty":
            return "\(name)：数量 \(item?.quantity ?? 0) → \(c.newQuantity ?? 0)"
        case "change_price":
            let old = item.map { "¥\(money($0.unitPrice))" } ?? "?"
            let new = c.newUnitPrice.map { "¥\(money($0))" } ?? "?"
            return "\(name)：单价 \(old) → \(new)"
        case "change_spec":
            return "\(name)：规格改为 \(c.newSize ?? "")"
        default:
            return name
        }
    }

    private func money(_ d: Decimal) -> String {
        String(format: "%.2f", NSDecimalNumber(decimal: d).doubleValue)
    }

    // MARK: - 采购凭证

    @ViewBuilder
    private func evidenceSection(order: OrderDetail) -> some View {
        if store.showsEvidenceSection {
            Section("采购凭证") {
                if store.evidences.isEmpty {
                    Text(store.canUploadReceipt
                         ? "尚未上传小票。开始配送前需先上传采购小票。"
                         : "代购人尚未上传凭证")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(store.evidences) { ev in
                                EvidenceThumbnail(orderId: ev.orderId, evidenceId: ev.id)
                                    .onTapGesture {
                                        preview = EvidencePreviewTarget(id: ev.id, orderId: ev.orderId)
                                    }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                if store.canUploadReceipt {
                    let uploadLabel = store.hasReceipt ? "再传一张小票" : "上传采购小票"
                    PhotosPicker(selection: $receiptItem, matching: .images) {
                        Label(uploadLabel, systemImage: "doc.viewfinder")
                    }
                    .disabled(store.actionLoading)
                }
            }
        }
    }

    private func showToast(_ msg: String) {
        toast = msg
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run { if toast == msg { toast = nil } }
        }
    }

    private func formatDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.dateStyle = .medium
        out.timeStyle = .short
        return out.string(from: d)
    }
}

// MARK: - 采购凭证视图

struct EvidencePreviewTarget: Identifiable {
    let id: Int        // evidenceId
    let orderId: Int
}

// 改单决策确认目标
struct AdjustDecision: Identifiable {
    let id: Int        // adjustmentId
    let accept: Bool
}

// 鉴权缩略图：凭证桶非公开，经 EvidenceService 带 token 拉 bytes 后本地渲染。
private struct EvidenceThumbnail: View {
    let orderId: Int
    let evidenceId: Int
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if failed {
                Image(systemName: "photo").foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .frame(width: 88, height: 88)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .task {
            guard image == nil, !failed else { return }
            do {
                let data = try await EvidenceService.shared.imageData(orderId: orderId, evidenceId: evidenceId)
                if let ui = UIImage(data: data) { image = ui } else { failed = true }
            } catch { failed = true }
        }
    }
}

// 全屏放大查看（可双指缩放）。
private struct EvidenceFullScreen: View {
    let orderId: Int
    let evidenceId: Int
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    ZoomableImage(image: image)
                } else if failed {
                    ContentUnavailableView("无法加载凭证", systemImage: "photo")
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.92).ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .task {
                guard image == nil, !failed else { return }
                do {
                    let data = try await EvidenceService.shared.imageData(orderId: orderId, evidenceId: evidenceId)
                    if let ui = UIImage(data: data) { image = ui } else { failed = true }
                } catch { failed = true }
            }
        }
    }
}

private struct ZoomableImage: View {
    let image: UIImage
    @State private var scale: CGFloat = 1

    var body: some View {
        Image(uiImage: image)
            .resizable().scaledToFit()
            .scaleEffect(scale)
            .gesture(
                MagnificationGesture()
                    .onChanged { scale = max(1, $0) }
                    .onEnded { _ in withAnimation { scale = min(max(scale, 1), 4) } }
            )
    }
}
