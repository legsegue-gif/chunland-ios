import SwiftUI
import ChunlandCore

// 商家「订单」tab：自家订单只读视图。
// 隐私边界（服务端保证）：不含买家地址/联系方式；金额只有货值（平台费/代购费与商家无关）。
struct MerchantOrdersView: View {
    @State private var orders: [MerchantOrderSummary] = []
    @State private var hasLoaded = false
    @State private var error: String?
    @Environment(\.horizontalSizeClass) private var hSizeClass

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
                    NavigationLink(destination: MerchantOrderDetailView(orderId: order.id)) {
                        orderRow(order)
                    }
                }
                .listStyle(.plain)
                .refreshable { await load() }
            }
        }
        .frame(maxWidth: hSizeClass == .regular ? 720 : .infinity)
        .frame(maxWidth: .infinity)
        .navigationTitle("订单")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onAppear {
            if hasLoaded { Task { await load() } }
        }
    }

    @ViewBuilder
    private var emptyOrErrorView: some View {
        if let error {
            ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
        } else {
            ContentUnavailableView("还没有订单", systemImage: "list.bullet.rectangle",
                description: Text("买家下单你的商品后会出现在这里"))
        }
    }

    private func orderRow(_ order: MerchantOrderSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(order.orderNumber).font(.caption).foregroundStyle(.secondary)
                Spacer()
                StatusBadge(status: order.status)
            }
            HStack {
                Text("货值 ¥\(order.itemsTotal.description)").font(.headline).bold()
                Spacer()
                Text(formatDate(order.createdAt)).font(.caption2).foregroundStyle(.tertiary)
            }
            if let count = order.itemCount {
                Text("共 \(count) 件商品").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        error = nil
        do {
            orders = try await MerchantConsoleService.shared.orders()
        } catch {
            self.error = error.localizedDescription
        }
        hasLoaded = true
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

// MARK: - 详情（只读）

struct MerchantOrderDetailView: View {
    let orderId: Int
    @State private var detail: MerchantOrderDetail?
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let error {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            } else if let d = detail {
                content(d)
            }
        }
        .navigationTitle("订单详情")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { detail = try await MerchantConsoleService.shared.order(id: orderId) }
            catch { self.error = error.localizedDescription }
            isLoading = false
        }
    }

    private func content(_ d: MerchantOrderDetail) -> some View {
        List {
            Section {
                LabeledContent("订单号", value: d.orderNumber)
                HStack { Text("状态"); Spacer(); StatusBadge(status: d.status) }
                LabeledContent("下单时间", value: formatDate(d.createdAt))
            }
            Section("商品") {
                ForEach(d.items) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.subheadline)
                            HStack(spacing: 6) {
                                if let size = item.selectedSize, !size.isEmpty {
                                    Text("尺码 \(size)").font(.caption).foregroundStyle(.secondary)
                                }
                                Text("¥\(item.unitPrice.description) × \(item.quantity)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text("¥\(item.totalPrice.description)").font(.subheadline).bold()
                    }
                }
            }
            Section {
                LabeledContent("货值合计", value: "¥\(d.itemsTotal.description)")
                    .bold()
            } footer: {
                Text("买家收货信息与配送由接单代购人负责，不向店铺展示")
            }
        }
        .listStyle(.insetGrouped)
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
