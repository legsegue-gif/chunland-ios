import Foundation

// MARK: - 上下文卸载存储
//
// 上下文吃紧时，把历史里的大工具结果从消息中抽走：正文换成一句占位说明，
// 原文存到这里，模型需要重看时按 ref 取回。
//
// 这是对「卸载到文件系统」的变形 —— 我们不给模型文件系统，
// 所以落到表里由代码按 ref 供给，效果等价。

public struct OffloadStore: Sendable {

    private let db: AIDatabase

    public init(db: AIDatabase) {
        self.db = db
    }

    /// 占位文本的前缀。已经卸载过的片段不再重复卸载，靠它识别。
    public static let placeholderPrefix = "[内容已转存]"

    /// 生成放回消息里的占位说明。
    ///
    /// 要写清三件事：内容去哪了、有多大、怎么取回 —— 否则模型只知道「没了」，
    /// 会倾向于重新调用一遍工具（那正是卸载想省掉的开销）。
    public static func placeholder(ref: String, toolName: String?, bytes: Int) -> String {
        let who = toolName.map { "\($0) 的" } ?? ""
        return "\(placeholderPrefix)\(who)完整结果（约 \(bytes) 字节）已从当前上下文移出，"
            + "引用标识 `\(ref)`。若确需重看完整内容，用该标识取回；"
            + "多数情况下依据下文已有的摘要继续即可。"
    }

    // MARK: - 写入

    /// 卸载一段内容，返回引用标识。
    public func offload(sessionId: String, toolName: String?, content: String) async throws -> String {
        let ref = "off_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        try await db.execute(
            """
            INSERT INTO offloads (ref, session_id, tool_name, content, bytes, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [.text(String(ref)), .text(sessionId), SQLValue(toolName),
             .text(content), SQLValue(content.utf8.count), .int(Date().epochMillis)]
        )
        return String(ref)
    }

    // MARK: - 读取

    public func content(ref: String) async throws -> String? {
        let rows = try await db.query(
            "SELECT content FROM offloads WHERE ref = ? LIMIT 1;", [.text(ref)]
        )
        return rows.first?.string("content")
    }

    /// 某会话已卸载的总字节数（诊断用）。
    public func totalBytes(sessionId: String) async throws -> Int {
        let rows = try await db.query(
            "SELECT COALESCE(SUM(bytes), 0) AS total FROM offloads WHERE session_id = ?;",
            [.text(sessionId)]
        )
        return rows.first?.int("total") ?? 0
    }

    // MARK: - 清理
    //
    // 会话删除时由外键 CASCADE 自动清掉，无需手动调用。
    // 这里只提供单会话清空（清空对话但保留会话本身时用）。

    public func clear(sessionId: String) async throws {
        try await db.execute("DELETE FROM offloads WHERE session_id = ?;", [.text(sessionId)])
    }
}
