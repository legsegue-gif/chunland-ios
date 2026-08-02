import SwiftUI
import PhotosUI
import UIKit
import ChunlandCore

// 建品 / 编辑商品（补全：多图相册、尺码、库存开关）。
// 图片两步式：保存时逐张上传拿 key → PUT 整体挂载（keys[0] 为主图）。
// 重新选图 = 整组替换（服务端语义如此，UI 明示）。
struct ProductFormView: View {
    let product: MerchantProduct?          // nil = 新建
    let onDone: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var priceText: String
    @State private var descriptionText: String
    @State private var sizesText: String            // 逗号/空格分隔 → [String]
    @State private var purchasable: Bool
    @State private var inStock: Bool
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var imageDatas: [Data] = []      // 新选的整组图（非空则保存时替换全部）
    @State private var saving = false
    @State private var error: String?

    init(product: MerchantProduct?, onDone: @escaping () async -> Void) {
        self.product = product
        self.onDone = onDone
        _name = State(initialValue: product?.name ?? "")
        _priceText = State(initialValue: product?.price.map { "\($0)" } ?? "")
        _descriptionText = State(initialValue: product?.description ?? "")
        _sizesText = State(initialValue: product?.sizes?.joined(separator: " ") ?? "")
        _purchasable = State(initialValue: product?.purchasable ?? true)
        _inStock = State(initialValue: product?.stockStatus != "outOfStock")
    }

    private var parsedPrice: Decimal? {
        Decimal(string: priceText.trimmingCharacters(in: .whitespaces))
    }

    private var parsedSizes: [String] {
        sizesText.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == " " })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && parsedPrice != nil && parsedPrice! > 0
            && !saving
    }

    var body: some View {
        NavigationStack {
            Form {
                imagesSection
                Section("基本信息") {
                    TextField("商品名（必填）", text: $name)
                    TextField("价格（元，必填）", text: $priceText)
                        .keyboardType(.decimalPad)
                    TextField("描述（可选）", text: $descriptionText, axis: .vertical)
                        .lineLimit(3...6)
                    TextField("尺码/规格（空格分隔，如 S M L，可选）", text: $sizesText)
                        .autocorrectionDisabled()
                }
                if product != nil {
                    Section {
                        Toggle("上架销售", isOn: $purchasable)
                        Toggle("有货", isOn: $inStock)
                    } footer: {
                        Text("下架后商品不再出现在商城；缺货仍展示但排序靠后，历史订单均不受影响")
                    }
                }
                if let error {
                    Section { Text(error).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle(product == nil ? "新增商品" : "编辑商品")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("保存") { Task { await save() } }
                            .disabled(!canSave)
                    }
                }
            }
            .onChange(of: pickedItems) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    for item in items {
                        if imageDatas.count >= 9 { break }
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            imageDatas.append(data)
                        }
                    }
                    pickedItems = []
                }
            }
        }
    }

    // MARK: - 商品图（多图）

    @ViewBuilder
    private var imagesSection: some View {
        Section {
            if !imageDatas.isEmpty {
                newImagesStrip
            } else if let product, !product.gallery.isEmpty {
                existingGalleryStrip(product.gallery)
            }
            let pickLabel = imageDatas.isEmpty ? "选择图片（最多 9 张）" : "重新选择"
            PhotosPicker(selection: $pickedItems, maxSelectionCount: 9, matching: .images) {
                Label(pickLabel, systemImage: "photo.on.rectangle.angled")
            }
        } header: {
            Text("商品图")
        } footer: {
            if product != nil && !imageDatas.isEmpty {
                Text("保存后将以新选的 \(imageDatas.count) 张图整体替换原有图片，第 1 张为主图")
            } else {
                Text("第 1 张为主图（列表缩略图）")
            }
        }
    }

    private var newImagesStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(imageDatas.enumerated()), id: \.offset) { idx, data in
                    if let ui = UIImage(data: data) {
                        Image(uiImage: ui)
                            .resizable().scaledToFill()
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(alignment: .bottomLeading) {
                                if idx == 0 {
                                    Text("主图").font(.caption2).bold()
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(Color.accentColor)
                                        .foregroundStyle(.white)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                        .padding(3)
                                }
                            }
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    imageDatas.remove(at: idx)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .offset(x: 6, y: -6)
                            }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func existingGalleryStrip(_ gallery: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(gallery.enumerated()), id: \.offset) { idx, url in
                    CachedAsyncImage(url: URL(string: url)) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color(.systemGray5)
                    }
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .bottomLeading) {
                        if idx == 0 {
                            Text("主图").font(.caption2).bold()
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.85))
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .padding(3)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - 保存

    private func save() async {
        guard let price = parsedPrice else { return }
        saving = true
        defer { saving = false }
        error = nil
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let desc = descriptionText.trimmingCharacters(in: .whitespaces)
        let sizes = parsedSizes
        do {
            let saved: MerchantProduct
            if let product {
                saved = try await MerchantConsoleService.shared.updateProduct(
                    code: product.code, name: trimmedName, price: price,
                    description: desc.isEmpty ? nil : desc, purchasable: purchasable,
                    sizes: sizes,
                    stockStatus: inStock ? "inStock" : "outOfStock")
            } else {
                saved = try await MerchantConsoleService.shared.createProduct(
                    name: trimmedName, price: price, description: desc.isEmpty ? nil : desc,
                    sizes: sizes.isEmpty ? nil : sizes)
            }
            if !imageDatas.isEmpty {
                var keys: [String] = []
                for data in imageDatas {
                    guard let ui = UIImage(data: data),
                          let jpeg = ui.jpegData(compressionQuality: 0.75) else { continue }
                    let img = try await MerchantConsoleService.shared.uploadProductAsset(jpeg: jpeg)
                    keys.append(img.key)
                }
                _ = try await MerchantConsoleService.shared.setProductImages(code: saved.code, keys: keys)
            }
            await onDone()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
