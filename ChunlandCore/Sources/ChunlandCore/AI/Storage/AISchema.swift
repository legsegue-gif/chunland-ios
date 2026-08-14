import Foundation

// MARK: - AI 会话库的表结构（双端唯一真相源）
//
// ⚠️ 本文件的建表语句必须与 Android 的 AiSchema.kt **逐字一致**（除语言语法差异）。
// review 时把两个文件并排比对即可验证 —— 这是双端存储同构的唯一保证手段。
//
// 几条贯穿全表的约定：
// - 时间一律 epoch 毫秒（INTEGER），不存字符串，避免时区与格式分歧
// - 主键一律 TEXT（UUID 字符串），跨端生成互不冲突
// - owner_user_id 可空（NULL = 游客）；**所有读路径都必须按它过滤**，
//   同设备换账号绝不能看到别人的对话历史
// - 字节（图片等）永远不进数据库，只存文件路径引用

public enum AISchema {

    /// schema 版本。改动表结构时递增，并在 `migrations` 里补对应步骤。
    public static let version = 3

    /// 连接建立后立即执行的 pragma。
    ///
    /// - WAL：读写不互相阻塞（流式写入期间 UI 仍要读会话列表）
    /// - foreign_keys：默认是关的，不显式打开则 CASCADE 不会生效
    /// - busy_timeout：写队列已经串行化了写，这里兜住跨进程/跨连接的偶发竞争
    public static let pragmas = [
        "PRAGMA journal_mode = WAL;",
        "PRAGMA foreign_keys = ON;",
        "PRAGMA busy_timeout = 3000;",
        "PRAGMA synchronous = NORMAL;",
    ]

