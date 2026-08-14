import Foundation

// MARK: - 消息仓库（domain ↔ storage 映射所在）
//
// 写入是 append-only：消息一旦落库就不再改，唯一的例外是卸载时替换某个片段的正文。
// 流式生成期间消息只在内存里，一轮结束时（assistant 消息 + 全部工具结果）
// 在**同一个事务**里落库 —— 半条历史比没有历史更糟，配对关系不能跨事务断开。

public struct MessageRepo: Sendable {

    private let db: AIDatabase
    private let media: MediaStore

    public init(db: AIDatabase) {
        self.db = db
        self.media = MediaStore(db: db)
    }

    /// 会话列表预览取多少字。
    private static let previewLength = 60

    // MARK: - 写

    /// 追加一批消息，并在同一事务里更新会话的冗余列。
    ///
    /// 返回落库后带上 `dbId` 的消息（调用方要回填到内存历史里 ——
    /// 压缩与卸载按 id 定位消息边界，不能用数组下标，历史随时会被裁剪）。
    @discardableResult
    public func append(sessionId: String, messages: [AgentMessage]) async throws -> [AgentMessage] {
        guard !messages.isEmpty else { return [] }

        let now = Date().epochMillis
        let input = messages

        return try await db.transaction { db in
            var stored = input
            var seq = try Self.nextSeq(db, sessionId: sessionId)

            for i in stored.indices {
                let messageId = stored[i].dbId ?? UUID().uuidString
                stored[i].dbId = messageId

                try db.execute(
                    """
                    INSERT INTO messages (id, session_id, seq, role, interrupted, reasoning, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    [.text(messageId), .text(sessionId), SQLValue(seq),
                     .text(stored[i].role.rawValue), SQLValue(stored[i].isInterrupted),
                     SQLValue(stored[i].reasoning), .int(now)]
                )
                seq += 1

                for (idx, part) in stored[i].parts.enumerated() {
                    try Self.insertPart(db, sessionId: sessionId,
                                        messageId: messageId, idx: idx, part: part)
                }
            }

            // 冗余列与主表在同一事务更新，保证列表看到的计数与预览永远和消息一致。
            let preview = stored.last.map { Self.preview(of: $0) } ?? ""
            try db.execute(
                """
                UPDATE sessions
                SET message_count = message_count + ?,
                    last_preview  = ?,
                    updated_at    = ?
                WHERE id = ?
                """,
                [SQLValue(stored.count), .text(preview), .int(now), .text(sessionId)]
            )
            return stored
        }
    }

    /// 卸载：把某个片段的正文换成占位说明，并记下取回用的引用。
    ///
    /// 只改 text 与 offload_ref 两列 —— 片段的身份（配对键、类型、顺序）绝不动，
    /// 否则会破坏「调用与结果严格配对同序」这条第一约束。
    public func markOffloaded(messageId: String,
                              partIndex: Int,
                              placeholder: String,
                              ref: String) async throws {
        try await db.execute(
            """
            UPDATE message_parts SET text = ?, offload_ref = ?
            WHERE message_id = ? AND idx = ?
            """,
            [.text(placeholder), .text(ref), .text(messageId), SQLValue(partIndex)]
        )
    }

    /// 清空会话的消息（会话本身保留）。
    ///
    /// 检索表的外键挂在 message_parts 上，这里删的是 messages，
    /// 级联链断在中间，必须显式删 —— 漏了会留下指向已删消息的索引行。
    public func deleteAll(sessionId: String) async throws {
        try await db.transaction { db in
            try db.execute("DELETE FROM part_search WHERE session_id = ?;", [.text(sessionId)])
            try db.execute("DELETE FROM messages WHERE session_id = ?;", [.text(sessionId)])
            try db.execute(
                "UPDATE sessions SET message_count = 0, last_preview = NULL WHERE id = ?;",
                [.text(sessionId)]
            )
        }
    }

    // MARK: - 读

    /// 加载会话的最近 `limit` 条消息，按时间正序返回。
    ///
    /// `beforeSeq` 用于上滑加载更早：传入当前最早一条的 seq。
    public func load(sessionId: String,
                     limit: Int = 100,
                     beforeSeq: Int? = nil) async throws -> [AgentMessage] {
        let messageRows: [SQLRow]
        if let beforeSeq {
            messageRows = try await db.query(
                """
                SELECT * FROM messages WHERE session_id = ? AND seq < ?
                ORDER BY seq DESC LIMIT ?
                """,
                [.text(sessionId), SQLValue(beforeSeq), SQLValue(limit)]
            )
        } else {
            messageRows = try await db.query(
                "SELECT * FROM messages WHERE session_id = ? ORDER BY seq DESC LIMIT ?;",
                [.text(sessionId), SQLValue(limit)]
            )
        }
        guard !messageRows.isEmpty else { return [] }

        let ordered = messageRows.reversed().map { $0 }
        let ids = ordered.compactMap { $0.string("id") }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")

        let partRows = try await db.query(
            """
            SELECT * FROM message_parts WHERE message_id IN (\(placeholders))
            ORDER BY message_id, idx
            """,
            ids.map { .text($0) }
        )

        // 媒体一次性批量取，避免每个片段查一次库。
        let mediaIds = Set(partRows.compactMap { $0.string("media_id") })
        let mediaMap = try await media.find(ids: Array(mediaIds))

        var partsByMessage: [String: [AgentContentPart]] = [:]
        for row in partRows {
            guard let mid = row.string("message_id"),
                  let part = Self.decodePart(row, media: mediaMap) else { continue }
            partsByMessage[mid, default: []].append(part)
        }

        return ordered.compactMap { row -> AgentMessage? in
            guard let id = row.string("id"),
                  let roleRaw = row.string("role"),
                  let role = AgentMessage.Role(rawValue: roleRaw) else { return nil }
            return AgentMessage(
                role: role,
                parts: partsByMessage[id] ?? [],
                isInterrupted: row.bool("interrupted") ?? false,
                reasoning: row.string("reasoning"),
                dbId: id
            )
        }
    }

    /// 当前最小 seq —— 上滑分页的游标。
    public func earliestSeq(sessionId: String) async throws -> Int? {
        let rows = try await db.query(
            "SELECT MIN(seq) AS s FROM messages WHERE session_id = ?;", [.text(sessionId)]
        )
        return rows.first?.int("s")
    }

    // MARK: - 内部

    /// 事务内使用 —— `db` 是 isolated 参数，故可同步调用，不会在事务中途让出隔离域。
    private static func nextSeq(_ db: isolated AIDatabase, sessionId: String) throws -> Int {
        let rows = try db.query(
            "SELECT COALESCE(MAX(seq), -1) AS s FROM messages WHERE session_id = ?;",
            [.text(sessionId)]
        )
        return (rows.first?.int("s") ?? -1) + 1
    }

    private static func insertPart(_ db: isolated AIDatabase,
                                   sessionId: String, messageId: String,
                                   idx: Int, part: AgentContentPart) throws {
        let sql = """
            INSERT INTO message_parts
              (id, message_id, idx, kind, text, tool_use_id, tool_name, tool_input, is_error, media_id, offload_ref)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        let partId = UUID().uuidString

        switch part {
        case .text(let s):
            try db.execute(sql, [
                .text(partId), .text(messageId), SQLValue(idx),
                .text(AISchema.PartKind.text.rawValue), .text(s),
                .null, .null, .null, .null, .null, .null,
            ])
            // 只有正文进检索索引。分词无法在 SQL 触发器里做，
            // 所以检索表由这里与消息写入在同一事务内维护 —— 两者绝不会不一致。
            let seg = AITextSegmenter.segment(s)
            if !seg.isEmpty {
                try db.execute(
                    """
                    INSERT INTO part_search (part_id, message_id, session_id, seg)
                    VALUES (?, ?, ?, ?)
                    """,
                    [.text(partId), .text(messageId), .text(sessionId), .text(seg)]
                )
            }

        case .toolUse(let id, let name, let input):
            try db.execute(sql, [
                .text(partId), .text(messageId), SQLValue(idx),
                .text(AISchema.PartKind.toolUse.rawValue), .null,
                .text(id), .text(name), .text(input.jsonString()), .null, .null, .null,
            ])

        case .toolResult(let id, let name, let text, let isError, let media, let offloadRef):
            try db.execute(sql, [
                .text(partId), .text(messageId), SQLValue(idx),
                .text(AISchema.PartKind.toolResult.rawValue), .text(text),
                .text(id), .text(name), .null, SQLValue(isError),
                SQLValue(media?.id), SQLValue(offloadRef),
            ])

        case .image(let ref):
            try db.execute(sql, [
                .text(partId), .text(messageId), SQLValue(idx),
                .text(AISchema.PartKind.image.rawValue), .null,
                .null, .null, .null, .null, .text(ref.id), .null,
            ])
        }
    }

    static func decodePart(_ row: SQLRow, media: [String: MediaRef]) -> AgentContentPart? {
        guard let kindRaw = row.string("kind"),
              let kind = AISchema.PartKind(rawValue: kindRaw) else { return nil }

        switch kind {
        case .text:
            return .text(row.string("text") ?? "")

        case .toolUse:
            guard let id = row.string("tool_use_id"), let name = row.string("tool_name") else { return nil }
            return .toolUse(id: id, name: name,
                            input: AgentToolInput.parse(row.string("tool_input") ?? "{}"))

        case .toolResult:
            guard let id = row.string("tool_use_id"), let name = row.string("tool_name") else { return nil }
            return .toolResult(
                id: id, name: name,
                text: row.string("text") ?? "",
                isError: row.bool("is_error") ?? false,
                media: row.string("media_id").flatMap { media[$0] },
                offloadRef: row.string("offload_ref")
            )

        case .image:
            guard let mid = row.string("media_id"), let ref = media[mid] else { return nil }
            return .image(ref)
        }
    }

    /// 会话列表的预览文本。
    ///
    /// 只取文本片段：工具调用与结果对用户没有阅读价值，
    /// 一条纯工具消息的预览宁可为空，也不要显示一段 JSON。
    static func preview(of message: AgentMessage) -> String {
        let text = message.plainText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(previewLength))
    }
}
