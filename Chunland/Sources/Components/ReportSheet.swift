import SwiftUI
import ChunlandCore

/// 可复用举报面板。各入口 `.sheet(isPresented:)` 弹出，传 targetType/targetKey（AI 另传 snapshot）。
/// 自包含：理由选择 + 选填说明 + 提交 + 成功反馈后自动关闭，不依赖父视图的 toast。
struct ReportSheet: View {
    let targetType: ReportTargetType
    var targetKey: String? = nil
    var snapshot: String? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var reason: ReportReason = .illegal
    @State private var detail = ""
    @State private var submitting = false
    @State private var submitted = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if submitted {
                    successView
                } else {
                    formView
                }
            }
            .navigationTitle("举报")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !submitted {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("提交") { submit() }.disabled(submitting)
                    }
                }
            }
        }
    }

    private var formView: some View {
        Form {
            Section("举报理由") {
                Picker("理由", selection: $reason) {
                    ForEach(ReportReason.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section("补充说明（选填）") {
                TextField("可描述具体情况", text: $detail, axis: .vertical)
                    .lineLimit(3...6)
            }
            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
        }
        .disabled(submitting)
    }

    private var successView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52)).foregroundStyle(.green)
            Text("举报已提交").font(.headline)
            Text("感谢反馈，我们会尽快核实处理").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(for: .seconds(1.4))
            dismiss()
        }
    }

    private func submit() {
        submitting = true
        error = nil
        Task {
            do {
                try await ReportService.shared.submit(
                    targetType: targetType, targetKey: targetKey,
                    reason: reason, detail: detail, snapshot: snapshot
                )
                await MainActor.run { submitting = false; submitted = true }
            } catch {
                await MainActor.run {
                    submitting = false
                    self.error = error.localizedDescription
                }
            }
        }
    }
}
