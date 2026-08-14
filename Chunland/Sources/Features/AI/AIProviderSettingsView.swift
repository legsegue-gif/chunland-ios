import SwiftUI
import ChunlandCore

// MARK: - AI 来源配置
//
// 替换旧的「三个输入框（baseUrl / model / apiKey）+ 一个系统 AI 开关」。
//
// 旧实现的问题不在界面，在它背后：同一份配置被四处各读一遍
// （orchestrator / 单次调用服务 / 本页表单 / 我的页的 @AppStorage），
// 裸 UserDefaults key 硬编码在六处，改一个字段要改四个地方。
// 现在全部走 ProviderConfigStore。
//
// 界面上多出来的是**降级链** —— 旧实现只能配一个来源，它挂了就没 AI 用；
// 现在能配多个并排出优先级，系统 AI 不可用时自动切下一个。

struct AIProviderSettingsView: View {

    let config: ProviderConfigStore

    @State private var instances: [ProviderInstance] = []
    @State private var entries: [ModelEntry] = []
    @State private var defaultGroup: ModelGroup?
    /// 编辑目标。**新增与编辑共用这一个状态** —— 同一个视图上挂两个 `.sheet` 修饰符时
    /// SwiftUI 只认其中一个，另一个静默失效（实测：+ 能弹出、点已有来源没反应）。
    @State private var editTarget: EditTarget?
    @State private var loading = true

