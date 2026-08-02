import SwiftUI
import PhotosUI
import UIKit
import ChunlandCore

// 合并采购清单（作业化）：一次进店买 N 单的作业清单。
// 按商家分节、同商品跨单聚合数量；勾选进度**本地持久化**（UserDefaults，app 切后台/杀进程不丢，
// 不落服务端——进度是个人作业状态非业务事实）；组头进度条；勾齐后引导传小票。
// 每组支持「一张小票复用上传到组内未传凭证的订单」（客户端循环调 端点，服务端零改动）。
struct PurchaseListView: View {
    @State private var list: PurchaseList?
    @State private var hasLoaded = false
    @State private var error: String?
    @State private var checked: Set<String> = []           // 已购勾选（merchantId|itemId），镜像自 UserDefaults
    @State private var receiptItem: PhotosPickerItem?      // 待上传小票
    @State private var receiptTargetGroup: Int?            // 小票归属的商家组
    @State private var uploading = false
    @State private var toast: String?
    @Environment(\.horizontalSizeClass) private var hSizeClass

    private static let checkedDefaultsKey = "purchase_checklist_checked"

    var body: some View {
        Group {
            if !hasLoaded {
                ProgressView()
            } else if let error, list == nil {
                ScrollView {
                    ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
                        .containerRelativeFrame([.horizontal, .vertical])
                }
                .refreshable { await load() }
            } else if let list, list.groups.isEmpty {
                ScrollView {
                    ContentUnavailableView("暂无待采购的订单", systemImage: "basket",
                        description: Text("接单支付后，商品会汇总到这里"))
                        .containerRelativeFrame([.horizontal, .vertical])
                }
                .refreshable { await load() }
            } else if let list {
                content(list)
            }
        }
        .frame(maxWidth: hSizeClass == .regular ? 720 : .infinity)
        .frame(maxWidth: .infinity)
        .navigationTitle("合并采购清单")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .top) { toastView }
        .task { await load() }
        .onChange(of: receiptItem) { _, item in
            guard let item, let groupId = receiptTargetGroup else { return }
            Task { await uploadReceipt(item: item, groupId: groupId) }
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private func content(_ list: PurchaseList) -> some View {
        List {
            ForEach(list.groups) { group in
                Section {
                    ForEach(group.items) { item in
                        itemRow(item, groupId: group.merchantId)
                    }
                    receiptFooter(group)
                } header: {
                    groupHeader(group)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
    }

    // 组头：商家名 + 进度（x/y 项）+ 进度条
    private func groupHeader(_ group: PurchaseList.Group) -> some View {
        let done = checkedCount(group)
        let total = group.items.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(group.merchantName)
                Spacer()
                Text(done == total && total > 0
                     ? "已购齐 \(total) 项 ✓"
                     : "已购 \(done)/\(total) 项 · \(group.orders.count) 单")
                    .font(.caption2)
                    .foregroundStyle(done == total && total > 0 ? .green : .secondary)
            }
            ProgressView(value: total > 0 ? Double(done) / Double(total) : 0)
                .tint(done == total && total > 0 ? .green : .accentColor)
        }
    }

    private func checkedCount(_ group: PurchaseList.Group) -> Int {
        group.items.filter { checked.contains("\(group.merchantId)|\($0.id)") }.count
    }

    private func isGroupComplete(_ group: PurchaseList.Group) -> Bool {
        !group.items.isEmpty && checkedCount(group) == group.items.count
    }

    private func itemRow(_ item: PurchaseList.Item, groupId: Int) -> some View {
        let key = "\(groupId)|\(item.id)"
        let isChecked = checked.contains(key)
        return Button {
            if isChecked { checked.remove(key) } else { checked.insert(key) }
            persistChecked()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isChecked ? Color.green : Color.secondary)
                CachedAsyncImage(url: URL(string: item.imageUrl ?? "")) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color(.systemGray5)
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.subheadline)
                        .lineLimit(2)
                        .strikethrough(isChecked)
                        .foregroundStyle(isChecked ? .secondary : .primary)
                    HStack(spacing: 6) {
                        if let size = item.selectedSize, !size.isEmpty {
                            Text("尺码 \(size)").font(.caption).foregroundStyle(.secondary)
                        }
                        // 跨单来源明细：知道这 N 件分属哪些单
                        Text(item.breakdown.map { "\(shortNo($0.orderNumber)) ×\($0.quantity)" }.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text("×\(item.totalQuantity)")
                    .font(.headline)
                    .foregroundStyle(isChecked ? .secondary : .primary)
            }
        }
        .buttonStyle(.plain)
    }

    // 组尾：订单凭证状态 + 一键传小票（应用到组内所有未传凭证的单）
    @ViewBuilder
    private func receiptFooter(_ group: PurchaseList.Group) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(group.orders) { order in
                HStack(spacing: 6) {
                    Image(systemName: order.hasReceipt ? "checkmark.seal.fill" : "doc.viewfinder")
                        .font(.caption)
                        .foregroundStyle(order.hasReceipt ? .green : .orange)
                    Text(shortNo(order.orderNumber)).font(.caption)
                    StatusBadge(status: order.status)
                    Spacer()
                    Text(order.hasReceipt ? "已传小票" : "待传小票")
                        .font(.caption2)
                        .foregroundStyle(order.hasReceipt ? .green : .orange)
                }
            }
            let pending = group.orders.filter { !$0.hasReceipt }
            if !pending.isEmpty {
                let complete = isGroupComplete(group)
                if complete {
                    Label("本组已购齐，传小票即可完成采购凭证", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                let isUploadingThisGroup = uploading && receiptTargetGroup == group.merchantId
                let label = isUploadingThisGroup ? "上传中…" : "传小票到 \(pending.count) 张未传凭证的单"
                PhotosPicker(selection: $receiptItem, matching: .images) {
                    Label(label, systemImage: "doc.viewfinder")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, complete ? 6 : 0)
                }
                // 勾齐后升格为主按钮（作业闭环引导：买齐 → 传小票）
                .buttonStyle(ProminentWhenComplete(isProminent: complete))
                .disabled(uploading)
                .simultaneousGesture(TapGesture().onEnded { receiptTargetGroup = group.merchantId })
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 小票复用上传（同一张图循环传到组内未传凭证的单）

    private func uploadReceipt(item: PhotosPickerItem, groupId: Int) async {
        defer { receiptItem = nil; receiptTargetGroup = nil }
        guard let group = list?.groups.first(where: { $0.merchantId == groupId }) else { return }
        let targets = group.orders.filter { !$0.hasReceipt }
        guard !targets.isEmpty else { return }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let ui = UIImage(data: data),
              let jpeg = ui.jpegData(compressionQuality: 0.7) else {
            showToast("无法读取所选图片"); return
        }
        uploading = true
        var okCount = 0
        for order in targets {
            do {
                _ = try await EvidenceService.shared.upload(orderId: order.id, jpeg: jpeg)
                okCount += 1
            } catch {
                showToast("订单 \(shortNo(order.orderNumber)) 上传失败：\(error.localizedDescription)")
            }
        }
        uploading = false
        if okCount > 0 { showToast("小票已上传到 \(okCount) 张订单") }
        await load()
    }

    // MARK: - 勾选持久化（UserDefaults；清单是个人作业状态，不上服务端）

    private func restoreChecked() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.checkedDefaultsKey) ?? []
        checked = Set(saved)
    }

    private func persistChecked() {
        UserDefaults.standard.set(Array(checked), forKey: Self.checkedDefaultsKey)
    }

    /// 清理孤儿键：订单履约完成/取消后条目离开清单，其勾选记录一并清掉（防无限膨胀）
    private func pruneChecked(against list: PurchaseList) {
        let valid = Set(list.groups.flatMap { g in g.items.map { "\(g.merchantId)|\($0.id)" } })
        let pruned = checked.intersection(valid)
        if pruned != checked {
            checked = pruned
            persistChecked()
        }
    }

    // MARK: - 加载 / 杂项

    private func load() async {
        error = nil
        if checked.isEmpty { restoreChecked() }
        do {
            let fetched = try await AgentProfileService.shared.purchaseList()
            list = fetched
            pruneChecked(against: fetched)
        } catch {
            self.error = error.localizedDescription
        }
        hasLoaded = true
    }

    /// 订单号尾 6 位：清单里全号太长，尾号足够区分
    private func shortNo(_ orderNumber: String) -> String {
        "…\(orderNumber.suffix(6))"
    }

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

// 勾齐后传小票按钮升格为主按钮；未勾齐保持普通链接样式
private struct ProminentWhenComplete: PrimitiveButtonStyle {
    let isProminent: Bool

    func makeBody(configuration: Configuration) -> some View {
        if isProminent {
            BorderedProminentButtonStyle().makeBody(configuration: configuration)
        } else {
            DefaultButtonStyle().makeBody(configuration: configuration)
        }
    }
}
