import SwiftUI
import UIKit
import ChunlandCore

// 内容详情页（商家卡走 ProductDetailView，不到这里）。完整富文本 + 大图 + 购买外链 + 优惠码。
// 链接/口令内联化（方案A）：meta.links / meta.coupons 按锚文本装回正文 —— 正文里的
// 【购买链接】直接可点开外链、淘口令点击即复制；只有正文找不到锚点的条目才回退到底部组件，信息不丢失。
struct FeedDetailView: View {
    let item: FeedItem
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var login: LoginCoordinator
    @State private var toast: String?
    @State private var showReport = false

    // 由 item 一次性推导（item 不变），避免每次 body 重算字符串匹配
    private let inline: InlineContent

    init(item: FeedItem) {
        self.item = item
        self.inline = InlineContent(item: item)
    }

    private var images: [FeedMedia] {
        item.media.filter { $0.kind == "photo" || $0.kind == "animation" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if item.text?.isEmpty == false {
                    Text(inline.text)
                        .font(.body)
                        // SwiftUI 内联链接的点击都走 openURL：拦截口令复制 scheme，其余交系统打开
                        .environment(\.openURL, OpenURLAction { url in
                            if let code = InlineContent.copyPayload(of: url) {
                                copyCoupon(code)
                                return .handled
                            }
                            return .systemAction
                        })
                }
                ForEach(images, id: \.url) { m in
                    CachedAsyncImage(url: URL(string: m.url)) { img in
                        img.resizable().scaledToFit()
                    } placeholder: {
                        Rectangle().fill(Color(.systemGray6)).frame(height: 200)
                    }
                    .cornerRadius(10)
                }
                coupons
                links
            }
            .padding()
        }
        .navigationTitle("详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("举报内容", systemImage: "flag") {
                        login.requireLogin(reason: "登录后即可举报") { showReport = true }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showReport) {
            ReportSheet(targetType: .feedItem, targetKey: String(item.id))
        }
        .overlay(alignment: .top) {
            if let toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.subheadline).bold()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.85))
                    .clipShape(Capsule())
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "paperplane.circle.fill").foregroundStyle(.blue)
            Text(item.authorName ?? item.authorHandle ?? "频道").font(.subheadline).bold()
            if let h = item.authorHandle {
                Text("@\(h)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let cid = item.channelId {
                FollowButton(type: .channel, key: String(cid))
            }
        }
    }

    // 底部回退：仅渲染正文里没匹配到锚点的口令
    @ViewBuilder
    private var coupons: some View {
        if !inline.unmatchedCoupons.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("优惠码 / 口令").font(.caption).foregroundStyle(.secondary)
                ForEach(inline.unmatchedCoupons, id: \.self) { c in
                    Button {
                        copyCoupon(c)
                    } label: {
                        HStack {
                            Text(c).font(.callout).textSelection(.enabled)
                            Spacer()
                            Image(systemName: "doc.on.doc").font(.caption)
                        }
                        .padding(8)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // 底部回退：仅渲染正文里没匹配到锚点的外链（如无 label 的裸链接）
    @ViewBuilder
    private var links: some View {
        if !inline.unmatchedLinks.isEmpty {
            VStack(spacing: 8) {
                ForEach(inline.unmatchedLinks, id: \.url) { link in
                    Button {
                        if let url = URL(string: link.url) { openURL(url) }
                    } label: {
                        HStack {
                            Image(systemName: "cart.fill")
                            Text(link.label ?? "去购买")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(10)
                    }
                }
            }
        }
    }

    private func copyCoupon(_ code: String) {
        UIPasteboard.general.string = code
        showToast("已复制口令")
    }

    private func showToast(_ msg: String) {
        toast = msg
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if toast == msg { toast = nil }
        }
    }
}

// MARK: - 内联化（方案A：label 文本匹配）

// 把 meta.links / meta.coupons 装回正文锚点：链接挂真实 URL，口令挂自定义复制 scheme。
// 匹配不到的留在 unmatched* 由底部组件回退渲染。
private struct InlineContent {
    var text = AttributedString()
    var unmatchedLinks: [FeedLink] = []
    var unmatchedCoupons: [String] = []

    private static let copyScheme = "chunland-copy"

    init(item: FeedItem) {
        var attr = AttributedString(item.text ?? "")

        for link in item.meta?.links ?? [] {
            var matched = false
            if let url = URL(string: link.url), let label = link.label, !label.isEmpty {
                // 优先连书名号整体匹配【label】（整段变蓝更醒目），退化匹配裸 label
                matched = Self.linkifyAll(&attr, needle: "【\(label)】", url: url)
                    || Self.linkifyAll(&attr, needle: label, url: url)
            }
            if !matched { unmatchedLinks.append(link) }
        }

        for coupon in item.meta?.coupons ?? [] {
            var matched = false
            if let url = Self.copyURL(coupon) {
                // 先整串匹配（ETL 即从正文切出，通常命中），退化只匹配 ￥…￥ 口令体
                matched = Self.linkifyAll(&attr, needle: coupon, url: url)
                if !matched, let token = coupon.firstMatch(of: /￥[^￥]+￥/) {
                    matched = Self.linkifyAll(&attr, needle: String(token.0), url: url)
                }
            }
            if !matched { unmatchedCoupons.append(coupon) }
        }

        text = attr
    }

    // 把 attr 中所有 needle 片段标为链接；返回是否至少命中一次
    private static func linkifyAll(_ attr: inout AttributedString, needle: String, url: URL) -> Bool {
        guard !needle.isEmpty else { return false }
        var hit = false
        var from = attr.startIndex
        while from < attr.endIndex, let r = attr[from..<attr.endIndex].range(of: needle) {
            attr[r].link = url
            hit = true
            from = r.upperBound
        }
        return hit
    }

    // 口令复制走自定义 scheme（SwiftUI Text 内联链接唯一的点击通道是 openURL）
    private static func copyURL(_ code: String) -> URL? {
        var c = URLComponents()
        c.scheme = copyScheme
        c.host = "copy"
        c.queryItems = [URLQueryItem(name: "text", value: code)]
        return c.url
    }

    static func copyPayload(of url: URL) -> String? {
        guard url.scheme == copyScheme else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "text" })?.value
    }
}
