import Foundation
import Observation

// 当前用户的关注集合缓存（频道 + 商家）。供 FollowButton 判态、following tab 判空。
// 内部以 "type:key"（如 "channel:123456" / "merchant:2"）为成员，O(1) 命中。
// 乐观更新 + 失败回滚，mutator 返回 String?（nil=成功，非 nil 是给 UI 的 toast）。
@MainActor
@Observable
public final class FollowStore {
    public static let shared = FollowStore()

    public private(set) var keys: Set<String> = []
    public private(set) var isLoaded = false

    private init() {}

    private func member(_ type: FollowTargetType, _ key: String) -> String { "\(type.rawValue):\(key)" }

    public func isFollowing(type: FollowTargetType, key: String) -> Bool {
        keys.contains(member(type, key))
    }

    /// 有任一 feed 订阅（channel/merchant）—— following tab 判空用。
    /// 商品收藏（product）不产生 feed 内容，刻意不算：只收藏了商品时 following 仍显示引导态。
    public var hasAnyFollow: Bool {
        keys.contains { $0.hasPrefix("channel:") || $0.hasPrefix("merchant:") }
    }

    public func loadIfNeeded() async {
        if isLoaded { return }
        await reload()
    }

    public func reload() async {
        do {
            let list = try await FeedService.shared.follows()
            keys = Set(list.map { "\($0.targetType):\($0.targetKey)" })
            isLoaded = true
        } catch {
            AppLogger.app.warn("FollowStore.reload failed", metadata: ["error": String(describing: error)])
        }
    }

    // 关注/取关切换。乐观更新立即反映到 UI，失败回滚并返回 toast 文案。
    @discardableResult
    public func toggle(type: FollowTargetType, key: String) async -> String? {
        let m = member(type, key)
        let wasFollowing = keys.contains(m)
        if wasFollowing { keys.remove(m) } else { keys.insert(m) }   // 乐观
        do {
            if wasFollowing {
                try await FeedService.shared.unfollow(type: type, key: key)
            } else {
                try await FeedService.shared.follow(type: type, key: key)
            }
            return nil
        } catch {
            // 回滚
            if wasFollowing { keys.insert(m) } else { keys.remove(m) }
            AppLogger.app.warn("FollowStore.toggle failed", metadata: ["error": String(describing: error)])
            return wasFollowing ? "取消关注失败，请重试" : "关注失败，请重试"
        }
    }

    public func reset() {
        keys = []
        isLoaded = false
    }
}