    /// 建表语句，按依赖顺序执行（被引用的表在前）。
    public static let createStatements: [String] = [

        // ── 会话 ────────────────────────────────────────────────
        //
        // last_preview 与 message_count 是**有意的冗余**：让会话列表完全不必碰
        // messages/message_parts。旧实现每次刷新都把所有会话的所有消息读进内存，
        // 这两列就是为了根除那个模式。写入时在同一事务里更新。
        """
        CREATE TABLE IF NOT EXISTS sessions (
          id            TEXT PRIMARY KEY,
          owner_user_id TEXT,
          title         TEXT NOT NULL,
          context_key   TEXT,
          created_at    INTEGER NOT NULL,
          updated_at    INTEGER NOT NULL,
          message_count INTEGER NOT NULL DEFAULT 0,
          last_preview  TEXT
        );
        """,

        // ── 媒体（内容寻址）─────────────────────────────────────
        //
        // sha256 唯一 = 同一张图多次发送只存一份文件。
        // rel_path 形如 `ab/abcdef….jpg`（两级分桶，避免单目录堆几千个文件）。
        """
        CREATE TABLE IF NOT EXISTS media (
          id         TEXT PRIMARY KEY,
          sha256     TEXT NOT NULL UNIQUE,
          rel_path   TEXT NOT NULL,
          mime       TEXT NOT NULL,
          bytes      INTEGER NOT NULL,
          width      INTEGER,
          height     INTEGER,
          created_at INTEGER NOT NULL
        );
        """,

        // ── 卸载的大内容 ────────────────────────────────────────
        //
        // 上下文吃紧时把大工具结果从消息里抽走，正文换成占位，原文存这里。
        // 模型需要重看时按 ref 取回。会话删除时一并清掉。
        """
        CREATE TABLE IF NOT EXISTS offloads (
          ref        TEXT PRIMARY KEY,
          session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
          tool_name  TEXT,
          content    TEXT NOT NULL,
          bytes      INTEGER NOT NULL,
          created_at INTEGER NOT NULL
        );
        """,

        // ── 消息 ────────────────────────────────────────────────
        //
        // role 只有 user / assistant —— 工具结果是 user 消息里的一个 part，
        // 传输层的 `role: "tool"` 独立帧由 wire 编码时才拆出来。
        """
        CREATE TABLE IF NOT EXISTS messages (
          id          TEXT PRIMARY KEY,
          session_id  TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
          seq         INTEGER NOT NULL,
          role        TEXT NOT NULL,
          interrupted INTEGER NOT NULL DEFAULT 0,
          reasoning   TEXT,
          created_at  INTEGER NOT NULL
        );
        """,

        // ── 消息片段 ────────────────────────────────────────────
        //
        // kind: text | tool_use | tool_result | image
        // tool_use_id 是调用与结果的配对键 —— 孤儿扫描每轮都要跑，必须有索引。
        """
        CREATE TABLE IF NOT EXISTS message_parts (
          id          TEXT PRIMARY KEY,
          message_id  TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
          idx         INTEGER NOT NULL,
          kind        TEXT NOT NULL,
          text        TEXT,
          tool_use_id TEXT,
          tool_name   TEXT,
          tool_input  TEXT,
          is_error    INTEGER,
          media_id    TEXT REFERENCES media(id),
          offload_ref TEXT REFERENCES offloads(ref)
        );
        """,

        // ── 记忆（预留，本期不写入）────────────────────────────
        //
        // 本期采用的是轻量替代：由代码在发送期注入用户已有的事实
        // （默认地址区县、近期常买品类），不让模型写记忆。
        // 建表占位，将来做通用记忆时不必改结构。
        """
        CREATE TABLE IF NOT EXISTS memories (
          id            TEXT PRIMARY KEY,
          owner_user_id TEXT,
          scope         TEXT NOT NULL,
          content       TEXT NOT NULL,
          source        TEXT,
          created_at    INTEGER NOT NULL,
          updated_at    INTEGER NOT NULL
        );
        """,

        // ── AI 来源配置（四级模型）────────────────────────────
        //
        //   provider_instances  一个「来源」（凭证 + 地址）
        //     └ model_entries   该来源下的一个模型
        //         └ model_groups 一组模型 + 路由策略（降级的载体）
        //             └ session_bindings 某会话用哪个组/哪个模型
        //
        // ⚠️ **API Key 绝不进这张表**（也绝不进任何 SQLite 表）——
        // 密钥存 Keychain / 平台安全存储，库里只有 id 引用。
        """
        CREATE TABLE IF NOT EXISTS provider_instances (
          id           TEXT PRIMARY KEY,
          label        TEXT NOT NULL,
          kind         TEXT NOT NULL,
          base_url     TEXT,
          is_enabled   INTEGER NOT NULL DEFAULT 1,
          created_at   INTEGER NOT NULL
        );
        """,

        """
        CREATE TABLE IF NOT EXISTS model_entries (
          id                TEXT PRIMARY KEY,
          instance_id       TEXT NOT NULL REFERENCES provider_instances(id) ON DELETE CASCADE,
          model_id          TEXT NOT NULL,
          display_name      TEXT NOT NULL,
          context_window    INTEGER NOT NULL,
          max_output_tokens INTEGER NOT NULL,
          supports_vision   INTEGER NOT NULL DEFAULT 0
        );
        """,

        // member_ids 存 JSON 数组：成员是有序的（顺序即降级顺序），
        // 拆成关联表反而要多一列 sort_order 且每次读都要 JOIN + 排序。
        """
        CREATE TABLE IF NOT EXISTS model_groups (
          id                TEXT PRIMARY KEY,
          name              TEXT NOT NULL,
          member_ids        TEXT NOT NULL,
          strategy          TEXT NOT NULL,
          fallback_strategy TEXT NOT NULL
        );
        """,

        // 会话删除时绑定一并清掉。
        """
        CREATE TABLE IF NOT EXISTS session_bindings (
          session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
          kind       TEXT NOT NULL,
          target_id  TEXT NOT NULL
        );
        """,

        // 单例配置（默认组等）。键值表而不是单行表：加一项不用改 schema。
        """
        CREATE TABLE IF NOT EXISTS provider_meta (
          key   TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        """,

        // ── 全文检索 ────────────────────────────────────────────
        //
        // 只索引 kind='text' 的片段（用户提问 + AI 回复正文）。
        // 工具结果与入参刻意不索引：体积大、噪音多（JSON、长列表），
        // 索引它们会让搜索结果全是机器输出，而用户要找的是「我当时问了什么」。
        //
        // `seg` 存的是**分词后**的文本（表意文字逐字空格隔开，首尾各补一个空格），
        // 不是原文。原因见 AITextSegmenter：SQLite 自带的两个分词器对中文都不可用。
        //
        // **刻意不用 FTS5**：Android 系统 SQLite 不含 fts5 模块（实测 API 37 仍
        // `no such module: fts5`），建表即崩。而检索真正的难点在中文分词 ——
        // 那已经在应用层解决了，剩下的匹配用 `LIKE` 就够：seg 里 token 以空格
        // 分隔且首尾补空，`LIKE '% 坚 果 %'` 天然是整词匹配，不会命中「果坚」。
        // 会话量级是几百条对话、几千行片段，全表扫描是毫秒级；
        // FTS5 真正的优势（BM25 排序、大规模语料）在这个量级用不上。
        //
        // 原文在搜索时 JOIN message_parts 取回（seg 满是空格，不能直接显示）。
        """
        CREATE TABLE IF NOT EXISTS part_search (
          part_id    TEXT PRIMARY KEY REFERENCES message_parts(id) ON DELETE CASCADE,
          message_id TEXT NOT NULL,
          session_id TEXT NOT NULL,
          seg        TEXT NOT NULL
        );
        """,
    ]

