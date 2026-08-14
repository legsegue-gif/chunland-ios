import SwiftUI
import ChunlandCore

// MARK: - 变更确认（批量）
//
// 旧实现一次只确认一个操作。轮次放开后（8 → 30），一个任务可能产生
// 5-10 个变更 —— 商家「按吃穿住行分类」每个分类调一次归类工具 ——
// 逐个弹窗用户会疯。
//
// 批量**不削弱安全性**：每一项的完整摘要都在，用户看到的信息量没变，
// 只是把 N 次点击压成 1 次。取消 = 整批取消，不存在「同意一半」——
// 半批执行会让数据处在模型没预期的中间状态。

struct MutationConfirmSheet: View {
    let intents: [AgentMutationIntent]
    let onDecision: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(intents.enumerated()), id: \.element.id) { index, intent in
                        row(index: index, intent: intent)
                    }
                } header: {
                    Text(intents.count == 1 ? "AI 想执行以下操作" : "AI 想执行以下 \(intents.count) 项操作")
                } footer: {
                    Text("确认后将立即执行。取消则全部不执行。")
                        .font(.caption)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("确认操作")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { decide(false) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(intents.count == 1 ? "确认" : "全部确认") { decide(true) }
                        .fontWeight(.semibold)
                }
            }
            .interactiveDismissDisabled()   // 下滑关闭会让循环一直等着，必须显式选一个
        }
        .presentationDetents([.medium, .large])
    }

    private func row(index: Int, intent: AgentMutationIntent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if intents.count > 1 {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 16, alignment: .trailing)
                }
                Text(intent.summary)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !intent.details.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    // 键排序：同类操作每次展示顺序一致，用户扫一眼就能比对
                    ForEach(intent.details.keys.sorted(), id: \.self) { key in
                        HStack(alignment: .top, spacing: 6) {
                            Text(key)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(intent.details[key] ?? "")
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.leading, intents.count > 1 ? 24 : 0)
            }
        }
        .padding(.vertical, 2)
    }

    private func decide(_ approved: Bool) {
        onDecision(approved)
        dismiss()
    }
}
