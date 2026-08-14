import Foundation

// MARK: - 会话元数据
//
// 注意这里**没有消息** —— 会话列表只需要这些字段。
// message_count 与 last_preview 是表里的冗余列，正是为了让列表不必碰消息表：
// 旧实现每次刷新都把所有会话的所有消息（含图片）读进内存常驻，
// 这两列 + 分页就是为了根除那个模式。

public struct AISessionRecord: Sendable, Identifiable, Equatable {
    public let id: String
    public var ownerUserId: String?
    public var title: String
    /// 页面 ✨ 会话的续聊键（如 `product:123`）；主会话为 nil。
    public var contextKey: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var messageCount: Int
    public var lastPreview: String?

    public init(id: String = UUID().uuidString,
                ownerUserId: String?,
                title: String,
                contextKey: String? = nil,
                createdAt: Date = .now,
                updatedAt: Date = .now,
                messageCount: Int = 0,
                lastPreview: String? = nil) {
        self.id = id
        self.ownerUserId = ownerUserId
        self.title = title
        self.contextKey = contextKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.lastPreview = lastPreview
    }

    /// 还没聊过 —— 关闭页面 ✨ 时据此判断要不要直接删掉，避免抽屉堆一次性死会话。
    public var isEmpty: Bool { messageCount == 0 }
}

/// 跨会话搜索命中。
public struct AISearchHit: Sendable, Identifiable, Equatable {
    public var id: String { messageId }
    public let sessionId: String
    public let sessionTitle: String
    public let messageId: String
    public let updatedAt: Date
    /// 带高亮标记的片段。
    public let snippet: String
}

// MARK: - 会话仓库

public struct SessionRepo: Sendable {

    private let db: AIDatabase

    public init(db: AIDatabase) {
        self.db = db
    }

    /// 新会话默认标题。首条用户消息落库后由调用方替换。
    public static let untitled = "新对话"

    // MARK: - 读
    //
    // ⚠️ 所有读路径都按 owner_user_id 过滤 —— 同设备换账号绝不能看到别人的历史。
    // SQL 里用 `IS ?` 而不是 `= ?`，这样 NULL（游客）也能正确匹配。

    /// 会话列表，最近在前。**只查 sessions 表**。
    public func list(owner: String?, limit: Int = 30, offset: Int = 0) async throws -> [AISessionRecord] {
        let rows = try await db.query(
            """
            SELECT * FROM sessions
            WHERE owner_user_id IS ?
            ORDER BY updated_at DESC
            LIMIT ? OFFSET ?
            """,
            [SQLValue(owner), SQLValue(limit), SQLValue(offset)]
        )
        return rows.compactMap(Self.decode)
    }

    public func count(owner: String?) async throws -> Int {
        let rows = try await db.query(
            "SELECT COUNT(*) AS n FROM sessions WHERE owner_user_id IS ?;",
            [SQLValue(owner)]
        )
        return rows.first?.int("n") ?? 0
    }

    public func find(id: String) async throws -> AISessionRecord? {
        let rows = try await db.query("SELECT * FROM sessions WHERE id = ? LIMIT 1;", [.text(id)])
        return rows.first.flatMap(Self.decode)
    }

    /// 页面 ✨ 续聊：同 contextKey 且在时间窗内的最近一条。
    ///
    /// 走 `idx_sessions_context` 一次索引查找。
    /// 同 contextKey 的近期会话。
    ///
    /// `seconds` 为 nil = **不限时间**，永远复用那一条。这不是「窗口很大」——
    /// 用一个巨大的数值会让 `now - seconds` 溢出，反而一条都匹配不上。
    /// 页面 ✨ 用有限窗口（问一半收起再打开要能接上，但隔天该是新话题）；
    /// 助手 tab 的主对话用 nil（它就是「你正在进行的那个对话」，
    /// 换新的是用户按「新对话」的显式动作）。
    public func recent(owner: String?,
                       contextKey: String,
                       within seconds: TimeInterval?) async throws -> AISessionRecord? {
        var sql = """
            SELECT * FROM sessions
            WHERE owner_user_id IS ? AND context_key = ?
            """
        var binds: [SQLValue] = [SQLValue(owner), .text(contextKey)]
        if let seconds {
            sql += " AND updated_at >= ?"
            binds.append(.int(Date().addingTimeInterval(-seconds).epochMillis))
        }
        sql += " ORDER BY updated_at DESC LIMIT 1"

        let rows = try await db.query(sql, binds)
        return rows.first.flatMap(Self.decode)
    }

    // MARK: - 写

    @discardableResult
    public func create(owner: String?,
                       title: String = SessionRepo.untitled,
                       contextKey: String? = nil) async throws -> AISessionRecord {
        let record = AISessionRecord(ownerUserId: owner, title: title, contextKey: contextKey)
        try await db.execute(
            """
            INSERT INTO sessions (id, owner_user_id, title, context_key,
                                  created_at, updated_at, message_count, last_preview)
            VALUES (?, ?, ?, ?, ?, ?, 0, NULL)
            """,
            [.text(record.id), SQLValue(owner), .text(title), SQLValue(contextKey),
             .int(record.createdAt.epochMillis), .int(record.updatedAt.epochMillis)]
        )
        return record
    }

