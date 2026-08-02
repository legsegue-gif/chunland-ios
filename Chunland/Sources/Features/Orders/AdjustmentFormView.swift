import SwiftUI
import ChunlandCore

// 代购人发起改单（单商品 MVP）。选一个商品 + 处理方式（缺货移除/改数量/降价）。
// 预览金额本地按当前 per-merchant 费率镜像服务端改单计算（最终以提交结果为准）。
struct AdjustmentFormView: View {
    let order: OrderDetail
    let store: OrderDetailStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedItemId: Int?
    @State private var action: String = "remove"      // remove / reduce_qty / change_price
    @State private var newPriceText = ""
    @State private var newQty = 0
    @State private var note = ""
    @State private var submitting = false
    @State private var error: String?

    private var selectedItem: OrderItem? {
        order.items.first { $0.id == selectedItemId }
    }

    var body: some View {
        NavigationStack {
            Form {
                itemSection
                actionSection
                previewSection
                Section("备注（可选）") {
                    TextField("如：现货只剩特价款 / 这款断货了", text: $note, axis: .vertical)
                        .lineLimit(1...3)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle("发起改单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await submit() } } label: {
                        if submitting { ProgressView() } else { Text("提交").bold() }
                    }
                    .disabled(submitting || !canSubmit)
                }
            }
            .task {
                if let m = order.merchantId { await ConfigStore.shared.loadIfNeeded(merchant: m) }
                if selectedItemId == nil { selectedItemId = order.items.first?.id }
            }
        }
    }

    private var itemSection: some View {
        Section("选择商品") {
            ForEach(order.items) { item in
                Button {
                    selectedItemId = item.id
                    resetForItem(item)
                } label: {
                    HStack {
                        Image(systemName: selectedItemId == item.id ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selectedItemId == item.id ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.productSnapshot.name).foregroundStyle(.primary)
                            Text("¥\(money(item.unitPrice)) × \(item.quantity)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        Section("处理方式") {
            Picker("处理方式", selection: $action) {
                Text("缺货移除").tag("remove")
                Text("改数量").tag("reduce_qty")
                Text("降价").tag("change_price")
            }
            .pickerStyle(.segmented)

            if action == "reduce_qty", let item = selectedItem {
                Stepper("新数量：\(newQty)", value: $newQty, in: 0...max(0, item.quantity - 1))
            }
            if action == "change_price" {
                HStack {
                    Text("新单价")
                    Spacer()
                    TextField("0.00", text: $newPriceText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 120)
                    Text("元").foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        if let p = previewTotals() {
            Section("金额预览") {
                LabeledContent("原合计", value: "¥\(money(order.totalAmount))")
                LabeledContent("新合计", value: "¥\(money(p.newTotal))")
                LabeledContent("预计退款", value: "¥\(money(p.refund))")
                if p.upward {
                    Text("改单导致金额上调（需消费者补款）暂不支持")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Logic

    private var kind: String {
        action == "change_price" ? "price_change" : "out_of_stock"
    }

    private var canSubmit: Bool {
        guard selectedItem != nil else { return false }
        guard let p = previewTotals(), !p.upward else { return false }
        if action == "change_price" {
            guard let v = Decimal(string: newPriceText), v >= 0 else { return false }
        }
        return true
    }

    private func resetForItem(_ item: OrderItem) {
        newQty = max(0, item.quantity - 1)
        newPriceText = ""
    }

    // 本地镜像服务端改单计算（仅预览）
    private func previewTotals() -> (newTotal: Decimal, refund: Decimal, upward: Bool)? {
        guard let sel = selectedItem else { return nil }
        var newItems: Decimal = 0
        for it in order.items {
            if it.id == sel.id {
                switch action {
                case "remove": break
                case "reduce_qty": newItems += it.unitPrice * Decimal(newQty)
                case "change_price":
                    let p = Decimal(string: newPriceText) ?? it.unitPrice
                    newItems += p * Decimal(it.quantity)
                default: newItems += it.unitPrice * Decimal(it.quantity)
                }
            } else {
                newItems += it.unitPrice * Decimal(it.quantity)
            }
        }
        let pRate = ConfigStore.shared.platformFeeRate(merchant: order.merchantId)
        let aRate = ConfigStore.shared.agentFeeRate(merchant: order.merchantId)
        let newTotal = round2(round2(newItems) + round2(newItems * pRate) + round2(newItems * aRate))
        let delta = newTotal - order.totalAmount
        return (newTotal, max(0, -delta), delta > 0)
    }

    private func submit() async {
        guard let item = selectedItem else { return }
        error = nil
        submitting = true
        defer { submitting = false }

        let result: String?
        switch action {
        case "remove":
            result = await store.proposeAdjustment(
                itemId: item.id, kind: kind, action: "remove",
                note: note.isEmpty ? nil : note)
        case "reduce_qty":
            result = await store.proposeAdjustment(
                itemId: item.id, kind: kind, action: "reduce_qty",
                newQuantity: newQty, note: note.isEmpty ? nil : note)
        case "change_price":
            result = await store.proposeAdjustment(
                itemId: item.id, kind: kind, action: "change_price",
                newUnitPrice: Decimal(string: newPriceText) ?? 0, note: note.isEmpty ? nil : note)
        default:
            result = nil
        }
        if let result { error = result } else { dismiss() }
    }

    // MARK: - Format

    private func money(_ d: Decimal) -> String {
        String(format: "%.2f", NSDecimalNumber(decimal: d).doubleValue)
    }
    private func round2(_ d: Decimal) -> Decimal {
        var input = d, result = Decimal()
        NSDecimalRound(&result, &input, 2, .plain)
        return result
    }
}
