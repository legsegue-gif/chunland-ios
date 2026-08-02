import SwiftUI
import PhotosUI
import UIKit
import ChunlandCore

// 店铺动态：商家自发图文，进平台发现/关注流。列表 + 左滑删除 + ➕ 发布。
struct MerchantPostsView: View {
    @State private var posts: [MerchantPost] = []
    @State private var hasLoaded = false
    @State private var error: String?
    @State private var showCompose = false
    @State private var toast: String?

    var body: some View {
        Group {
            if !hasLoaded {
                ProgressView()
            } else if posts.isEmpty {
                ScrollView {
                    emptyOrErrorView
                        .containerRelativeFrame([.horizontal, .vertical])
                }
                .refreshable { await load() }
            } else {
                List {
                    ForEach(posts) { post in
                        postRow(post)
                    }
                }
                .listStyle(.plain)
                .refreshable { await load() }
            }
        }
        .navigationTitle("店铺动态")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCompose = true } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("发动态")
            }
        }
        .sheet(isPresented: $showCompose) {
            MerchantPostComposeView { await load() }
        }
        .overlay(alignment: .top) { toastView }
        .task { await load() }
    }

    @ViewBuilder
    private var emptyOrErrorView: some View {
        if let error {
            ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
        } else {
            ContentUnavailableView("还没有动态", systemImage: "megaphone",
                description: Text("发布新品、活动，让关注你店铺的买家在「发现」里看到"))
        }
    }

    private func postRow(_ post: MerchantPost) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let text = post.text, !text.isEmpty {
                Text(text).font(.subheadline).lineLimit(3)
            }
            if !post.media.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(post.media, id: \.url) { m in
                            CachedAsyncImage(url: URL(string: m.url)) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Color(.systemGray5)
                            }
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            Text(formatDate(post.publishedAt))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
            Button("删除", role: .destructive) {
                Task { await remove(post) }
            }
        }
    }

    private func remove(_ post: MerchantPost) async {
        do {
            try await MerchantConsoleService.shared.deletePost(id: post.id)
            await load()
            showToast("已删除")
        } catch {
            showToast("删除失败：\(error.localizedDescription)")
        }
    }

    private func load() async {
        error = nil
        do {
            posts = try await MerchantConsoleService.shared.posts()
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
        out.dateStyle = .medium
        out.timeStyle = .short
        return out.string(from: d)
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

// MARK: - 发布

// 发动态：文字 + 最多 9 图 + 可挂自家商品（可购卡：消费者在 feed 看到价格+去购买）。
// 发布 = 逐图上传拿 key → createPost 引用。
struct MerchantPostComposeView: View {
    let onDone: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var imageDatas: [Data] = []
    @State private var linkedProduct: MerchantProduct?   // 挂载的商品（M4）
    @State private var showProductPicker = false
    @State private var publishing = false
    @State private var error: String?

    private var canPublish: Bool {
        (!text.trimmingCharacters(in: .whitespaces).isEmpty || !imageDatas.isEmpty) && !publishing
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("说点什么…（新品、活动、到货通知）", text: $text, axis: .vertical)
                        .lineLimit(4...10)
                }
                Section {
                    if !imageDatas.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(imageDatas.enumerated()), id: \.offset) { idx, data in
                                    if let ui = UIImage(data: data) {
                                        Image(uiImage: ui)
                                            .resizable().scaledToFill()
                                            .frame(width: 72, height: 72)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
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
                    PhotosPicker(selection: $pickedItems, maxSelectionCount: 9, matching: .images) {
                        Label("添加图片（最多 9 张）", systemImage: "photo.on.rectangle.angled")
                    }
                } footer: {
                    Text("发布后会出现在平台「发现」流，关注你店铺的买家也会在「正在关注」看到")
                }
                Section {
                    if let p = linkedProduct {
                        HStack(spacing: 10) {
                            CachedAsyncImage(url: URL(string: p.thumbnail ?? "")) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Color(.systemGray5)
                            }
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.subheadline).lineLimit(1)
                                if let price = p.price {
                                    Text("¥\(price.description)").font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            Button {
                                linkedProduct = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        Button { showProductPicker = true } label: {
                            Label("挂载商品（买家可点卡片直接购买）", systemImage: "tag")
                        }
                    }
                } footer: {
                    if linkedProduct != nil {
                        Text("买家在动态卡片上会看到价格与「去购买」，点击直达商品详情")
                    }
                }
                if let error {
                    Section { Text(error).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("发动态")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if publishing {
                        ProgressView()
                    } else {
                        Button("发布") { Task { await publish() } }
                            .disabled(!canPublish)
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
            .sheet(isPresented: $showProductPicker) {
                LinkProductPicker { p in
                    linkedProduct = p
                    showProductPicker = false
                }
            }
        }
    }

    private func publish() async {
        publishing = true
        defer { publishing = false }
        error = nil
        do {
            var keys: [String] = []
            for data in imageDatas {
                guard let ui = UIImage(data: data),
                      let jpeg = ui.jpegData(compressionQuality: 0.75) else { continue }
                let img = try await MerchantConsoleService.shared.uploadPostImage(jpeg: jpeg)
                keys.append(img.key)
            }
            let body = text.trimmingCharacters(in: .whitespaces)
            _ = try await MerchantConsoleService.shared.createPost(
                text: body.isEmpty ? nil : body, mediaKeys: keys,
                productCode: linkedProduct?.code)
            await onDone()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 挂商品选择器（在售商品单选）

private struct LinkProductPicker: View {
    let onSelect: (MerchantProduct) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var products: [MerchantProduct] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else if let error {
                    ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
                } else if products.isEmpty {
                    ContentUnavailableView("没有在售商品", systemImage: "tag",
                        description: Text("先在店铺页上架商品"))
                } else {
                    List(products) { p in
                        Button { onSelect(p) } label: {
                            HStack(spacing: 10) {
                                CachedAsyncImage(url: URL(string: p.thumbnail ?? "")) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    Color(.systemGray5)
                                }
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name).font(.subheadline).lineLimit(2)
                                    if let price = p.price {
                                        Text("¥\(price.description)").font(.caption).foregroundStyle(.orange)
                                    }
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("选择商品")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .task {
                do {
                    // 只给在售商品挂卡（下架商品消费者点进去买不了）
                    products = try await MerchantConsoleService.shared.products().filter(\.purchasable)
                } catch {
                    self.error = error.localizedDescription
                }
                isLoading = false
            }
        }
    }
}
