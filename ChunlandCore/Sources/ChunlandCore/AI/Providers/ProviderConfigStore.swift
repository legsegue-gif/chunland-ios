import Foundation

// MARK: - 来源配置聚合
//
// 全部 AI 来源配置的唯一入口 —— 四级配置（instance / entry / group / binding）都经此读写。
// 集中的理由：配置此前散在对话装配、分类服务、设置表单与各调用点，每处各读一遍裸 key，
// 改一个字段要改四个地方，且各自的兜底逻辑还不一致。
//
// 落 SQLite（密钥除外，见 ProviderCredentials）。

public actor ProviderConfigStore {

    private let db: AIDatabase
    private let logger = AppLogger(subsystem: AppLogger.subsystem, category: "ai.provider")

    /// 内存快照 —— 配置读远多于写，每次查询都打库没必要。
    private var instances: [ProviderInstance] = []
    private var entries: [ModelEntry] = []
    private var groups: [ModelGroup] = []
    private var defaultGroupId: String?
    private var loaded = false

    public init(db: AIDatabase) {
        self.db = db
    }

    // MARK: - 加载与播种

    public func loadIfNeeded() async throws {
        guard !loaded else { return }
        try await reload()
        if try await meta(AISchema.MetaKey.seeded) == nil {
            try await seedDefaults()
            try await setMeta(AISchema.MetaKey.seeded, "1")
        }
        loaded = true
    }

    public func reload() async throws {
        instances = try await db.query("SELECT * FROM provider_instances;").compactMap(Self.decodeInstance)
        entries = try await db.query("SELECT * FROM model_entries;").compactMap(Self.decodeEntry)
        groups = try await db.query("SELECT * FROM model_groups;").compactMap(Self.decodeGroup)
        defaultGroupId = try await meta(AISchema.MetaKey.defaultGroupId)
    }

    /// 首次启动播种：建系统 AI 来源 + 默认组。
    ///
    /// 默认组只放系统 AI —— 用户自配的来源要等他自己添加。
    /// 一旦添加，`ensureInDefaultGroup` 会把它追加到组尾，
    /// 于是自动获得「系统 AI 优先、自配兜底」。
    private func seedDefaults() async throws {
        let system = ProviderInstance.system()
        try await upsert(instance: system)

        // 系统 AI 的模型属性**一个都不落库** —— 它们随模块预设与服务端下发变化，
        // 落库就等于把「真相源」钉死成首装那一刻的快照，此后改预设、发新版全部失效。
        // 这里存的是占位死值，读出口的 applyingSystemPreset 会无条件覆盖。
        let entry = ModelEntry(
            instanceId: system.id,
            modelId: ModelEntry.systemModelSentinel,
            displayName: "系统提供的 AI",
            contextWindow: 32_000,
            maxOutputTokens: 4_096,
            supportsVision: false
        )
        try await upsert(entry: entry)

        let group = ModelGroup(
            id: ModelGroup.defaultGroupId,
            name: "默认",
            memberEntryIds: [entry.id],
            strategy: .fallback,
            fallbackStrategy: .limited
        )
        try await upsert(group: group)
        try await setMeta(AISchema.MetaKey.defaultGroupId, group.id)
        logger.info("已播种默认 AI 配置")
    }

    // MARK: - 查询

    public func allInstances() -> [ProviderInstance] { instances }
    public func allEntries() -> [ModelEntry] { entries.map(Self.applyingSystemPreset) }
    public func allGroups() -> [ModelGroup] { groups }

    public func instance(id: String) -> ProviderInstance? {
        instances.first { $0.id == id }
    }

    public func entry(id: String) -> ModelEntry? {
        entries.first { $0.id == id }.map(Self.applyingSystemPreset)
    }

    /// 系统 AI 条目的模型属性一律现取 —— 库里存的是占位死值。
    ///
    /// **落点必须在读出口，不能只改造 provider 的那一处**：contextWindow 被
    /// `AIChatSession` 拿去喂 ContextPolicy、supportsVision 决定图片编不编进请求，
    /// 三条链路各取所需，只改一处必漏。
    ///
    /// 覆盖是**无条件**的（不做「库里有值就用库里的」），否则占位死值会赢。
    /// 模块未接入时 preset 为 nil，此时系统 AI 整体不可用，返回原样即可。
    private static func applyingSystemPreset(_ entry: ModelEntry) -> ModelEntry {
        guard entry.instanceId == ProviderInstance.systemInstanceId,
              let preset = SystemAIProvider.preset else { return entry }
        var resolved = entry
        resolved.modelId = preset.model
        resolved.contextWindow = preset.contextWindow
        resolved.maxOutputTokens = preset.maxOutputTokens
        resolved.supportsVision = preset.supportsVision
        return resolved
    }

    public func group(id: String) -> ModelGroup? {
        groups.first { $0.id == id }
    }

    public func defaultGroup() -> ModelGroup? {
        defaultGroupId.flatMap { group(id: $0) } ?? groups.first
    }

    /// 组的可用成员 —— 过滤掉来源被停用、来源已删、或（自配来源）缺密钥的条目。
    ///
    /// 「缺密钥」必须在这里就滤掉：让一个必然 401 的条目参与降级，
    /// 只会白白多一轮请求 + 一条误导性的「密钥无效」提示。
    public func usableEntries(in group: ModelGroup) -> [ModelEntry] {
        group.memberEntryIds.compactMap { id -> ModelEntry? in
            guard let entry = entry(id: id),
                  let inst = instance(id: entry.instanceId),
                  inst.isEnabled,
                  inst.kind != .unsupported else { return nil }
            if inst.kind.usesStoredAPIKey,
               ProviderCredentials.apiKey(for: inst.id) == nil { return nil }
            return entry
        }
    }

    /// 解析会话该用哪个模型：绑定 → 组首个可用 → 默认组首个可用。
    public func resolveEntry(binding: SessionModelBinding?) -> ModelEntry? {
        switch binding {
        case .entry(let id):
            // 显式钉死的模型：即使不可用也如实返回 nil，不静默改用别的 ——
            // 用户选了什么就该用什么，换模型必须是他自己的动作。
            return entry(id: id)
        case .group(let gid):
            if let g = group(id: gid), let first = usableEntries(in: g).first { return first }
            return defaultGroup().flatMap { usableEntries(in: $0).first }
        case nil:
            return defaultGroup().flatMap { usableEntries(in: $0).first }
        }
    }

    /// 当前是否有任何可用模型 —— UI 据此显示配置引导。
    public func hasUsableModel() -> Bool {
        resolveEntry(binding: nil) != nil
    }

    // MARK: - 写入

    public func upsert(instance: ProviderInstance) async throws {
        try await db.execute(
            """
            INSERT INTO provider_instances (id, label, kind, base_url, is_enabled, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              label = excluded.label,
              kind = excluded.kind,
              base_url = excluded.base_url,
              is_enabled = excluded.is_enabled
            """,
            [.text(instance.id), .text(instance.label),
             .text(instance.unknownKindRaw ?? instance.kind.rawValue),
             SQLValue(instance.baseURL), SQLValue(instance.isEnabled),
             .int(instance.createdAt.epochMillis)]
        )
        try await reload()
    }

    public func upsert(entry: ModelEntry) async throws {
        try await db.execute(
            """
            INSERT INTO model_entries
              (id, instance_id, model_id, display_name, context_window, max_output_tokens, supports_vision)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              display_name = excluded.display_name,
              context_window = excluded.context_window,
              max_output_tokens = excluded.max_output_tokens,
              supports_vision = excluded.supports_vision
            """,
            [.text(entry.id), .text(entry.instanceId), .text(entry.modelId),
             .text(entry.displayName), SQLValue(entry.contextWindow),
             SQLValue(entry.maxOutputTokens), SQLValue(entry.supportsVision)]
        )
        try await reload()
    }

    public func upsert(group: ModelGroup) async throws {
        let members = (try? JSONEncoder().encode(group.memberEntryIds))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try await db.execute(
            """
            INSERT INTO model_groups (id, name, member_ids, strategy, fallback_strategy)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              name = excluded.name,
              member_ids = excluded.member_ids,
              strategy = excluded.strategy,
              fallback_strategy = excluded.fallback_strategy
            """,
            [.text(group.id), .text(group.name), .text(members),
             .text(group.strategy.rawValue), .text(group.fallbackStrategy.rawValue)]
        )
        try await reload()
    }

    /// 把某个来源下的模型条目整体换成 `entry`，并让降级链跟着改指。
    ///
    /// 为什么不能只 `upsert(entry:)`：`ModelEntry.id` 是 `{instanceId}:{modelId}` 复合的，
    /// **改一次模型名就等于换了一个条目** —— 直接 upsert 会留下一条指向旧模型的孤儿，
    /// 而降级链里还指着那个已经没人维护的旧 id（界面上显示成「已删除」）。
    public func replaceEntry(_ entry: ModelEntry, forInstance instanceId: String) async throws {
        let staleIds = entries
            .filter { $0.instanceId == instanceId && $0.id != entry.id }
            .map(\.id)

        try await upsert(entry: entry)          // 内含 reload
        guard !staleIds.isEmpty else { return }

        for id in staleIds {
            try await db.execute("DELETE FROM model_entries WHERE id = ?;", [.text(id)])
        }

        // 组成员里把旧 id 就地换成新 id —— 用「删了再追加」会把它挪到链尾，
        // 用户精心排的优先级就白排了。
        for var g in groups where g.memberEntryIds.contains(where: staleIds.contains) {
            var seen = Set<String>()
            g.memberEntryIds = g.memberEntryIds
                .map { staleIds.contains($0) ? entry.id : $0 }
                .filter { seen.insert($0).inserted }   // 新 id 可能本就在链上，去重
            try await upsert(group: g)
        }
        try await reload()
    }

    /// 删除来源。**密钥必须一并清掉** —— 库里的行走 CASCADE，Keychain 不会自己走。
    public func deleteInstance(id: String) async throws {
        guard id != ProviderInstance.systemInstanceId else {
            logger.warn("拒绝删除系统 AI 来源")
            return
        }
        let removedEntryIds = entries.filter { $0.instanceId == id }.map(\.id)
        try await db.execute("DELETE FROM provider_instances WHERE id = ?;", [.text(id)])
        ProviderCredentials.deleteAPIKey(for: id)

        // 组里残留已删条目的 id 会让降级链踩空，顺手摘掉。
        for var g in groups where g.memberEntryIds.contains(where: removedEntryIds.contains) {
            g.memberEntryIds.removeAll { removedEntryIds.contains($0) }
            try await upsert(group: g)
        }
        try await reload()
    }

    /// 新增自配来源时把它追加进默认组尾部 —— 这样系统 AI 挂了能自动兜底。
    public func ensureInDefaultGroup(entryId: String) async throws {
        guard var g = defaultGroup() else { return }
        guard !g.memberEntryIds.contains(entryId) else { return }
        g.memberEntryIds.append(entryId)
        try await upsert(group: g)
    }

    // MARK: - 会话绑定

    public func binding(sessionId: String) async throws -> SessionModelBinding? {
        let rows = try await db.query(
            "SELECT kind, target_id FROM session_bindings WHERE session_id = ? LIMIT 1;",
            [.text(sessionId)]
        )
        guard let row = rows.first,
              let kindRaw = row.string("kind"),
              let target = row.string("target_id"),
              let kind = AISchema.BindingKind(rawValue: kindRaw) else { return nil }
        return kind == .group ? .group(target) : .entry(target)
    }

    public func setBinding(_ binding: SessionModelBinding, sessionId: String) async throws {
        let (kind, target): (AISchema.BindingKind, String) = switch binding {
        case .group(let g): (.group, g)
        case .entry(let e): (.entry, e)
        }
        try await db.execute(
            """
            INSERT INTO session_bindings (session_id, kind, target_id) VALUES (?, ?, ?)
            ON CONFLICT(session_id) DO UPDATE SET kind = excluded.kind, target_id = excluded.target_id
            """,
            [.text(sessionId), .text(kind.rawValue), .text(target)]
        )
    }

    // MARK: - 单例配置

    public func meta(_ key: String) async throws -> String? {
        try await db.query("SELECT value FROM provider_meta WHERE key = ? LIMIT 1;", [.text(key)])
            .first?.string("value")
    }

    public func setMeta(_ key: String, _ value: String) async throws {
        try await db.execute(
            """
            INSERT INTO provider_meta (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            [.text(key), .text(value)]
        )
        if key == AISchema.MetaKey.defaultGroupId { defaultGroupId = value }
    }

    // MARK: - 解码

    private static func decodeInstance(_ row: SQLRow) -> ProviderInstance? {
        guard let id = row.string("id"),
              let label = row.string("label"),
              let kindRaw = row.string("kind") else { return nil }
        let kind = ProviderKind.decoded(kindRaw)
        return ProviderInstance(
            id: id,
            label: label,
            kind: kind,
            baseURL: row.string("base_url"),
            isEnabled: row.bool("is_enabled") ?? true,
            createdAt: row.date("created_at") ?? .now,
            unknownKindRaw: kind == .unsupported ? kindRaw : nil
        )
    }

    private static func decodeEntry(_ row: SQLRow) -> ModelEntry? {
        guard let instanceId = row.string("instance_id"),
              let modelId = row.string("model_id") else { return nil }
        return ModelEntry(
            instanceId: instanceId,
            modelId: modelId,
            displayName: row.string("display_name"),
            contextWindow: row.int("context_window") ?? 32_000,
            maxOutputTokens: row.int("max_output_tokens") ?? 4_096,
            supportsVision: row.bool("supports_vision") ?? false
        )
    }

    private static func decodeGroup(_ row: SQLRow) -> ModelGroup? {
        guard let id = row.string("id"),
              let name = row.string("name"),
              let membersRaw = row.string("member_ids") else { return nil }
        let members = (membersRaw.data(using: .utf8))
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        return ModelGroup(
            id: id,
            name: name,
            memberEntryIds: members,
            strategy: row.string("strategy").flatMap(RoutingStrategy.init) ?? .fallback,
            fallbackStrategy: row.string("fallback_strategy").flatMap(FallbackStrategy.init) ?? .limited
        )
    }
}