    var body: some View {
        List {
            if loading {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                fallbackChainSection
                sourcesSection
            }
        }
        .navigationTitle("AI 来源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editTarget = .new } label: { Image(systemName: "plus") }
                    .accessibilityLabel("添加来源")
            }
        }
        .sheet(item: $editTarget) { target in
            ProviderEditSheet(config: config, instance: target.instance) { await reload() }
        }
        .task { await reload() }
    }

    // MARK: - 降级链

    private var fallbackChainSection: some View {
        Section {
            if !activeMembers.isEmpty {
                ForEach(Array(activeMembers.enumerated()), id: \.element) { index, entryId in
                    chainRow(index: index, entryId: entryId)
                }
                .onMove { source, destination in
                    Task { await moveMember(from: source, to: destination) }
                }
            } else if defaultGroup?.memberEntryIds.isEmpty == false {
                // 配置还在、只是全被关了 —— 说清楚，否则看着像配置丢了
                Text("所有来源都已停用，AI 无法使用")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else {
                Text("尚未配置可用来源")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("使用顺序")
        } footer: {
            Text("从上往下依次尝试。排在前面的不可用时（服务维护、请求过多、密钥失效），会自动切换到下一个，并在对话里告知你。长按可调整顺序。已停用的来源不在这里显示。")
                .font(.caption)
        }
    }

    private func chainRow(index: Int, entryId: String) -> some View {
        let entry = entries.first { $0.id == entryId }
        let instance = entry.flatMap { e in instances.first { $0.id == e.instanceId } }
        let usable = isUsable(entry: entry, instance: instance)

        return HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry?.displayName ?? entryId)
                    .font(.callout)
                if let instance {
                    Text(instance.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if !usable.ok {
                // 不可用的条目留在链上但标出原因 —— 直接隐藏会让用户
                // 以为配置丢了，而它其实只是缺个密钥
                Text(usable.reason)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func isUsable(entry: ModelEntry?, instance: ProviderInstance?) -> (ok: Bool, reason: String) {
        guard let entry, let instance else { return (false, "已删除") }
        _ = entry
        // 停用的来源根本不会出现在这个列表里（activeMembers 已滤掉），不必再判
        if instance.kind == .unsupported { return (false, "不支持") }
        if instance.kind.usesStoredAPIKey,
           ProviderCredentials.apiKey(for: instance.id) == nil {
            return (false, "缺密钥")
        }
        return (true, "")
    }

    // MARK: - 来源列表

    private var sourcesSection: some View {
        Section("已配置的来源") {
            ForEach(instances) { instance in
                // 用整行 tap 而不是 Button：List 里 .buttonStyle(.plain) 的点击区域只盖住
                // label 的实际内容，而同一个 List 的另一个 Section 挂了 .onMove（拖动排序），
                // 行内 Button 的点击会被排序手势吃掉 —— 表现是点了完全没反应（实测）。
                sourceRow(instance)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // 系统 AI 没有可编辑的字段（地址与密钥都是运行时取的）
                        guard instance.kind != .system else { return }
                        editTarget = .existing(instance)
                    }
            }
        }
    }

    private func sourceRow(_ instance: ProviderInstance) -> some View {
        HStack(spacing: 10) {
            Image(systemName: instance.kind == .system ? "sparkles" : "server.rack")
                .foregroundStyle(instance.isEnabled ? Color.accentColor : .secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(instance.label).font(.callout)
                Text(subtitle(for: instance))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if instance.kind != .system {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func subtitle(for instance: ProviderInstance) -> String {
        // 停用的来源已从「使用顺序」移除，这里是它唯一还看得见的地方 ——
        // 不标出来的话，用户不知道该去哪把它开回来
        guard instance.isEnabled else { return "已停用" }
        switch instance.kind {
        case .system:
            // 措辞保持服务级 —— 用户不需要知道它跑在哪、用什么端口
            switch SystemAIProvider.status {
            case .running:      return "服务正常"
            case .disabled:     return "维护中"
            case .waitingAuth:  return "需要登录"
            case .starting, .stopped, .unreachable, .failed: return "准备中"
            case .none:         return "不可用"
            }
        case .openAICompatible:
            let hasKey = ProviderCredentials.apiKey(for: instance.id) != nil
            let host = instance.baseURL.flatMap { URL(string: $0)?.host } ?? instance.baseURL ?? "未填写地址"
            return hasKey ? host : "\(host) · 未填 API Key"
        case .unsupported:
            return "本版本不支持这种来源"
        }
    }

    // MARK: - 数据

    private func reload() async {
        try? await config.loadIfNeeded()
        instances = await config.allInstances()
        entries = await config.allEntries()
        defaultGroup = await config.defaultGroup()
        loading = false
    }

    /// 降级链里**当前启用**的成员（停用的不显示，但仍留在组数据里保位置）。
    private var activeMembers: [String] {
        guard let group = defaultGroup else { return [] }
        return group.memberEntryIds.filter { id in
            guard let entry = entries.first(where: { $0.id == id }),
                  let inst = instances.first(where: { $0.id == entry.instanceId })
            else { return false }   // 条目/来源已删 —— 不该占位
            return inst.isEnabled
        }
    }

    /// 拖动排序。
    ///
    /// ⚠️ `onMove` 给的索引是**可见列表**（已过滤停用项）的，而要改的是完整的
    /// `memberEntryIds` —— 直接拿它 move 完整数组，中间夹着停用项时就会错位。
    /// 故按 id 重排：先摘出被拖的，再插到锚点前面。
    private func moveMember(from source: IndexSet, to destination: Int) async {
        guard var group = defaultGroup else { return }
        let visible = activeMembers
        let movingIds = source.map { visible[$0] }
        // destination == visible.count 表示拖到了末尾，此时没有锚点
        let anchorId: String? = destination < visible.count ? visible[destination] : nil

        var ids = group.memberEntryIds
        ids.removeAll { movingIds.contains($0) }
        let insertAt = anchorId.flatMap { ids.firstIndex(of: $0) } ?? ids.count
        ids.insert(contentsOf: movingIds, at: insertAt)

        group.memberEntryIds = ids
        try? await config.upsert(group: group)
        await reload()
    }
}

/// 拉回来的模型列表选择器。
private struct ModelPickerSheet: View {
    let models: [String]
    let current: String
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var keyword = ""

    private var filtered: [String] {
        let k = keyword.trimmingCharacters(in: .whitespaces).lowercased()
        return k.isEmpty ? models : models.filter { $0.lowercased().contains(k) }
    }

    var body: some View {
        NavigationStack {
            List(filtered, id: \.self) { model in
                Button {
                    onPick(model)
                    dismiss()
                } label: {
                    HStack {
                        Text(model).foregroundStyle(.primary)
                        Spacer()
                        if model == current {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
            }
            .searchable(text: $keyword, prompt: "搜索模型")
            .navigationTitle("选择模型（\(models.count)）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

/// 表单的呈现目标（新增 or 编辑既有）。
private enum EditTarget: Identifiable {
    case new
    case existing(ProviderInstance)

    var instance: ProviderInstance? {
        if case .existing(let i) = self { return i }
        return nil
    }
    var id: String {
        switch self {
        case .new: return "__new__"
        case .existing(let i): return i.id
        }
    }
}

// MARK: - 添加 / 编辑自配来源

struct ProviderEditSheet: View {

    let config: ProviderConfigStore
    let instance: ProviderInstance?
    let onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var modelId = ""
    /// 自动补 "/v1"（对齐 minis 的 Auto Append）。开着时地址栏只需填到主机名。
    @State private var autoAppendV1 = true
    /// 启用状态。关掉 = 保留配置但不参与降级链（不是删除）。
    @State private var isEnabled = true
    /// 密钥是否明文显示。默认关 —— 只有用户主动点眼睛才现形。
    @State private var revealKey = false
    /// 从端点拉回来的模型列表（供选择，非必需 —— 手填一直可用）
    @State private var fetchedModels: [String] = []
    @State private var fetchingModels = false
    @State private var showModelPicker = false
    @State private var modelFetchError: String?
    @State private var saving = false
    @State private var error: String?

    private var isNew: Bool { instance == nil }

    /// 自定义来源的模型参数默认值 —— **不问用户**（理由见表单里的注释）。
    ///
    /// 上下文长度取保守值：偏小只是提前整理历史，偏大则会撑爆窗口直接报错。
    /// 识图默认开：用户主动发图就是期望模型能看，模型看不了会自己说明，
    /// 比默默把图换成占位文案更诚实。
    private static let defaultContextWindow = 32_000
    private static let defaultSupportsVision = true

    var body: some View {
        NavigationStack {
            Form {
                // 只问用户答得上来的四项。
                //
                // 上下文长度与识图能力**刻意不做成表单项**：配一个自定义端点的人，
                // 通常并不知道那个模型的窗口多大、支不支持视觉 —— 问了也只是逼他猜。
                // 前者只影响「何时自动整理历史」（填错不影响能否使用），后者失败时
                // 上游会明确报错或模型自己说看不了图，两种都是清楚的反馈。
                // 故由代码定默认值，见 Self.defaultContextWindow / defaultSupportsVision。
                Section {
                    LabeledContent("名称") {
                        TextField("我的 AI", text: $label)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("接口地址") {
                        // placeholder 刻意不写完整 URL：SwiftUI 会把含协议头的文本
                        // 当链接染成蓝色，空状态看着像「已经填好了」（实测两次）。
                        TextField(autoAppendV1 ? "例：api.openai.com" : "例：api.openai.com/v1",
                                  text: $baseURL)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            // 刻意不用 keyboardType(.URL)：它会让系统把 placeholder 里的
                            // 示例网址当成链接渲染成蓝色，看着像「已经填好了」（实测）。
                            // URL 键盘省的那点输入便利，不值得换来一个会骗人的空状态。
                            .foregroundStyle(.primary)
                    }
                    Toggle("自动补 \"/v1\"", isOn: $autoAppendV1)
                    LabeledContent("API Key") {
                        HStack(spacing: 8) {
                            // 始终用 TextField 而不是 SecureField：SecureField 会切到密码键盘，
                            // 屏蔽掉一部分字符（密钥里出现就打不进来）。隐藏态改成在
                            // opacity 0 的输入框上叠一层圆点遮罩 —— 明文既不上屏也不进截图。
                            ZStack(alignment: .trailing) {
                                TextField("sk-...", text: $apiKey)
                                    .multilineTextAlignment(.trailing)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .font(.system(.body, design: .monospaced))
                                    // 空的时候不遮 —— 否则连 placeholder 都看不见
                                    .opacity(revealKey || apiKey.isEmpty ? 1 : 0)

                                if !revealKey, !apiKey.isEmpty {
                                    Text(String(repeating: "•", count: min(apiKey.count, 16)))
                                        .font(.system(.body, design: .monospaced))
                                        .allowsHitTesting(false)
                                }
                            }
                            Button {
                                revealKey.toggle()
                            } label: {
                                Image(systemName: revealKey ? "eye.slash" : "eye")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(revealKey ? "隐藏 API Key" : "显示 API Key")
                        }
                    }
                    LabeledContent("模型名") {
                        HStack(spacing: 8) {
                            TextField("gpt-4o", text: $modelId)
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            if fetchingModels {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("获取") { Task { await fetchModels() } }
                                    .font(.caption)
                                    .buttonStyle(.borderless)
                                    // 没有地址就拉不了；密钥可以留空（编辑时用已存的那把）
                                    .disabled(baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                    }
                    if let modelFetchError {
                        Text(modelFetchError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } footer: {
                    Text((autoAppendV1
                          ? "接口地址填到主机名即可（要带 http:// 或 https://），\"/v1\" 会自动补上。\n"
                          : "接口地址要填完整，包含 \"/v1\" 这一级。\n")
                         + (isNew
                            ? "密钥只存在本机钥匙串里，不会离开这台设备。"
                            : "密钥只存在本机钥匙串里，不会离开这台设备。清空并保存会删除已存的密钥。"))
                        .font(.caption)
                }

                Section {
                    Toggle("启用", isOn: $isEnabled)
                } footer: {
                    Text("关掉后这个来源会从「使用顺序」里移除，但配置和位置都保留 —— 重新启用就回到原来的位置。")
                        .font(.caption)
                }

                if let error {
                    Section {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }

                if !isNew {
                    Section {
                        Button("删除这个来源", role: .destructive) {
                            Task { await delete() }
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "添加来源" : "编辑来源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .disabled(saving || !canSave)
                }
            }
            .task { await prefill() }
            .sheet(isPresented: $showModelPicker) {
                ModelPickerSheet(models: fetchedModels, current: modelId) { picked in
                    modelId = picked
                }
            }
        }
    }

    private var canSave: Bool {
        !label.trimmingCharacters(in: .whitespaces).isEmpty
            && !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !modelId.trimmingCharacters(in: .whitespaces).isEmpty
            && (!isNew || !apiKey.isEmpty)
    }

    private func prefill() async {
        guard let instance else { return }
        label = instance.label

        // 地址与开关是一对：库里存的是**最终地址**（provider 直接拿它拼 /chat/completions），
        // 编辑时按「是不是 /v1 结尾」反推出开关状态，好让用户看到的和他当初填的一致。
        isEnabled = instance.isEnabled

        let stored = instance.baseURL ?? ""
        if stored.hasSuffix("/v1") {
            autoAppendV1 = true
            baseURL = String(stored.dropLast(3))
        } else {
            autoAppendV1 = false
            baseURL = stored
        }

        // 模型名在 ModelEntry 上而不是 instance 上，得单独取 —— 漏了这一步的后果不只是
        // 「显示为空」：用户不重填就保存，会存进一个 modelId 为空的条目
        modelId = await config.allEntries()
            .first { $0.instanceId == instance.id }?.modelId ?? ""

        // 密钥回填真实值（默认仍是圆点遮罩，点眼睛才现形）。
        //
        // 这里推翻了原先「只写不读」的做法：不回显时，用户既没法核对自己填的对不对，
        // 也没法在换端点时把密钥抄出来 —— 而密钥本就存在这台设备上，本人看自己的密钥
        // 不构成新的泄露面（对齐 minis 的 Credential 段）。代价是「留空 = 不修改」
        // 这条语义不再成立，改为「留空保存 = 删除密钥」，footer 已写明。
        apiKey = ProviderCredentials.apiKey(for: instance.id) ?? ""
    }

    /// 拉模型列表。**失败只提示、绝不阻断保存** —— 手填那条路一直留着。
    private func fetchModels() async {
        fetchingModels = true
        modelFetchError = nil
        defer { fetchingModels = false }

        // 用表单里的当前值拉，不是库里存的 —— 否则新增来源时（还没保存）根本没法拉。
        // 编辑既有来源时表单已回填了已存的密钥，这里天然拿到的就是那把
        do {
            let models = try await ModelCatalog.fetch(baseURL: resolvedBaseURL, apiKey: apiKey)
            fetchedModels = models
            showModelPicker = true
        } catch {
            modelFetchError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    /// 表单里的地址 + 开关 → 真正存库的地址。
    private var resolvedBaseURL: String {
        var url = baseURL.trimmingCharacters(in: .whitespaces)
        while url.hasSuffix("/") { url = String(url.dropLast()) }
        guard autoAppendV1, !url.isEmpty, !url.hasSuffix("/v1") else { return url }
        return url + "/v1"
    }

    private func save() async {
        saving = true
        defer { saving = false }
        error = nil

        let trimmedURL = resolvedBaseURL
        guard URL(string: trimmedURL)?.scheme?.hasPrefix("http") == true else {
            error = "接口地址需要以 http:// 或 https:// 开头"
            return
        }

        let target = instance ?? ProviderInstance(
            label: label,
            kind: .openAICompatible,
            baseURL: trimmedURL
        )
        var updated = target
        updated.label = label.trimmingCharacters(in: .whitespaces)
        updated.baseURL = trimmedURL
        updated.isEnabled = isEnabled

        do {
            try await config.upsert(instance: updated)
            // 无条件按表单值写 —— 空值在 setAPIKey 里就是删除。
            // 表单已回填已存密钥，所以「空」只可能是用户自己清掉的，那就该删
            ProviderCredentials.setAPIKey(apiKey, for: updated.id)

            let entry = ModelEntry(
                instanceId: updated.id,
                modelId: modelId.trimmingCharacters(in: .whitespaces),
                contextWindow: Self.defaultContextWindow,
                supportsVision: Self.defaultSupportsVision
            )
            // 用 replace 而不是 upsert：改模型名会换掉条目 id，
            // 直接 upsert 会留孤儿、降级链还指着旧 id（详见 store 内注释）
            try await config.replaceEntry(entry, forInstance: updated.id)
            // 新来源自动排进降级链尾部 —— 用户不必再去「使用顺序」里手动加一次
            try await config.ensureInDefaultGroup(entryId: entry.id)

            await onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete() async {
        guard let instance else { return }
        try? await config.deleteInstance(id: instance.id)
        await onSaved()
        dismiss()
    }
}
