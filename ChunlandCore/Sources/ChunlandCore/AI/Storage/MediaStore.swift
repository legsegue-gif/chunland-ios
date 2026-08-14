import Foundation
import CryptoKit

// MARK: - 媒体存储（内容寻址）
//
// 红线：**图片字节永远不进数据库、也永远不进消息**。
//
// 旧实现把图片编成 base64 文本塞进消息里，跟着会话 blob 一起被全量读进内存 ——
// 一张 1MB 照片编码后约 1.37MB，几十条带图会话就是几十 MB 常驻。
// 这里改成：字节落文件、按内容哈希命名、消息里只留一个引用。
//
// 内容寻址顺带解决去重：同一张图在不同会话里发多次，磁盘上只有一份。

public struct MediaStore: Sendable {

    private let db: AIDatabase

    public init(db: AIDatabase) {
        self.db = db
    }

    /// 媒体文件根目录。
    public static var mediaDirectory: URL {
        AIDatabase.rootDirectory.appendingPathComponent("media", isDirectory: true)
    }

    /// 从 MediaRef 还原出磁盘位置。
    public static func fileURL(for ref: MediaRef) -> URL {
        mediaDirectory.appendingPathComponent(ref.relPath)
    }

    // MARK: - 写入

    /// 保存一段媒体字节，返回可放进消息的引用。
    ///
    /// 同内容重复调用只落一次盘、只写一行 —— 直接返回已有引用。
    /// `width` / `height` 由调用方传入：解码图片是 UI 层的事，
    /// Core 不引 ImageIO 以保持与 UI 的隔离。
    @discardableResult
    public func save(_ data: Data,
                     mime: String,
                     width: Int? = nil,
                     height: Int? = nil) async throws -> MediaRef {
        let digest = SHA256.hash(data: data)
        let sha = digest.map { String(format: "%02x", $0) }.joined()

        if let existing = try await find(sha256: sha) {
            // 行在但文件被系统清掉了（极少数情况）→ 补回文件，引用不变
            let url = Self.fileURL(for: existing)
            if !FileManager.default.fileExists(atPath: url.path) {
                try writeFile(data, to: url)
            }
            return existing
        }

        let relPath = Self.relativePath(sha256: sha, mime: mime)
        try writeFile(data, to: Self.mediaDirectory.appendingPathComponent(relPath))

        let ref = MediaRef(
            id: UUID().uuidString,
            sha256: sha,
            relPath: relPath,
            mime: mime,
            bytes: data.count,
            width: width,
            height: height
        )
        try await db.execute(
            """
            INSERT INTO media (id, sha256, rel_path, mime, bytes, width, height, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(ref.id), .text(sha), .text(relPath), .text(mime),
             SQLValue(ref.bytes), SQLValue(width), SQLValue(height),
             .int(Date().epochMillis)]
        )
        return ref
    }

    // MARK: - 读取

    public func find(sha256: String) async throws -> MediaRef? {
        let rows = try await db.query(
            "SELECT * FROM media WHERE sha256 = ? LIMIT 1;", [.text(sha256)]
        )
        return rows.first.flatMap(Self.decode)
    }

    public func find(id: String) async throws -> MediaRef? {
        let rows = try await db.query(
            "SELECT * FROM media WHERE id = ? LIMIT 1;", [.text(id)]
        )
        return rows.first.flatMap(Self.decode)
    }

    /// 批量取（消息加载时一次性拿齐，避免逐条查）。
    public func find(ids: [String]) async throws -> [String: MediaRef] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let rows = try await db.query(
            "SELECT * FROM media WHERE id IN (\(placeholders));",
            ids.map { .text($0) }
        )
        var out: [String: MediaRef] = [:]
        for row in rows {
            if let ref = Self.decode(row) { out[ref.id] = ref }
        }
        return out
    }

    /// 读回字节（wire 编码时才调用 —— 只在编码那一刻把字节读进内存，用完即弃）。
    public func loadData(_ ref: MediaRef) throws -> Data {
        try Data(contentsOf: Self.fileURL(for: ref))
    }

    // MARK: - 回收
    //
    // 删会话时不立即删文件：同一张图可能被别的会话引用（内容寻址去重的代价）。
    // 改为低频 GC —— 扫出没有任何 part 引用的 media 行，删行删文件。
    // 由 App 启动后台调用，失败无所谓，下次再扫。

    @discardableResult
    public func collectGarbage() async throws -> Int {
        let rows = try await db.query(
            """
            SELECT m.id, m.rel_path FROM media m
            WHERE NOT EXISTS (SELECT 1 FROM message_parts p WHERE p.media_id = m.id)
            """
        )
        guard !rows.isEmpty else { return 0 }

        for row in rows {
            guard let id = row.string("id"), let rel = row.string("rel_path") else { continue }
            try? FileManager.default.removeItem(
                at: Self.mediaDirectory.appendingPathComponent(rel)
            )
            try await db.execute("DELETE FROM media WHERE id = ?;", [.text(id)])
        }
        return rows.count
    }

    // MARK: - 内部

    /// `ab/abcdef….jpg` —— 前两位分桶，避免单目录堆几千个文件。
    static func relativePath(sha256: String, mime: String) -> String {
        let bucket = String(sha256.prefix(2))
        return "\(bucket)/\(sha256).\(fileExtension(for: mime))"
    }

    static func fileExtension(for mime: String) -> String {
        switch mime.lowercased() {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png":  return "png"
        case "image/gif":  return "gif"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        default: return "bin"
        }
    }

    private func writeFile(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    static func decode(_ row: SQLRow) -> MediaRef? {
        guard let id = row.string("id"),
              let sha = row.string("sha256"),
              let rel = row.string("rel_path"),
              let mime = row.string("mime"),
              let bytes = row.int("bytes") else { return nil }
        return MediaRef(id: id, sha256: sha, relPath: rel, mime: mime,
                        bytes: bytes, width: row.int("width"), height: row.int("height"))
    }
}
