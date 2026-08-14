import Foundation
import SQLite3

// MARK: - SQLite 连接（零依赖，直接用系统 sqlite3）
//
// 为什么不引三方封装：ChunlandCore 会被镜像到公开仓库，少一个依赖就少一份
// 许可与同步负担；而我们用到的只是「建表、增删改查、事务、FTS」，
// 系统 API 足够，封一层薄壳即可。
//
// 为什么是 actor：sqlite3 的连接句柄不是 Sendable，写操作必须串行。
// actor 天然给出串行执行域，比自己维护队列 + @unchecked Sendable 更安全。
// 本地 SQLite 的单次读写在微秒级，同步阻塞 actor 执行器没有实际代价。

/// SQLite 绑定值。
public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    public init(_ v: Int) { self = .int(Int64(v)) }
    public init(_ v: Int64) { self = .int(v) }
    public init(_ v: Double) { self = .double(v) }
    public init(_ v: String) { self = .text(v) }
    public init(_ v: Bool) { self = .int(v ? 1 : 0) }
    public init(_ v: Data) { self = .blob(v) }

    /// 可空便利构造 —— 业务侧大量字段可空，避免每处写三元表达式。
    public init(_ v: String?) { self = v.map { .text($0) } ?? .null }
    public init(_ v: Int?)    { self = v.map { .int(Int64($0)) } ?? .null }
    public init(_ v: Int64?)  { self = v.map { .int($0) } ?? .null }
    public init(_ v: Bool?)   { self = v.map { .int($0 ? 1 : 0) } ?? .null }

    public var stringValue: String? {
        if case .text(let s) = self { return s }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let i):    return Int(i)
        case .double(let d): return Int(d)
        case .text(let s):   return Int(s)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i):    return Double(i)
        case .text(let s):   return Double(s)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        guard let i = intValue else { return nil }
        return i != 0
    }

    public var dataValue: Data? {
        if case .blob(let d) = self { return d }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

/// 查询结果的一行。
///
/// `columns` 在同一次查询的所有行之间共享同一份字典存储（Swift 的写时复制），
/// 所以每行多带一个映射表不产生额外开销。
public struct SQLRow: Sendable {
    public let columns: [String: Int]
    public let values: [SQLValue]

    public subscript(name: String) -> SQLValue? {
        guard let i = columns[name], i < values.count else { return nil }
        return values[i]
    }

    public func string(_ name: String) -> String? { self[name]?.stringValue }
    public func int(_ name: String) -> Int? { self[name]?.intValue }
    public func double(_ name: String) -> Double? { self[name]?.doubleValue }
    public func bool(_ name: String) -> Bool? { self[name]?.boolValue }
    public func data(_ name: String) -> Data? { self[name]?.dataValue }

    /// 毫秒时间戳列 → Date。
    public func date(_ name: String) -> Date? {
        guard let ms = self[name]?.intValue else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }
}

public enum AIDatabaseError: LocalizedError {
    case openFailed(String)
    case prepareFailed(sql: String, message: String)
    case stepFailed(sql: String, message: String)
    case schemaTooNew(found: Int, supported: Int)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let m):
            return "无法打开 AI 会话库：\(m)"
        case .prepareFailed(let sql, let m):
            return "SQL 准备失败：\(m)\n语句：\(sql.prefix(200))"
        case .stepFailed(let sql, let m):
            return "SQL 执行失败：\(m)\n语句：\(sql.prefix(200))"
        case .schemaTooNew(let found, let supported):
            return "会话库版本 \(found) 高于本版本支持的 \(supported)，请升级 App"
        }
    }
}

