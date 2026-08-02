import Foundation
import Observation

// 内容流的缓存 + keyset 分页状态。按 mode 分实例：
//  - forYou：FeedStore.shared（跨 View 共享，tab 切换不重拉）
//  - following：FeedView 持局部 FeedStore(mode: .following)（关注集变化时 reload）
@MainActor
@Observable
public final class FeedStore {
    public static let shared = FeedStore(mode: .forYou)

    public let mode: FeedMode

    public private(set) var items: [FeedItem] = []
    public private(set) var isLoading = false       // 首屏 / 刷新
    public private(set) var isLoadingMore = false    // 翻页
    public private(set) var loadMoreFailed = false   // 翻页失败 → 显示重试，避免无限转圈
    public private(set) var errorMessage: String?
    public private(set) var hasLoadedOnce = false    // 区分「未加载」与「加载后确为空」（following 空流不反复 reload）

    private var nextCursor: String?
    private var reachedEnd = false

    public init(mode: FeedMode = .forYou) {
        self.mode = mode
    }

    public var canLoadMore: Bool { !reachedEnd && nextCursor != nil }

    public func loadIfNeeded() async {
        if hasLoadedOnce { return }
        await reload()
    }

    public func reload() async {
        isLoading = true
        errorMessage = nil
        do {
            let page = try await FeedService.shared.list(mode: mode, cursor: nil)
            items = page.items
            nextCursor = page.nextCursor
            reachedEnd = page.nextCursor == nil
            hasLoadedOnce = true
        } catch {
            errorMessage = error.localizedDescription
            AppLogger.app.warn("FeedStore.reload failed", metadata: ["mode": mode.rawValue, "error": String(describing: error)])
        }
        isLoading = false
    }

    public func loadMore() async {
        guard canLoadMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        loadMoreFailed = false
        do {
            let page = try await FeedService.shared.list(mode: mode, cursor: nextCursor)
            items += page.items
            nextCursor = page.nextCursor
            reachedEnd = page.nextCursor == nil
        } catch {
            loadMoreFailed = true   // 翻页失败不污染首屏 errorMessage
            AppLogger.app.warn("FeedStore.loadMore failed", metadata: ["mode": mode.rawValue, "error": String(describing: error)])
        }
        isLoadingMore = false
    }

    public func reset() {
        items = []
        nextCursor = nil
        reachedEnd = false
        loadMoreFailed = false
        errorMessage = nil
        hasLoadedOnce = false
    }
}
