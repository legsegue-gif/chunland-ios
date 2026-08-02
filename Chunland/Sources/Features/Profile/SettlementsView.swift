import SwiftUI
import ChunlandCore

// 代购人「待结算 / 收益」。只读：展示应结算账 + 余额聚合。
// 阶段0 仅记账，实际打款另行处理（payout 为 NullPayout 占位）。
struct SettlementsView: View {
    @State private var summary: SettlementSummary?
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        Group {
            if isLoading && summary == nil {
                ProgressView()
            } else if let error, summary == nil {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            } else if let s = summary {
                content(s)
            }
        }
        .navigationTitle("待结算 / 收益")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func content(_ s: SettlementSummary) -> some View {
        List {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("待结算").font(.caption).foregroundStyle(.secondary)
                        Text("¥\(money(s.pendingTotal))").font(.title2).bold().foregroundStyle(.orange)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("已结算").font(.caption).foregroundStyle(.secondary)
                        Text("¥\(money(s.paidTotal))").font(.title3).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            } footer: {
                Text("订单完成后生成应结算账（货款返还 + 代购费）。当前为记账阶段，实际打款另行处理。")
            }

            if s.items.isEmpty {
                Section { Text("暂无结算记录").foregroundStyle(.secondary) }
            } else {
                Section("结算明细") {
                    ForEach(s.items) { row($0) }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(_ s: Settlement) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(s.orderNumber).font(.subheadline).lineLimit(1)
                Spacer()
                statusBadge(s.status)
            }
            HStack {
                Text("应得 ¥\(money(s.netPayable))").font(.callout).bold()
                Spacer()
                Text("货款 \(money(s.itemsReimburse)) + 劳务 \(money(s.agentFee))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .opacity(s.status == "VOID" ? 0.5 : 1)
    }

    @ViewBuilder
    private func statusBadge(_ status: String) -> some View {
        let info: (text: String, color: Color) = {
            switch status {
            case "PENDING": return ("待结算", .orange)
            case "PAYABLE": return ("可结算", .blue)
            case "PAID":    return ("已结算", .green)
            case "VOID":    return ("已冲销", .secondary)
            default:        return (status, .secondary)
            }
        }()
        Text(info.text).font(.caption2)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(info.color.opacity(0.15), in: Capsule())
            .foregroundStyle(info.color)
    }

    private func load() async {
        if summary == nil { isLoading = true }
        defer { isLoading = false }
        do {
            summary = try await SettlementService.shared.mine()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func money(_ d: Decimal) -> String {
        String(format: "%.2f", NSDecimalNumber(decimal: d).doubleValue)
    }
}