/// 传给 sqlite3_bind_* 的析构器：告诉 SQLite 复制一份数据，
/// 因为 Swift 的字符串/数据缓冲区在调用返回后就可能失效。
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public actor AIDatabase {

    private var handle: OpaquePointer?
    private let path: String
    private let logger = AppLogger(subsystem: AppLogger.subsystem, category: "ai.storage")

    /// 库文件与媒体目录的根。
    ///
    /// 放 Application Support 而不是 Caches：会话是用户数据，系统不能在存储紧张时清掉。
    public static var rootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("chunland-ai", isDirectory: true)
    }

    public static var databaseURL: URL {
        rootDirectory.appendingPathComponent("ai.sqlite")
    }

    public init(path: String? = nil) {
        self.path = path ?? Self.databaseURL.path
    }

    // MARK: - 生命周期

    /// 打开连接、应用 pragma、建表。幂等，可重复调用。
    public func open() throws {
        guard handle == nil else { return }

        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            sqlite3_close_v2(db)
            throw AIDatabaseError.openFailed(msg)
        }
        handle = db

        for pragma in AISchema.pragmas {
            try executeRaw(pragma)
        }
        try bootstrap()
    }

    public func close() {
        guard let db = handle else { return }
        sqlite3_close_v2(db)
        handle = nil
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    /// 建表 / 版本校验。
    private func bootstrap() throws {
        let current = try schemaVersion()
        if current > AISchema.version {
            throw AIDatabaseError.schemaTooNew(found: current, supported: AISchema.version)
        }
        guard current < AISchema.version else { return }

        try transaction { db in
            if current == 0 {
                for sql in AISchema.bootstrapStatements { try db.executeRaw(sql) }
            } else {
                // 已有库：只重建检索索引，**会话历史保留**。
                // 分词规则或索引结构变了都走这条路 —— 索引可以从消息重算出来，
                // 对话本身不能。整库 drop 虽然更简单，但那是拿用户历史换省事。
                try db.executeRaw("DROP TABLE IF EXISTS parts_fts;")
                try db.executeRaw("DROP TABLE IF EXISTS part_search;")
                for sql in AISchema.bootstrapStatements { try db.executeRaw(sql) }
                try Self.reindexSearch(db)
            }
            try db.setSchemaVersion(AISchema.version)
        }
        logger.info("AI 会话库已初始化", metadata: ["version": "\(AISchema.version)"])
    }

    /// 从 message_parts 重算检索索引。
    ///
    /// 分词只能在应用层做（SQL 里表达不了），所以升级时逐行读出来重新分词。
    /// 消息量级是几千行，一次几十毫秒。
    private static func reindexSearch(_ db: isolated AIDatabase) throws {
        let rows = try db.query(
            """
            SELECT p.id AS pid, p.message_id AS mid, m.session_id AS sid, p.text AS txt
            FROM message_parts p
            JOIN messages m ON m.id = p.message_id
            WHERE p.kind = 'text' AND p.text IS NOT NULL
            """
        )
        for row in rows {
            guard let pid = row.string("pid"), let mid = row.string("mid"),
                  let sid = row.string("sid"), let txt = row.string("txt") else { continue }
            let seg = AITextSegmenter.segment(txt)
            guard !seg.isEmpty else { continue }
            try db.execute(
                """
                INSERT OR REPLACE INTO part_search (part_id, message_id, session_id, seg)
                VALUES (?, ?, ?, ?)
                """,
                [.text(pid), .text(mid), .text(sid), .text(seg)]
            )
        }
    }

    private func schemaVersion() throws -> Int {
        try query("PRAGMA user_version;").first?.values.first?.intValue ?? 0
    }

    private func setSchemaVersion(_ v: Int) throws {
        // pragma 不支持参数绑定，只能拼接；v 是本文件的常量，无注入面。
        try executeRaw("PRAGMA user_version = \(v);")
    }

    // MARK: - 执行

    /// 执行语句，返回影响行数。
    ///
    /// 返回行数而不是另开一个 `changes()` 方法：两次独立的 actor 调用之间
    /// 可以插入其他任务，分开取会读到别人的行数。
    @discardableResult
    public func execute(_ sql: String, _ binds: [SQLValue] = []) throws -> Int {
        _ = try run(sql, binds, collectRows: false)
        guard let db = handle else { return 0 }
        return Int(sqlite3_changes(db))
    }

    /// 执行查询并返回全部行。
    @discardableResult
    public func query(_ sql: String, _ binds: [SQLValue] = []) throws -> [SQLRow] {
        try run(sql, binds, collectRows: true)
    }

    /// 事务。闭包抛错则整体回滚。
    ///
    /// 闭包接收 `isolated AIDatabase` —— 这样闭包体内可以**同步**调用
    /// `execute` / `query`，中途不会让出隔离域。若闭包是普通异步闭包，
    /// 每个 `await` 都是一个重入点，别的任务可能在事务中间插进来执行 SQL，
    /// 那条 SQL 会被卷进本事务，一起提交或一起回滚。
    ///
    /// 不支持嵌套 —— 需要嵌套说明职责划分有问题，应由最外层统一开事务。
    public func transaction<T: Sendable>(_ body: (isolated AIDatabase) throws -> T) throws -> T {
        try executeRaw("BEGIN IMMEDIATE;")
        do {
            let result = try body(self)
            try executeRaw("COMMIT;")
            return result
        } catch {
            try? executeRaw("ROLLBACK;")
            throw error
        }
    }

    // MARK: - 内部

    /// 不走参数绑定的原始执行（建表 / pragma / 事务控制专用）。
    private func executeRaw(_ sql: String) throws {
        guard let db = handle else { throw AIDatabaseError.openFailed("连接未打开") }
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let m = errMsg.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(errMsg)
            throw AIDatabaseError.stepFailed(sql: sql, message: m)
        }
    }

    private func run(_ sql: String, _ binds: [SQLValue], collectRows: Bool) throws -> [SQLRow] {
        guard let db = handle else { throw AIDatabaseError.openFailed("连接未打开") }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            let m = String(cString: sqlite3_errmsg(db))
            sqlite3_finalize(stmt)
            throw AIDatabaseError.prepareFailed(sql: sql, message: m)
        }
        defer { sqlite3_finalize(stmt) }

        for (i, value) in binds.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch value {
            case .null:
                rc = sqlite3_bind_null(stmt, idx)
            case .int(let v):
                rc = sqlite3_bind_int64(stmt, idx, v)
            case .double(let v):
                rc = sqlite3_bind_double(stmt, idx, v)
            case .text(let v):
                rc = sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case .blob(let v):
                rc = v.withUnsafeBytes { raw in
                    sqlite3_bind_blob(stmt, idx, raw.baseAddress, Int32(v.count), SQLITE_TRANSIENT)
                }
            }
            guard rc == SQLITE_OK else {
                throw AIDatabaseError.prepareFailed(
                    sql: sql, message: "参数 \(idx) 绑定失败：\(String(cString: sqlite3_errmsg(db)))"
                )
            }
        }

        var columns: [String: Int] = [:]
        var rows: [SQLRow] = []
        var didReadColumns = false

        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw AIDatabaseError.stepFailed(sql: sql, message: String(cString: sqlite3_errmsg(db)))
            }
            guard collectRows else { continue }

            let count = sqlite3_column_count(stmt)
            if !didReadColumns {
                for i in 0..<count {
                    if let cName = sqlite3_column_name(stmt, i) {
                        columns[String(cString: cName)] = Int(i)
                    }
                }
                didReadColumns = true
            }

            var values: [SQLValue] = []
            values.reserveCapacity(Int(count))
            for i in 0..<count {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_NULL:
                    values.append(.null)
                case SQLITE_INTEGER:
                    values.append(.int(sqlite3_column_int64(stmt, i)))
                case SQLITE_FLOAT:
                    values.append(.double(sqlite3_column_double(stmt, i)))
                case SQLITE_BLOB:
                    if let ptr = sqlite3_column_blob(stmt, i) {
                        let n = Int(sqlite3_column_bytes(stmt, i))
                        values.append(.blob(Data(bytes: ptr, count: n)))
                    } else {
                        values.append(.blob(Data()))
                    }
                default:
                    if let c = sqlite3_column_text(stmt, i) {
                        values.append(.text(String(cString: c)))
                    } else {
                        values.append(.null)
                    }
                }
            }
            rows.append(SQLRow(columns: columns, values: values))
        }
        return rows
    }
}

// MARK: - 时间工具
//
// 全库统一 epoch 毫秒，双端一致。

public extension Date {
    var epochMillis: Int64 { Int64(timeIntervalSince1970 * 1000) }

    init(epochMillis: Int64) {
        self.init(timeIntervalSince1970: Double(epochMillis) / 1000)
    }
}
