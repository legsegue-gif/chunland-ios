import Foundation

// 0.5 feed 互动埋点缓冲：曝光去重（本会话同 item 只记一次）+ 批量节流上报。
// 失败静默（不阻塞浏览）。为后续推荐能力积累数据。
@MainActor
public final class FeedImpressionTracker {
    public static let shared = FeedImpressionTracker()

    private var seen = Set<Int>()            // 已上报曝光的 item（本会话去重）
    private var buffer: [FeedEvent] = []
    private var flushTask: Task<Void, Never>?
    private let flushThreshold = 20

    private init() {}

    public func impression(_ itemId: Int) {
        guard seen.insert(itemId).inserted else { return }
        buffer.append(FeedEvent(feedItemId: itemId, eventType: "impression"))
        scheduleFlush()
    }

    public func click(_ itemId: Int) {
        buffer.append(FeedEvent(feedItemId: itemId, eventType: "click"))
        scheduleFlush()
    }

    private func scheduleFlush() {
        if buffer.count >= flushThreshold {
            flush()
            return
        }
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    public func flush() {
        flushTask?.cancel()
        guard !buffer.isEmpty else { return }
        let batch = buffer
        buffer.removeAll()
        Task { await FeedService.shared.reportEvents(batch) }
    }
}
