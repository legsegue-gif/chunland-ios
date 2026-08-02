import SwiftUI
import PhotosUI
import UIKit
import ChunlandCore

// 店铺设置：名称 / 发货地区县（驱动距离定价，报价即时生效）/ 起送金额。
// 平台服务费率是平台收费，不在此页（不开放商家自改）。
struct StoreSettingsView: View {
    let store: MyStore
    let onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var areaPick: RegionPick?
    @State private var minOrderText: String
    @State private var showRegionPicker = false
    @State private var saving = false
    @State private var error: String?
    @State private var logoItem: PhotosPickerItem?      // logo 选图（选中即上传）
    @State private var logoUrl: String?                 // 当前 logo（上传后即时刷新）
    @State private var uploadingLogo = false

    init(store: MyStore, onSaved: @escaping () async -> Void) {
        self.store = store
        self.onSaved = onSaved
        _name = State(initialValue: store.name)
        _minOrderText = State(initialValue: store.minOrderAmount.map { "\($0)" } ?? "")
    }

    private var parsedMinOrder: Decimal? {
        let t = minOrderText.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : Decimal(string: t)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && (minOrderText.trimmingCharacters(in: .whitespaces).isEmpty || parsedMinOrder != nil)
            && !saving
    }

    var body: some View {
        Form {
            Section("店铺 logo") {
                HStack(spacing: 14) {
                    CachedAsyncImage(url: URL(string: logoUrl ?? store.logoUrl ?? "")) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color(.systemGray5).overlay {
                            Image(systemName: "storefront").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(Circle())
                    let logoPickText = uploadingLogo ? "上传中…" : "更换 logo"
                    PhotosPicker(selection: $logoItem, matching: .images) {
                        Text(logoPickText)
                    }
                    .disabled(uploadingLogo)
                }
            }
            Section {
                TextField("店铺名（必填）", text: $name)
                Button {
                    showRegionPicker = true
                } label: {
                    HStack {
                        Text("发货地")
                        Spacer()
                        Text(areaLabel)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.primary)
                TextField("起送金额（元，空 = 平台默认）", text: $minOrderText)
                    .keyboardType(.decimalPad)
            } header: {
                Text("店铺信息")
            } footer: {
                Text("发货地用于计算配送距离费，保存后新报价即时生效")
            }
            Section {
                Button {
                    Task { await save() }
                } label: {
                    if saving {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("保存").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
                .listRowInsets(EdgeInsets())
            }
            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("店铺设置")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showRegionPicker) {
            RegionCascadePicker { pick in
                areaPick = pick
                showRegionPicker = false
            }
        }
        .onChange(of: logoItem) { _, item in
            guard let item else { return }
            Task { await uploadLogo(item: item) }
        }
    }

    // logo 选中即上传（独立于「保存」——logo 是资产上传，非表单字段）
    private func uploadLogo(item: PhotosPickerItem) async {
        defer { logoItem = nil }
        uploadingLogo = true
        defer { uploadingLogo = false }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let ui = UIImage(data: data),
              let jpeg = ui.jpegData(compressionQuality: 0.8) else {
            error = "无法读取所选图片"; return
        }
        do {
            let updated = try await MerchantConsoleService.shared.uploadLogo(jpeg: jpeg)
            logoUrl = updated.logoUrl
            error = nil
        } catch {
            self.error = "logo 上传失败：\(error.localizedDescription)"
        }
    }

    private var areaLabel: String {
        if let pick = areaPick {
            return "\(pick.province.name) \(pick.city.name) \(pick.area.name)"
        }
        return store.areaCode ?? "未设置"
    }

    private func save() async {
        saving = true
        defer { saving = false }
        error = nil
        do {
            _ = try await MerchantConsoleService.shared.updateStore(
                name: name.trimmingCharacters(in: .whitespaces),
                areaCode: areaPick?.areaCode,                 // 没重选就不改
                minOrderAmount: parsedMinOrder
            )
            await onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