    /// 触发器（当前为空）。
    ///
    /// FTS 改为应用层维护后不再需要触发器 —— 分词无法在 SQL 里做。
    /// 保留这个入口是为了将来若有纯 SQL 能表达的约束可以挂进来。
    public static let triggerStatements: [String] = []

    /// 索引。
    ///
    /// sessions 的两个复合索引直接对应会话列表与 scoped 续聊两条唯一的读路径；
    /// idx_parts_tooluse 是每轮孤儿扫描的性能保证（不能全表扫）。
    public static let indexStatements: [String] = [
        "CREATE INDEX IF NOT EXISTS idx_sessions_owner_updated ON sessions(owner_user_id, updated_at DESC);",
        "CREATE INDEX IF NOT EXISTS idx_sessions_context ON sessions(owner_user_id, context_key, updated_at DESC);",
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_session_seq ON messages(session_id, seq);",
        "CREATE INDEX IF NOT EXISTS idx_parts_message ON message_parts(message_id, idx);",
        "CREATE INDEX IF NOT EXISTS idx_parts_tooluse ON message_parts(tool_use_id) WHERE tool_use_id IS NOT NULL;",
        "CREATE INDEX IF NOT EXISTS idx_offloads_session ON offloads(session_id);",
        "CREATE INDEX IF NOT EXISTS idx_part_search_session ON part_search(session_id);",
        "CREATE INDEX IF NOT EXISTS idx_memories_owner_scope ON memories(owner_user_id, scope, updated_at DESC);",
        "CREATE INDEX IF NOT EXISTS idx_entries_instance ON model_entries(instance_id);",
    ]

    // MARK: - 单例配置的键

    public enum MetaKey {
        /// 新会话默认绑定的组。
        public static let defaultGroupId = "default_group_id"
        /// 配置是否已完成初始化（避免每次启动重复播种默认组）。
        public static let seeded = "seeded"
    }

    /// `session_bindings.kind` 的取值。
    public enum BindingKind: String, Sendable {
        case group
        case entry
    }

    /// ⚠️ **改动分词规则（AITextSegmenter）也必须升版本** —— 索引里存的是
    /// 分词后的文本，规则变了而索引没重建，旧消息就再也搜不到（静默失效）。
    ///
    /// 重建用：按依赖倒序 drop。
    ///
    /// **本库没有迁移包袱**（会话是端上缓存，丢了重新聊即可），所以升级路径
    /// 就是「删干净重建」—— 比逐版本写迁移脚本简单得多，也不会积累半吊子状态。
    /// 真需要保数据时再改成逐版本迁移。
    public static let dropStatements: [String] = [
        "DROP TABLE IF EXISTS part_search;",
        "DROP TABLE IF EXISTS parts_fts;",
        "DROP TABLE IF EXISTS offloads;",
        "DROP TABLE IF EXISTS message_parts;",
        "DROP TABLE IF EXISTS messages;",
        "DROP TABLE IF EXISTS session_bindings;",
        "DROP TABLE IF EXISTS sessions;",
        "DROP TABLE IF EXISTS media;",
        "DROP TABLE IF EXISTS memories;",
        "DROP TABLE IF EXISTS model_groups;",
        "DROP TABLE IF EXISTS model_entries;",
        "DROP TABLE IF EXISTS provider_instances;",
        "DROP TABLE IF EXISTS provider_meta;",
    ]

    /// 全部建库语句，按执行顺序。
    public static var bootstrapStatements: [String] {
        createStatements + triggerStatements + indexStatements
    }

    // MARK: - 片段类型

    /// `message_parts.kind` 的取值。字符串字面量与 Android 侧一致。
    public enum PartKind: String, Sendable {
        case text
        case toolUse = "tool_use"
        case toolResult = "tool_result"
        case image
    }

    /// `memories.scope` 的取值（预留）。
    public enum MemoryScope: String, Sendable {
        case global
        case daily
    }
}
