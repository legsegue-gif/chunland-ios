import SwiftUI
import UIKit

// MARK: - 图片加载器（进程内缓存 + 下载去重）
//
// 为什么不用裸 SwiftUI `AsyncImage`：它在 `LazyVGrid` / `List` 里 cell 回收或重排时，
// 会取消正在进行的 URLSession 下载且**不重试**，占位是纯色 → 一旦被取消就永久停在灰块
// （表现为「列表里很多图片不显示 / 滚动后随机消失」）。`AsyncImage` 也无任何缓存，
// 每次出现都重新下载。
//
// 本加载器把「下载」与「视图等待」解耦：
//   - 下载是 actor 内的非结构化 Task，**不随视图 .task 取消而中断** → 即使 cell 被回收，
//     下载仍跑完并写入缓存，下次该 URL 出现即缓存命中、瞬时显示。
//   - NSCache 内存缓存 + URLCache 磁盘缓存；同一 URL 并发请求经 inFlight 去重，只下一次。
actor ImageLoader {
    static let shared = ImageLoader()

    private let cache = NSCache<NSURL, UIImage>()
    private var inFlight: [URL: Task<UIImage, Error>] = [:]
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 256 << 20, diskPath: "chunland_img")
        config.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: config)
        cache.countLimit = 300
    }

    /// 命中缓存直接返回；否则下载并写缓存。并发同 URL 复用同一个下载 Task。
    func image(for url: URL) async throws -> UIImage {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        if let task = inFlight[url] { return try await task.value }

        let task = Task<UIImage, Error> { [session] in
            let (data, _) = try await session.data(from: url)
            guard let img = UIImage(data: data) else {
                throw URLError(.cannotDecodeContentData)
            }
            return img
        }
        inFlight[url] = task
        defer { inFlight[url] = nil }

        let img = try await task.value
        cache.setObject(img, forKey: url as NSURL)
        return img
    }
}

// MARK: - CachedAsyncImage
//
// API 与 SwiftUI `AsyncImage` 同形（phase 闭包 + content/placeholder 双闭包两种初始化器），
// 调用点把 `AsyncImage` 改名为 `CachedAsyncImage` 即可 drop-in 替换，渲染外观完全不变。
struct CachedAsyncImage<Content: View>: View {
    private let url: URL?
    private let scale: CGFloat
    private let content: (AsyncImagePhase) -> Content

    @State private var phase: AsyncImagePhase = .empty

    init(
        url: URL?,
        scale: CGFloat = 1,
        @ViewBuilder content: @escaping (AsyncImagePhase) -> Content
    ) {
        self.url = url
        self.scale = scale
        self.content = content
    }

    var body: some View {
        content(phase)
            // id: url —— URL 不变不重新加载（cell 复用同一商品时不闪）；URL 变了才重跑。
            .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else {
            phase = .empty
            return
        }
        // 已是该 URL 的成功态就不动（.task 因无关刷新重跑时避免回退占位）。
        if case .success = phase { return }
        do {
            let uiImage = try await ImageLoader.shared.image(for: url)
            phase = .success(Image(uiImage: uiImage))
        } catch is CancellationError {
            // 视图被回收，下载仍在 actor 里跑完并缓存 —— 不改 phase。
        } catch {
            phase = .failure(error)
        }
    }
}

extension CachedAsyncImage {
    /// 双闭包形式：`CachedAsyncImage(url:) { image in … } placeholder: { … }`
    init<I: View, P: View>(
        url: URL?,
        scale: CGFloat = 1,
        @ViewBuilder content: @escaping (Image) -> I,
        @ViewBuilder placeholder: @escaping () -> P
    ) where Content == _ConditionalContent<I, P> {
        self.init(url: url, scale: scale) { phase in
            if case .success(let image) = phase {
                content(image)
            } else {
                placeholder()
            }
        }
    }
}
