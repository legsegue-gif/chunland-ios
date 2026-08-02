import SwiftUI
import ChunlandCore

struct ServerConfigSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = AppSettings.shared.serverBaseURL

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://192.168.x.x:3000/api/v1", text: $urlText)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                } header: {
                    Text("服务器地址")
                } footer: {
                    Text("真机调试时请填写开发机的局域网地址，例如 http://192.168.1.9:3000/api/v1")
                }

                Section {
                    // 清除 override，回到随构建走的默认（Debug=localhost / Release=prod 主机），并立即生效
                    Button("恢复默认") {
                        AppSettings.shared.resetServerBaseURL()
                        APIClient.shared.configure(baseURL: AppSettings.shared.serverBaseURL)
                        dismiss()
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("服务器配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
                        AppSettings.shared.serverBaseURL = trimmed
                        APIClient.shared.configure(baseURL: trimmed)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
