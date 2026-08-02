import SwiftUI
import ChunlandCore

// 开店（自建商家）：店铺名 + 发货地区县（驱动距离定价，可选）。
// 提交 = 建店 + 授予商家身份 + 重签 token（AuthManager.openMerchantStore），成功即切商家视图。
struct OpenStoreView: View {
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var areaPick: RegionPick?
    @State private var showRegionPicker = false
    @State private var busy = false
    @State private var error: String?

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !busy
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("店铺信息") {
                    TextField("店铺名（必填）", text: $name)
                    Button {
                        showRegionPicker = true
                    } label: {
                        HStack {
                            Text("发货地")
                            Spacer()
                            Text(areaPick.map { "\($0.province.name) \($0.city.name) \($0.area.name)" } ?? "选择区县（可选）")
                                .foregroundStyle(areaPick == nil ? .tertiary : .secondary)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        if busy {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("开店").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text("发货地用于计算配送距离费；平台不代收货款，交易结算方式不变。开店即获得商家身份，可随时在「我的」页切换身份。")
                }
                if let error {
                    Section { Text(error).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("我要开店")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .sheet(isPresented: $showRegionPicker) {
                RegionCascadePicker { pick in
                    areaPick = pick
                    showRegionPicker = false
                }
            }
        }
    }

    private func submit() async {
        busy = true
        defer { busy = false }
        error = nil
        do {
            try await auth.openMerchantStore(
                name: name.trimmingCharacters(in: .whitespaces),
                areaCode: areaPick?.areaCode
            )
            dismiss()   // activeIdentity 已切 merchant，MainTabView 自动换商家布局
        } catch {
            self.error = error.localizedDescription
        }
    }
}