    public func rename(id: String, title: String) async throws {
        try await db.execute(
            "UPDATE sessions SET title = ?, updated_at = ? WHERE id = ?;",
            [.text(title), .int(Date().epochMillis), .text(id)]
        )
    }

    /// 摘掉续聊键 —— 页面 ✨ 的「新对话」是归档语义：
    /// 旧会话留在抽屉里当历史，只是不再被续聊命中，新会话独占这个 key。
    public func detachContextKey(id: String) async throws {
        try await db.execute(
            "UPDATE sessions SET context_key = NULL WHERE id = ?;", [.text(id)]
        )
    }

    public func delete(id: String) async throws {
        // messages / message_parts / offloads 由外键 CASCADE 带走；
        // media 不在此处删（可能被别的会话引用），留给 MediaStore 的 GC；
        // part_search 有外键 CASCADE，但删的是 sessions 而非 message_parts，
        // 级联链断在中间，所以显式删 —— 与主表删除放同一事务。
        try await db.transaction { db in
            try db.execute("DELETE FROM part_search WHERE session_id = ?;", [.text(id)])
            try db.execute("DELETE FROM sessions WHERE id = ?;", [.text(id)])
        }
    }

    public func deleteAll(owner: String?) async throws {
        try await db.transaction { db in
            try db.execute(
                """
                DELETE FROM part_search WHERE session_id IN
                  (SELECT id FROM sessions WHERE owner_user_id IS ?)
                """,
                [SQLValue(owner)]
            )
            try db.execute("DELETE FROM sessions WHERE owner_user_id IS ?;", [SQLValue(owner)])
        }
    }

    /// 收编无主会话 —— 加属主列之前建的行归本机首个登录用户。
    /// 单人设备（绝大多数）无感保留历史；共享设备上归先登录者，可接受。
    public func adoptOrphans(to owner: String) async throws -> Int {
        try await db.execute(
            "UPDATE sessions SET owner_user_id = ? WHERE owner_user_id IS NULL;", [.text(owner)]
        )
    }

    // MARK: - 搜索
    //
    // 只索引 kind='text' 的片段（用户提问 + AI 回复正文），
    // 工具结果与入参刻意不进索引 —— 否则结果全被 JSON 和长列表淹没。

    public func search(owner: String?, keyword: String, limit: Int = 50) async throws -> [AISearchHit] {
        let patterns = AITextSegmenter.likePatterns(keyword)
        guard !patterns.isEmpty else { return [] }

        // 多个词是 AND —— 每个词一条 LIKE 条件。
        let conditions = patterns
            .map { _ in "f.seg LIKE ? ESCAPE '\(AITextSegmenter.likeEscape)'" }
            .joined(separator: " AND ")

        // 取回的是 message_parts 里的**原文**，不是索引里的分词文本 ——
        // 分词文本满是空格，拿去显示很难看，还原又会吃掉用户自己打的空格。
        // 高亮由 UI 层用 AITextSegmenter.highlightRanges 在原文里定位。
        let rows = try await db.query(
            """
            SELECT s.id         AS session_id,
                   s.title      AS session_title,
                   s.updated_at AS updated_at,
                   f.message_id AS message_id,
                   p.text       AS raw_text
            FROM part_search f
            JOIN sessions      s ON s.id = f.session_id
            JOIN message_parts p ON p.id = f.part_id
            WHERE \(conditions) AND s.owner_user_id IS ?
            ORDER BY s.updated_at DESC
            LIMIT ?
            """,
            patterns.map { SQLValue.text($0) } + [SQLValue(owner), SQLValue(limit)]
        )

        return rows.compactMap { row in
            guard let sid = row.string("session_id"),
                  let mid = row.string("message_id") else { return nil }
            return AISearchHit(
                sessionId: sid,
                sessionTitle: row.string("session_title") ?? "",
                messageId: mid,
                updatedAt: row.date("updated_at") ?? .now,
                snippet: AITextSegmenter.excerpt(from: row.string("raw_text") ?? "",
                                                 keyword: keyword)
            )
        }
    }

    // MARK: - 内部

    static func decode(_ row: SQLRow) -> AISessionRecord? {
        guard let id = row.string("id"),
              let title = row.string("title"),
              let created = row.date("created_at"),
              let updated = row.date("updated_at") else { return nil }
        return AISessionRecord(
            id: id,
            ownerUserId: row.string("owner_user_id"),
            title: title,
            contextKey: row.string("context_key"),
            createdAt: created,
            updatedAt: updated,
            messageCount: row.int("message_count") ?? 0,
            lastPreview: row.string("last_preview")
        )
    }
}
