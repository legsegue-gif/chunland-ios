import SwiftUI
import ChunlandCore

// MARK: - 会话抽屉
//
// 与旧实现的两处差别：
//
//   分页 —— 旧的把所有会话连同全部消息一次读进内存。页面 ✨ 会话按 contextKey
//          堆积（每个商品、每个订单各一条），量涨得比预期快。现在只查会话表，
//          带 message_count 与 last_preview 两个冗余列，翻到哪读到哪。
//
//   搜索 —— 旧的只能按时间倒序翻。现在可以搜「上次问的那个坚果」，
//          跨会话命中并直接跳到那条消息。

struct AgentConversationDrawer: View {

    let db: AIDatabase
    let ownerUserId: String?
    /// 选中一条会话（或搜索命中）后的回调。
    let onOpen: (String) -> Void
    /// 关闭抽屉。**不用 `@Environment(\.dismiss)`** —— 它只对 sheet/push 生效，
    /// 而这里是宿主用 offset 自绘的侧边抽屉，dismiss 拿不到可关的呈现层。
    let onClose: () -> Void

    @State private var sessions: [AISessionRecord] = []
    @State private var hits: [AISearchHit] = []
    @State private var keyword = ""
    @State private var loading = false
    @State private var reachedEnd = false
    @State private var pendingDelete: AISessionRecord?

    private var repo: SessionRepo { SessionRepo(db: db) }
    private static let pageSize = 30

    var body: some View {
        NavigationStack {
            Group {
                if keyword.isEmpty {
                    sessionList
                } else {
                    searchResults
                }
            }
            .navigationTitle("历史对话")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $keyword, prompt: "搜索对话内容")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { onClose() }
                }
            }
            .task { await loadFirstPage() }
            .onChange(of: keyword) { _, new in
                Task { await search(new) }
            }
            .confirmationDialog(
                "删除这条对话？",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let target = pendingDelete { Task { await delete(target) } }
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("删除后无法恢复。")
            }
        }
    }

    // MARK: - 会话列表

    private var sessionList: some View {
        List {
            ForEach(groupedSessions, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.items) { record in
                        Button { open(record.id) } label: { sessionRow(record) }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button("删除", role: .destructive) { pendingDelete = record }
                            }
                    }
                }
            }

            if !reachedEnd && !sessions.isEmpty {
                // 滚到底自动加载下一页 —— 不做「加载更多」按钮，
                // 会话列表是连续浏览的场景，按钮会打断节奏
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .task { await loadNextPage() }
            }

            if sessions.isEmpty && !loading {
                Text("还没有历史对话")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func sessionRow(_ record: AISessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if record.contextKey != nil {
                    // 页面 ✨ 起的会话，与主对话区分开
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
                Text(record.title)
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                Text(relativeTime(record.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let preview = record.lastPreview, !preview.isEmpty {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - 搜索结果

    private var searchResults: some View {
        List {
            if hits.isEmpty {
                Text(loading ? "搜索中…" : "没有找到包含「\(keyword)」的对话")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(hits) { hit in
                    Button { open(hit.sessionId) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(hit.sessionTitle).font(.callout).lineLimit(1)
                                Spacer()
                                Text(relativeTime(hit.updatedAt))
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            highlighted(hit.snippet)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// 命中词加粗。
    ///
    /// 在原文里定位而不是用数据库的 snippet 函数 —— 后者返回的是分词后的
    /// 文本（中文会变成「坚 果」带空格），拿来展示很难看。
    private func highlighted(_ text: String) -> Text {
        let ranges = AITextSegmenter.highlightRanges(in: text, keyword: keyword)
        guard !ranges.isEmpty else { return Text(text) }

        var result = Text("")
        var cursor = text.startIndex
        for range in ranges where range.lowerBound >= cursor {
            result = result + Text(text[cursor..<range.lowerBound])
            result = result + Text(text[range]).bold().foregroundColor(.primary)
            cursor = range.upperBound
        }
        result = result + Text(text[cursor...])
        return result
    }

    // MARK: - 分组

    private struct SessionGroup {
        let title: String
        let items: [AISessionRecord]
    }

    private var groupedSessions: [SessionGroup] {
        let calendar = Calendar.current
        var today: [AISessionRecord] = []
        var yesterday: [AISessionRecord] = []
        var earlier: [AISessionRecord] = []

        for record in sessions {
            if calendar.isDateInToday(record.updatedAt) {
                today.append(record)
            } else if calendar.isDateInYesterday(record.updatedAt) {
                yesterday.append(record)
            } else {
                earlier.append(record)
            }
        }

        return [
            SessionGroup(title: "今天", items: today),
            SessionGroup(title: "昨天", items: yesterday),
            SessionGroup(title: "更早", items: earlier),
        ].filter { !$0.items.isEmpty }
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    // MARK: - 数据

    private func loadFirstPage() async {
        loading = true
        defer { loading = false }
        sessions = (try? await repo.list(owner: ownerUserId, limit: Self.pageSize)) ?? []
        reachedEnd = sessions.count < Self.pageSize
    }

    private func loadNextPage() async {
        guard !loading, !reachedEnd else { return }
        loading = true
        defer { loading = false }
        let next = (try? await repo.list(
            owner: ownerUserId, limit: Self.pageSize, offset: sessions.count
        )) ?? []
        sessions.append(contentsOf: next)
        reachedEnd = next.count < Self.pageSize
    }

    private func search(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            hits = []
            return
        }
        loading = true
        defer { loading = false }
        hits = (try? await repo.search(owner: ownerUserId, keyword: trimmed)) ?? []
    }

    private func delete(_ record: AISessionRecord) async {
        pendingDelete = nil
        try? await repo.delete(id: record.id)
        sessions.removeAll { $0.id == record.id }
        hits.removeAll { $0.sessionId == record.id }
    }

    private func open(_ sessionId: String) {
        onOpen(sessionId)
        onClose()
    }
}
