import SwiftUI
import ChunlandCore

// 分类方案管理（lens）：方案列表 → 方案详情（分类）→ 分类下商品勾选。
// 「方案 = 观察商品的一个视角」：一店多方案，消费者进店可切换；隐藏 = 不显示该视角。
struct SchemeManageView: View {
    @State private var schemes: [CategoryScheme] = []
    @State private var hasLoaded = false
    @State private var error: String?
    /// sheet(item:) 一次性令牌：每次打开新身份，@State 不残留、.task 必重跑。
    private struct PresentToken: Identifiable { let id = UUID() }

    @State private var showNewChoice = false     // 新建方案：手动 / AI 起草 二选一
    @State private var showCreate = false
    @State private var aiDraftToken: PresentToken?
    @State private var showTemplates = false     // 分类思路模板管理页
    @State private var newName = ""
    @State private var toast: String?

    var body: some View {
        Group {
            if !hasLoaded {
                ProgressView()
            } else if schemes.isEmpty {
                ScrollView {
                    emptyOrErrorView
                        .containerRelativeFrame([.horizontal, .vertical])
                }
                .refreshable { await load() }
            } else {
                List {
                    ForEach(schemes) { scheme in
                        schemeRow(scheme)
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await load() }
            }
        }
        .navigationTitle("分类方案")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showTemplates = true
                    } label: {
                        Label("分类思路模板", systemImage: "text.badge.star")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("更多")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNewChoice = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("新建方案")
            }
        }
        // 新建方案只有一个入口，AI 起草是它的一种方式（不是并列的神秘功能）
        .confirmationDialog("新建分类方案", isPresented: $showNewChoice, titleVisibility: .visible) {
            Button("AI 起草（按分类思路生成，可预览调整）") { aiDraftToken = PresentToken() }
            Button("手动创建") { showCreate = true }
            Button("取消", role: .cancel) {}
        }
        .alert("手动创建方案", isPresented: $showCreate) {
            TextField("方案名（如 吃穿住行用）", text: $newName)
            Button("创建") { Task { await create() } }
            Button("取消", role: .cancel) { newName = "" }
        } message: {
            Text("一个方案是浏览店铺商品的一个视角，可同时存在多个供买家切换")
        }
        .sheet(item: $aiDraftToken) { _ in
            AIClassifySheet { msg in
                Task { await load() }
                showToast(msg)
            }
        }
        .navigationDestination(isPresented: $showTemplates) {
            TemplateManageView()
        }
        .overlay(alignment: .top) { toastView }
        .task { await load() }
    }

    @ViewBuilder
    private var emptyOrErrorView: some View {
        if let error {
            ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
        } else {
            ContentUnavailableView("还没有分类方案", systemImage: "square.grid.3x1.below.line.grid.1x2",
                description: Text("例如建一个「吃穿住行用」方案，买家进店可按这个视角逛。点右上角 ➕ 新建（支持 AI 起草）"))
        }
    }

    private func schemeRow(_ scheme: CategoryScheme) -> some View {
        NavigationLink(destination: SchemeDetailView(scheme: scheme) { await load() }) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(scheme.name).font(.subheadline).bold()
                    if scheme.isDefault {
                        Text("默认").font(.caption2).bold()
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    }
                    if scheme.isVisible == false {
                        Text("已隐藏").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .foregroundStyle(.secondary)
                            .clipShape(Capsule())
                    }
                }
                Text(scheme.categories.isEmpty
                     ? "还没有分类"
                     : scheme.categories.map(\.name).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .swipeActions(edge: .trailing) {
            Button("删除", role: .destructive) {
                Task { await remove(scheme) }
            }
            if scheme.isVisible == false {
                Button("显示") { Task { await setVisible(scheme, true) } }.tint(.green)
            } else {
                Button("隐藏") { Task { await setVisible(scheme, false) } }.tint(.orange)
            }
        }
        .swipeActions(edge: .leading) {
            if !scheme.isDefault {
                Button("设默认") { Task { await setDefault(scheme) } }.tint(.blue)
            }
        }
    }

    // MARK: - 操作

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        newName = ""
        guard !name.isEmpty else { return }
        do {
            _ = try await MerchantConsoleService.shared.createScheme(name: name)
            await load()
        } catch {
            showToast("创建失败：\(error.localizedDescription)")
        }
    }

    private func remove(_ scheme: CategoryScheme) async {
        do {
            try await MerchantConsoleService.shared.deleteScheme(id: scheme.id)
            await load()
            showToast("已删除")
        } catch {
            showToast("删除失败：\(error.localizedDescription)")
        }
    }

    private func setVisible(_ scheme: CategoryScheme, _ visible: Bool) async {
        do {
            _ = try await MerchantConsoleService.shared.updateScheme(id: scheme.id, isVisible: visible)
            await load()
        } catch {
            showToast("操作失败：\(error.localizedDescription)")
        }
    }

    private func setDefault(_ scheme: CategoryScheme) async {
        do {
            _ = try await MerchantConsoleService.shared.updateScheme(id: scheme.id, isDefault: true)
            await load()
            showToast("已设为默认视角")
        } catch {
            showToast("操作失败：\(error.localizedDescription)")
        }
    }

    private func load() async {
        error = nil
        do {
            schemes = try await MerchantConsoleService.shared.schemes()
        } catch {
            self.error = error.localizedDescription
        }
        hasLoaded = true
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.subheadline).foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.black.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.top, 8)
        }
    }

    private func showToast(_ msg: String) {
        withAnimation { toast = msg }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run { if toast == msg { withAnimation { toast = nil } } }
        }
    }
}

// MARK: - 方案详情（分类管理）

struct SchemeDetailView: View {
    let scheme: CategoryScheme
    let onChanged: () async -> Void

    /// sheet(item:) 用的一次性令牌：每次打开生成新 id → sheet 内容全新身份，
    /// @State 不残留、.task 必重跑（isPresented 版二次打开有身份复用坑）。
    private struct PresentToken: Identifiable { let id = UUID() }

    // 移动/改级目标：cat = 被移动分类，parentId = 它当前的父（nil = 它本身是一级）
    private struct MoveTarget: Identifiable { let cat: CategoryScheme.Cat; let parentId: Int?; var id: Int { cat.id } }

    @State private var categories: [CategoryScheme.Cat]
    @State private var showAdd = false
    @State private var addParent: CategoryScheme.Cat?   // 非 nil = 在该一级下加二级
    @State private var moving: MoveTarget?
    @State private var aiAssignToken: PresentToken?
    @State private var newName = ""
    @State private var toast: String?

    init(scheme: CategoryScheme, onChanged: @escaping () async -> Void) {
        self.scheme = scheme
        self.onChanged = onChanged
        _categories = State(initialValue: scheme.categories)
    }

    var body: some View {
        List {
            if categories.isEmpty {
                Text("点右上角 ➕ 添加分类（如 吃 / 穿 / 住 / 行 / 用）")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(categories) { cat in
                NavigationLink(destination: SchemeCategoryProductsView(category: cat) { await reload() }) {
                    HStack {
                        Text(cat.name)
                        Spacer()
                        Text("\(cat.productCount ?? 0) 件商品")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button("删除", role: .destructive) {
                        Task { await remove(cat) }
                    }
                }
                .swipeActions(edge: .leading) {
                    Button("加子分类") { addParent = cat; showAdd = true }.tint(.blue)
                    // 带子分类的一级不能降为二级（否则出三级），只在无子分类时给「移动」
                    if cat.subcategories.isEmpty {
                        Button("移动") { moving = MoveTarget(cat: cat, parentId: nil) }.tint(.indigo)
                    }
                }
                // 二级分类：缩进行（删除 = 连带其商品归属；商品挂接与一级同入口）
                ForEach(cat.subcategories) { sub in
                    NavigationLink(destination: SchemeCategoryProductsView(category: sub) { await reload() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.caption2).foregroundStyle(.tertiary)
                            Text(sub.name)
                            Spacer()
                            Text("\(sub.productCount ?? 0) 件商品")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.leading, 16)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("删除", role: .destructive) {
                            Task { await remove(sub) }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button("移动") { moving = MoveTarget(cat: sub, parentId: cat.id) }.tint(.indigo)
                    }
                }
            }
            // AI 归类：作用于本方案既有分类的归类动作（与「起草方案」是两件事）
            Section {
                Button {
                    aiAssignToken = PresentToken()
                } label: {
                    Label("AI 归类", systemImage: "sparkles")
                }
                .disabled(categories.isEmpty)
            } footer: {
                Text(categories.isEmpty
                     ? "先添加分类，才能让 AI 把商品归入其中。"
                     : "让 AI 把商品归入本方案的现有分类；可选范围（全部/未归类/挑选），应用前可预览调整。")
            }
        }
        .listStyle(.insetGrouped)
        .sheet(item: $aiAssignToken) { _ in
            AIAssignSheet(schemeName: scheme.name, categories: categories) { msg in
                Task { await reload() }
                showToast(msg)
            }
        }
        .navigationTitle(scheme.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("添加分类")
            }
        }
        .alert(addParent.map { "在「\($0.name)」下添加子分类" } ?? "添加分类", isPresented: $showAdd) {
            TextField("分类名", text: $newName)
            Button("添加") { Task { await add() } }
            Button("取消", role: .cancel) { newName = ""; addParent = nil }
        }
        .confirmationDialog(moving.map { "移动「\($0.cat.name)」" } ?? "", isPresented: Binding(
            get: { moving != nil }, set: { if !$0 { moving = nil } }
        ), titleVisibility: .visible, presenting: moving) { target in
            if target.parentId != nil {
                Button("升为一级分类") { Task { await move(target.cat, to: nil) } }
            }
            ForEach(categories.filter { $0.id != target.cat.id && $0.id != target.parentId }) { top in
                Button("移到「\(top.name)」下") { Task { await move(target.cat, to: top.id) } }
            }
            Button("取消", role: .cancel) { moving = nil }
        }
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(.subheadline).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.black.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.top, 8)
            }
        }
    }

    private func add() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        let parentId = addParent?.id
        newName = ""
        addParent = nil
        guard !name.isEmpty else { return }
        do {
            try await MerchantConsoleService.shared.addSchemeCategory(schemeId: scheme.id, name: name, parentId: parentId)
            await reload()
        } catch {
            showToast("添加失败：\(error.localizedDescription)")
        }
    }

    /// parentId=nil → 升为一级；非空 → 移到该一级下。服务端做两级/环校验，失败如实透出。
    private func move(_ cat: CategoryScheme.Cat, to parentId: Int?) async {
        moving = nil
        do {
            try await MerchantConsoleService.shared.moveSchemeCategory(id: cat.id, parentId: parentId)
            await reload()
            showToast(parentId == nil ? "已升为一级" : "已移动")
        } catch {
            showToast("移动失败：\(error.localizedDescription)")
        }
    }

    private func remove(_ cat: CategoryScheme.Cat) async {
        do {
            try await MerchantConsoleService.shared.deleteSchemeCategory(id: cat.id)
            await reload()
        } catch {
            showToast("删除失败：\(error.localizedDescription)")
        }
    }

    /// 重新拉全量方案，取出本方案的最新分类（含 productCount）
    private func reload() async {
        await onChanged()
        if let fresh = try? await MerchantConsoleService.shared.schemes()
            .first(where: { $0.id == scheme.id }) {
            categories = fresh.categories
        }
    }

    private func showToast(_ msg: String) {
        toast = msg
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run { if toast == msg { toast = nil } }
        }
    }
}

// MARK: - 分类下商品勾选（整体替换保存）

struct SchemeCategoryProductsView: View {
    let category: CategoryScheme.Cat
    let onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var products: [MerchantProduct] = []
    @State private var selected: Set<String> = []
    @State private var isLoading = true
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let error {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            } else if products.isEmpty {
                ContentUnavailableView("店里还没有商品", systemImage: "tag",
                    description: Text("先在店铺页上架商品，再回来归类"))
            } else {
                List(products) { p in
                    Button {
                        if selected.contains(p.code) { selected.remove(p.code) }
                        else { selected.insert(p.code) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selected.contains(p.code) ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(selected.contains(p.code) ? Color.accentColor : Color.secondary)
                            CachedAsyncImage(url: URL(string: p.thumbnail ?? "")) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Color(.systemGray5)
                            }
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.subheadline).lineLimit(2)
                                if let price = p.price {
                                    Text("¥\(price.description)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving {
                    ProgressView()
                } else {
                    Button("保存(\(selected.count))") { Task { await save() } }
                        .disabled(isLoading)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            async let productsTask = MerchantConsoleService.shared.products()
            async let assignedTask = MerchantConsoleService.shared.schemeCategoryProducts(id: category.id)
            let (ps, assigned) = try await (productsTask, assignedTask)
            products = ps
            selected = Set(assigned)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await MerchantConsoleService.shared.setSchemeCategoryProducts(id: category.id, codes: Array(selected))
            await onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - AI 智能分类（Phase 3 产品化）
//
// 模板选择 → AI 生成草稿（AIClassifyService，端侧单次结构化调用）→ 预览编辑器
// （改方案名/分类名、商品移动/移出、看未归类）→ 保存：origin='ai' + 隐藏态落库，
// 商家在方案列表确认无误后左滑「显示」才对买家可见。编辑器即 HITL，无确认弹窗。

/// 分类思路模板（商家数据，按账号存本机；出厂四条只是首次种子）。
struct AIClassifyTemplate: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var description: String
    /// 出厂「吃穿住行用」标记：空店且描述仍为出厂原文时本地直建五分类、零 AI 调用。
    var isFactoryFixed = false
}

/// 模板存取的唯一管理点（按账号隔离，与会话属主同思路）。
/// UI 使用方：TemplateManageView（管理）与 AIClassifySheet（选用）。
@MainActor
enum AIClassifyTemplateStore {
    static let factoryFixedDescription = "分类固定为五个：吃（食品、饮料、生鲜、零食）、穿（服装、鞋帽、配饰）、住（家居、家纺、清洁、收纳）、行（出行装备、箱包、车品）、用（其他日用百货）。不要增减分类或改名。归类规则：每个商品按 吃→穿→住→行→用 的顺序匹配，同时符合多个时归入最靠前的那个；都不能准确匹配的一律放进「用」。"

    static let factoryTemplates: [AIClassifyTemplate] = [
        AIClassifyTemplate(title: "吃穿住行用", description: factoryFixedDescription, isFactoryFixed: true),
        AIClassifyTemplate(
            title: "按使用场景",
            description: "按商品被使用的典型场景起草分类，如：日常自用、送礼馈赠、节日聚会、户外出行、办公学习等；场景名 2–6 字，贴合本店经营定位，不要生造与本店无关的场景，并加一个「其他」兜底分类。归类规则：每个商品归入最典型的一个使用场景，同时符合多个时选更常见的那个；不好归的放「其他」。"),
        AIClassifyTemplate(
            title: "按人群",
            description: "按目标人群起草分类，如：男士、女士、儿童、长辈、学生等；只保留与本店商品相关的人群，人群名 2–4 字，并加一个「通用」兜底分类。归类规则：每个商品归入最主要的目标人群；男女老少皆宜或拿不准的放「通用」。"),
        AIClassifyTemplate(
            title: "按价格档",
            description: "按价格区间起草 3–5 个档位分类，如：百元以内、100–300、300–1000、千元以上；档位边界按本店商品的实际价格分布自然划分（无商品时用上述通用档位），档名简短直白。归类规则：每个商品按现价落入对应档位；缺价格的放最低档。"),
    ]

    private static var storageKey: String {
        "merchant_ai_classify_templates." + (AuthManager.shared.currentUserId ?? "guest")
    }

    static func load() -> [AIClassifyTemplate] {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let list = try? JSONDecoder().decode([AIClassifyTemplate].self, from: data),
           !list.isEmpty {
            return list
        }
        return factoryTemplates
    }

    private static func persist(_ list: [AIClassifyTemplate]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    @discardableResult
    static func upsert(_ t: AIClassifyTemplate) -> [AIClassifyTemplate] {
        var list = load()
        if let i = list.firstIndex(where: { $0.id == t.id }) { list[i] = t } else { list.append(t) }
        persist(list)
        return list
    }

    @discardableResult
    static func remove(id: UUID) -> [AIClassifyTemplate] {
        var list = load()
        list.removeAll { $0.id == id }
        persist(list)
        return list
    }

    @discardableResult
    static func reset() -> [AIClassifyTemplate] {
        persist(factoryTemplates)
        return factoryTemplates
    }

    /// 是否与出厂一致（按内容比，id 每次种子化会变）。
    static func isFactory(_ list: [AIClassifyTemplate]) -> Bool {
        list.map { [$0.title, $0.description] } == factoryTemplates.map { [$0.title, $0.description] }
    }
}

struct AIClassifySheet: View {
    let onSaved: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Stage { case input, generating, preview }

    // 模板 = 分类思路的标题 + 详细描述（管理在 TemplateManageView，这里只选用）。
    // 选中模板即填充描述框，商家可再临时改 —— 最终发给 AI 的永远是描述框内容。
    private static let ideaKey = "merchant_ai_classify_idea"
    private static let templateIdKey = "merchant_ai_classify_template_id"

    @State private var stage: Stage = .input
    @State private var products: [MerchantProduct] = []
    @State private var productsLoaded = false
    @State private var storeName: String?
    @State private var templates: [AIClassifyTemplate] = []
    @State private var selectedTemplateId: UUID?          // nil = 自定义
    @State private var idea = ""                // 思路描述（真相源，发给 AI 的即是它）
    @State private var draft: AIClassifyDraft?
    @State private var draftMoving: AIClassifyDraft.Category?   // 预览编辑器里正在改层级的分类
    @State private var saving = false
    @State private var errorMsg: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("AI 起草方案")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                            .disabled(stage == .generating || saving)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if stage == .preview {
                            if saving {
                                ProgressView()
                            } else {
                                Button("保存") { Task { await save() } }
                            }
                        }
                    }
                }
                .alert("出错了", isPresented: Binding(
                    get: { errorMsg != nil },
                    set: { if !$0 { errorMsg = nil } }
                )) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text(errorMsg ?? "")
                }
                .task {
                    restoreLastIdea()
                    await loadStore()
                }
        }
        .interactiveDismissDisabled(stage == .generating || saving)
    }

    // MARK: 阶段视图

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .input:
            inputForm
        case .generating:
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text(products.isEmpty
                     ? "AI 正在起草分类框架…"
                     : "AI 正在为 \(products.count) 件商品起草分类…")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("通常需要十几秒，请稍候")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        case .preview:
            previewEditor
        }
    }

    private var inputForm: some View {
        Form {
            Section {
                ForEach(templates) { t in
                    Button {
                        selectedTemplateId = t.id
                        idea = t.description
                    } label: {
                        HStack {
                            Text(t.title)
                            Spacer()
                            if selectedTemplateId == t.id { checkmark }
                        }
                    }
                    .foregroundStyle(.primary)
                }
                Button {
                    selectedTemplateId = nil
                    idea = ""
                } label: {
                    HStack {
                        Text("自定义")
                        Spacer()
                        if selectedTemplateId == nil { checkmark }
                    }
                }
                .foregroundStyle(.primary)
                NavigationLink("管理分类思路模板…") {
                    TemplateManageView()
                }
                .font(.subheadline)
            } header: {
                Text("分类思路")
            } footer: {
                Text("选择后可在下方修改描述，最终以描述为准。")
            }
            Section {
                TextField("描述分类框架怎么定、商品怎么归类（含兜底），如「按烘焙品类分：面包、蛋糕、饼干…不好归的放其他」",
                          text: $idea, axis: .vertical)
                    .lineLimit(4...12)
            } header: {
                Text("思路描述（AI 按此执行，可修改）")
            } footer: {
                Text(inputFooter)
            }
            Section {
                Button {
                    Task { await generate() }
                } label: {
                    Text("生成草稿").frame(maxWidth: .infinity)
                }
                .disabled(!canGenerate)
            }
        }
        // 从「管理模板」页返回时同步最新模板；被删的选中项自动落回自定义
        .onAppear {
            let fresh = AIClassifyTemplateStore.load()
            if fresh.map(\.id) != templates.map(\.id)
                || fresh.map(\.description) != templates.map(\.description)
                || fresh.map(\.title) != templates.map(\.title) {
                templates = fresh
                if let sel = selectedTemplateId, !fresh.contains(where: { $0.id == sel }) {
                    selectedTemplateId = nil
                }
            }
        }
    }

    private var inputFooter: String {
        guard productsLoaded else { return "正在读取店铺商品…" }
        if products.isEmpty {
            return "店内暂无商品：将只生成分类框架（空分类），商品上架后再归入。生成后可预览调整，保存后默认隐藏，确认无误再开放给买家。"
        }
        return "AI 将按思路起草框架，并把店内 \(products.count) 件商品归类；生成后可预览调整，保存后默认隐藏，确认无误再开放给买家。"
    }

    @ViewBuilder
    private var previewEditor: some View {
        if draft != nil {
            List {
                Section("方案名") {
                    TextField("方案名", text: Binding(
                        get: { self.draft?.schemeName ?? "" },
                        set: { self.draft?.schemeName = $0 }
                    ))
                }
                ForEach(orderedCats) { cat in
                    categorySection(cat)
                }
                unassignedSection
                Section {
                    Button {
                        addTopCategory()
                    } label: {
                        Label("添加一级分类", systemImage: "plus.circle")
                    }
                } footer: {
                    Text("AI 摆错了也没关系：可在此加分类、加子分类（分类的「…」菜单），或把分类移动/改级后再保存。")
                }
            }
            .listStyle(.insetGrouped)
            .confirmationDialog(draftMoving.map { "移动「\($0.name)」" } ?? "", isPresented: Binding(
                get: { draftMoving != nil }, set: { if !$0 { draftMoving = nil } }
            ), titleVisibility: .visible, presenting: draftMoving) { target in
                if target.parentId != nil {
                    Button("升为一级分类") { moveDraftCategory(target.id, to: nil); draftMoving = nil }
                }
                // 带子分类的一级不能降为二级；只对无子分类的分类给「移到…下」
                if !draftHasChildren(target.id) {
                    ForEach(draftTopCategories.filter { $0.id != target.id && $0.id != target.parentId }) { top in
                        Button("移到「\(top.name)」下") { moveDraftCategory(target.id, to: top.id); draftMoving = nil }
                    }
                }
                Button("取消", role: .cancel) { draftMoving = nil }
            }
        }
    }

    /// 展示顺序：一级后紧跟其二级；孤儿（parent 已删等异常）兜底排最后
    private var orderedCats: [AIClassifyDraft.Category] {
        let all = draft?.categories ?? []
        let tops = all.filter { $0.parentId == nil }
        var out = tops.flatMap { t in [t] + all.filter { $0.parentId == t.id } }
        let covered = Set(out.map(\.id))
        out += all.filter { !covered.contains($0.id) }
        return out
    }

    /// 分类显示名：二级带父名前缀（移动菜单/歧义消解用）
    private func catLabel(_ cat: AIClassifyDraft.Category) -> String {
        guard let pid = cat.parentId,
              let parent = draft?.categories.first(where: { $0.id == pid }) else { return cat.name }
        return "\(parent.name)/\(cat.name)"
    }

    private func categorySection(_ cat: AIClassifyDraft.Category) -> some View {
        Section {
            HStack(spacing: 8) {
                if cat.parentId != nil {
                    Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(.tertiary)
                }
                Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
                TextField("分类名", text: nameBinding(for: cat.id)).bold()
            }
            ForEach(cat.productCodes, id: \.self) { code in
                productRow(code, in: cat)
            }
            if cat.productCodes.isEmpty {
                Text("暂无商品").font(.caption).foregroundStyle(.tertiary)
            }
        } header: {
            HStack {
                if let pid = cat.parentId,
                   let parent = draft?.categories.first(where: { $0.id == pid }) {
                    Text("二级 · 属「\(parent.name)」 · \(cat.productCodes.count) 件")
                } else {
                    Text("分类 · \(cat.productCodes.count) 件")
                }
                Spacer()
                Menu {
                    if cat.parentId == nil {
                        Button { addSubcategory(parentId: cat.id) } label: { Label("添加子分类", systemImage: "plus") }
                    }
                    // 二级可动；一级只有无子分类时可降级（有子分类降级会出三级）
                    if cat.parentId != nil || !draftHasChildren(cat.id) {
                        Button { draftMoving = cat } label: { Label("移动 / 改级", systemImage: "arrow.up.arrow.down") }
                    }
                    Button(role: .destructive) { removeCategory(cat.id) } label: { Label("删除分类", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private func productRow(_ code: String, in cat: AIClassifyDraft.Category) -> some View {
        HStack(spacing: 10) {
            productThumb(code)
            Text(productsByCode[code]?.name ?? code)
                .font(.subheadline).lineLimit(1)
            Spacer()
            Menu {
                moveButtons(code, excluding: cat.id)
                Button("移出（不归类）", role: .destructive) { unassign(code) }
            } label: {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption).foregroundStyle(Color.accentColor)
            }
        }
        .swipeActions(edge: .trailing) {
            Button("移出", role: .destructive) { unassign(code) }
        }
    }

    @ViewBuilder
    private var unassignedSection: some View {
        let codes = unassignedCodes
        if !codes.isEmpty {
            Section {
                ForEach(codes, id: \.self) { code in
                    HStack(spacing: 10) {
                        productThumb(code)
                        Text(productsByCode[code]?.name ?? code)
                            .font(.subheadline).lineLimit(1)
                        Spacer()
                        Menu {
                            moveButtons(code, excluding: nil)
                        } label: {
                            Text("归入").font(.caption).foregroundStyle(Color.accentColor)
                        }
                    }
                }
            } header: {
                Text("未归类 · \(codes.count) 件")
            } footer: {
                Text("未归类的商品不会出现在该方案视角里")
            }
        }
    }

    private func productThumb(_ code: String) -> some View {
        CachedAsyncImage(url: URL(string: productsByCode[code]?.thumbnail ?? "")) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color(.systemGray5)
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func moveButtons(_ code: String, excluding catId: UUID?) -> some View {
        ForEach(orderedCats) { other in
            if other.id != catId {
                Button("移到「\(catLabel(other))」") { move(code, to: other.id) }
            }
        }
    }

    private var checkmark: some View {
        Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Color.accentColor)
    }

    // MARK: 派生状态

    private var draftTopCategories: [AIClassifyDraft.Category] {
        (draft?.categories ?? []).filter { $0.parentId == nil }
    }

    private func draftHasChildren(_ id: UUID) -> Bool {
        (draft?.categories ?? []).contains { $0.parentId == id }
    }

    private var canGenerate: Bool {
        productsLoaded && !idea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var productsByCode: [String: MerchantProduct] {
        Dictionary(products.map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private var unassignedCodes: [String] {
        guard let draft else { return [] }
        let assigned = Set(draft.categories.flatMap(\.productCodes))
        return products.map(\.code).filter { !assigned.contains($0) }
    }

    private func nameBinding(for catId: UUID) -> Binding<String> {
        Binding(
            get: { draft?.categories.first(where: { $0.id == catId })?.name ?? "" },
            set: { newValue in
                guard var d = draft,
                      let i = d.categories.firstIndex(where: { $0.id == catId }) else { return }
                d.categories[i].name = newValue
                draft = d
            }
        )
    }

    // MARK: 草稿变更

    private func move(_ code: String, to catId: UUID) {
        guard var d = draft else { return }
        for i in d.categories.indices {
            d.categories[i].productCodes.removeAll { $0 == code }
        }
        if let i = d.categories.firstIndex(where: { $0.id == catId }) {
            d.categories[i].productCodes.append(code)
        }
        draft = d
    }

    private func unassign(_ code: String) {
        guard var d = draft else { return }
        for i in d.categories.indices {
            d.categories[i].productCodes.removeAll { $0 == code }
        }
        draft = d
    }

    private func removeCategory(_ id: UUID) {
        // 删一级连带其二级（与服务端级联语义一致）
        draft?.categories.removeAll { $0.id == id || $0.parentId == id }
    }

    private func addTopCategory() {
        draft?.categories.append(AIClassifyDraft.Category(name: "新分类", productCodes: []))
    }

    private func addSubcategory(parentId: UUID) {
        draft?.categories.append(AIClassifyDraft.Category(name: "新子分类", productCodes: [], parentId: parentId))
    }

    /// 草稿内改层级：parentId=nil → 升为一级；非空 → 移到该一级下（保存时按两遍落库）
    private func moveDraftCategory(_ id: UUID, to parentId: UUID?) {
        guard var d = draft, let i = d.categories.firstIndex(where: { $0.id == id }) else { return }
        d.categories[i].parentId = parentId
        draft = d
    }

    // MARK: 动作

    /// 载入模板 + 恢复上次用过的思路描述；首次进入默认第一个模板。
    private func restoreLastIdea() {
        templates = AIClassifyTemplateStore.load()
        if let saved = UserDefaults.standard.string(forKey: Self.ideaKey), !saved.isEmpty {
            idea = saved
            if let idStr = UserDefaults.standard.string(forKey: Self.templateIdKey),
               let id = UUID(uuidString: idStr),
               templates.contains(where: { $0.id == id }) {
                selectedTemplateId = id
            }
        } else if let first = templates.first {
            selectedTemplateId = first.id
            idea = first.description
        }
    }

    private func loadStore() async {
        do {
            products = try await MerchantConsoleService.shared.products()
        } catch {
            errorMsg = error.localizedDescription
        }
        storeName = (try? await MerchantConsoleService.shared.myStore())?.name
        productsLoaded = true
    }

    private func generate() async {
        let trimmedIdea = idea.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmedIdea, forKey: Self.ideaKey)
        UserDefaults.standard.set(selectedTemplateId?.uuidString ?? "", forKey: Self.templateIdKey)

        // 出厂固定框架（吃穿住行用）+ 空店 + 描述未改 → 分类已知，本地直建，零 AI 调用
        // （商家改过描述则规则可能已变，老老实实走 AI）
        if products.isEmpty,
           let t = templates.first(where: { $0.id == selectedTemplateId }),
           t.isFactoryFixed,
           trimmedIdea == AIClassifyTemplateStore.factoryFixedDescription {
            draft = AIClassifyDraft(
                schemeName: t.title,
                categories: ["吃", "穿", "住", "行", "用"]
                    .map { AIClassifyDraft.Category(name: $0, productCodes: []) })
            stage = .preview
            return
        }

        stage = .generating
        do {
            draft = try await AIClassifyService.generateDraft(
                idea: trimmedIdea, storeName: storeName, products: products)
            stage = .preview
        } catch {
            errorMsg = error.localizedDescription
            stage = .input
        }
    }

    private func save() async {
        guard let draft else { return }
        let name = draft.schemeName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            errorMsg = "方案名不能为空"
            return
        }
        let cats = draft.categories.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !cats.isEmpty else {
            errorMsg = "至少保留一个分类"
            return
        }
        saving = true
        defer { saving = false }
        do {
            let scheme = try await MerchantConsoleService.shared.createScheme(
                name: name, origin: "ai", isVisible: false)
            // 两级落库：先建全部一级拿 server id，再建二级挂 parentId。
            // 二级的父被商家在编辑器删名/剔除时降级为一级，绝不丢分类。
            var serverId: [UUID: Int] = [:]
            for cat in cats where cat.parentId == nil {
                let catId = try await MerchantConsoleService.shared.addSchemeCategory(
                    schemeId: scheme.id, name: cat.name.trimmingCharacters(in: .whitespaces))
                serverId[cat.id] = catId
                if !cat.productCodes.isEmpty {
                    try await MerchantConsoleService.shared.setSchemeCategoryProducts(
                        id: catId, codes: cat.productCodes, assignedBy: "ai")
                }
            }
            for cat in cats where cat.parentId != nil {
                let catId = try await MerchantConsoleService.shared.addSchemeCategory(
                    schemeId: scheme.id, name: cat.name.trimmingCharacters(in: .whitespaces),
                    parentId: cat.parentId.flatMap { serverId[$0] })
                if !cat.productCodes.isEmpty {
                    try await MerchantConsoleService.shared.setSchemeCategoryProducts(
                        id: catId, codes: cat.productCodes, assignedBy: "ai")
                }
            }
            onSaved("AI 方案已保存（隐藏中），确认无误后左滑「显示」")
            dismiss()
        } catch {
            errorMsg = "保存失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - AI 归类（把商品归入既有方案的固定分类；范围可选，应用前差异预览）
//
// 与「AI 起草方案」是两个动作：起草=建框架（作用于新方案）；归类=往既有框架里放商品。
// 典型场景：新品上架后归入现有方案、部分商品重归类。server 零改（复用整体替换端点）。

struct AIAssignSheet: View {
    let schemeName: String
    let categories: [CategoryScheme.Cat]
    let onApplied: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Stage { case scope, working, preview }
    private enum ScopeChoice: String, CaseIterable {
        case unassigned = "仅未归类商品"
        case all = "全部商品"
        case picked = "挑选商品"
    }

    private struct Proposal: Identifiable {
        let id = UUID()
        let code: String
        let name: String
        let fromCatId: Int?      // nil = 未归类
        let toCatId: Int
    }

    @State private var stage: Stage = .scope
    @State private var scope: ScopeChoice = .unassigned
    @State private var note = ""
    @State private var products: [MerchantProduct] = []
    @State private var codesByCat: [Int: [String]] = [:]        // 分类 id → 当前商品
    @State private var currentCatByCode: [String: Int] = [:]    // 商品 → 当前分类 id
    @State private var loaded = false
    @State private var picked: Set<String> = []
    @State private var proposals: [Proposal] = []
    @State private var applying = false
    @State private var errorMsg: String?
    @State private var storeName: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("AI 归类")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                            .disabled(stage == .working || applying)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if stage == .preview {
                            if applying {
                                ProgressView()
                            } else {
                                Button("应用(\(proposals.count))") { Task { await apply() } }
                                    .disabled(proposals.isEmpty)
                            }
                        }
                    }
                }
                .alert("出错了", isPresented: Binding(
                    get: { errorMsg != nil },
                    set: { if !$0 { errorMsg = nil } }
                )) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text(errorMsg ?? "")
                }
                .task { await load() }
        }
        .interactiveDismissDisabled(stage == .working || applying)
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .scope:
            scopeForm
        case .working:
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text("AI 正在为 \(scopedProducts.count) 件商品归类…")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("通常需要十几秒，请稍候")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        case .preview:
            previewList
        }
    }

    private var scopeForm: some View {
        Form {
            Section {
                ForEach(ScopeChoice.allCases, id: \.self) { c in
                    Button {
                        scope = c
                    } label: {
                        HStack {
                            Text(c.rawValue)
                            Spacer()
                            Text("\(count(for: c)) 件").font(.caption).foregroundStyle(.secondary)
                            if scope == c {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold).foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            } header: {
                Text("归类范围")
            } footer: {
                Text("AI 只在本方案的现有分类（\(flatCats.map(\.name).joined(separator: "、"))）中归类，不会新建分类；归不进的保持原状。")
            }
            if scope == .picked {
                Section("挑选商品") {
                    ForEach(products) { p in
                        Button {
                            if picked.contains(p.code) { picked.remove(p.code) } else { picked.insert(p.code) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: picked.contains(p.code) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(picked.contains(p.code) ? Color.accentColor : Color.secondary)
                                Text(p.name).font(.subheadline).lineLimit(1)
                                Spacer()
                                Text(catName(currentCatByCode[p.code]))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Section("补充说明（可选，AI 优先遵守）") {
                TextField("如「生鲜类都放进吃」", text: $note, axis: .vertical)
                    .lineLimit(2...6)
            }
            // 加载失败/慢链路兜底：显式重载，不逼用户关掉重开
            if loaded && products.isEmpty {
                Section {
                    Button("重新加载商品") {
                        Task {
                            loaded = false
                            await load()
                        }
                    }
                } footer: {
                    Text("商品加载失败或店内暂无商品。")
                }
            }
            Section {
                Button {
                    Task { await run() }
                } label: {
                    Text("开始归类").frame(maxWidth: .infinity)
                }
                .disabled(!loaded || scopedProducts.isEmpty)
            }
        }
    }

    private var previewList: some View {
        List {
            Section {
                ForEach(proposals) { p in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.name).font(.subheadline).lineLimit(1)
                        Text("\(catName(p.fromCatId)) → \(catName(p.toCatId))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("排除", role: .destructive) {
                            proposals.removeAll { $0.id == p.id }
                        }
                    }
                }
            } header: {
                Text("将变动 \(proposals.count) 件（左滑可排除）")
            } footer: {
                Text("未列出的商品维持原状。点右上「应用」生效。")
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: 派生

    /// 归类目标 = 一级 + 二级平铺；二级显示名「父/子」（prompt 与映射共用，防跨级重名歧义）
    private var flatCats: [(id: Int, name: String)] {
        categories.flatMap { c in
            [(c.id, c.name)] + c.subcategories.map { ($0.id, "\(c.name)/\($0.name)") }
        }
    }

    private var scopedProducts: [MerchantProduct] {
        switch scope {
        case .all: return products
        case .unassigned: return products.filter { currentCatByCode[$0.code] == nil }
        case .picked: return products.filter { picked.contains($0.code) }
        }
    }

    private func count(for c: ScopeChoice) -> Int {
        switch c {
        case .all: return products.count
        case .unassigned: return products.filter { currentCatByCode[$0.code] == nil }.count
        case .picked: return picked.count
        }
    }

    private func catName(_ id: Int?) -> String {
        guard let id else { return "未归类" }
        return flatCats.first(where: { $0.id == id })?.name ?? "#\(id)"
    }

    // MARK: 动作

    private func load() async {
        do {
            products = try await MerchantConsoleService.shared.products()
            var byCat: [Int: [String]] = [:]
            for cat in flatCats {
                byCat[cat.id] = try await MerchantConsoleService.shared.schemeCategoryProducts(id: cat.id)
            }
            codesByCat = byCat
            currentCatByCode = byCat.reduce(into: [:]) { acc, kv in
                for code in kv.value { acc[code] = kv.key }
            }
        } catch {
            errorMsg = error.localizedDescription
        }
        storeName = (try? await MerchantConsoleService.shared.myStore())?.name
        loaded = true
    }

    private func run() async {
        stage = .working
        do {
            let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try await AIClassifyService.assignProducts(
                schemeName: schemeName, storeName: storeName,
                categories: flatCats.map(\.name),
                products: scopedProducts,
                note: trimmedNote.isEmpty ? nil : trimmedNote)
            let idByName = Dictionary(flatCats.map { ($0.name, $0.id) }, uniquingKeysWith: { a, _ in a })
            let nameByCode = Dictionary(products.map { ($0.code, $0.name) }, uniquingKeysWith: { a, _ in a })
            var out: [Proposal] = []
            for (name, codes) in result {
                guard let toId = idByName[name] else { continue }
                for code in codes where currentCatByCode[code] != toId {
                    out.append(Proposal(code: code, name: nameByCode[code] ?? code,
                                        fromCatId: currentCatByCode[code], toCatId: toId))
                }
            }
            if out.isEmpty {
                errorMsg = "AI 认为这些商品无需变动（或无法归入现有分类）。"
                stage = .scope
            } else {
                proposals = out.sorted { $0.name < $1.name }
                stage = .preview
            }
        } catch {
            errorMsg = error.localizedDescription
            stage = .scope
        }
    }

    private func apply() async {
        applying = true
        defer { applying = false }
        var finalByCat = codesByCat
        for p in proposals {
            if let from = p.fromCatId {
                finalByCat[from]?.removeAll { $0 == p.code }
            }
            finalByCat[p.toCatId, default: []].append(p.code)
        }
        let affected = Set(proposals.flatMap { [$0.fromCatId, $0.toCatId].compactMap { $0 } })
        do {
            for catId in affected {
                try await MerchantConsoleService.shared.setSchemeCategoryProducts(
                    id: catId, codes: finalByCat[catId] ?? [], assignedBy: "ai")
            }
            onApplied("已按 AI 建议归类 \(proposals.count) 件商品")
            dismiss()
        } catch {
            errorMsg = "应用失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 分类思路模板管理（独立页；生成流程里只「选用」，管理集中在这）

struct TemplateManageView: View {
    @State private var templates: [AIClassifyTemplate] = []
    @State private var editing: AIClassifyTemplate?

    var body: some View {
        List {
            Section {
                ForEach(templates) { t in
                    Button { editing = t } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(t.title)
                            Text(t.description)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .foregroundStyle(.primary)
                    .swipeActions(edge: .trailing) {
                        Button("删除", role: .destructive) {
                            templates = AIClassifyTemplateStore.remove(id: t.id)
                        }
                        Button("编辑") { editing = t }.tint(.orange)
                    }
                }
            } footer: {
                Text("模板 = 分类思路的标题 + 给 AI 的详细描述（建议结构：框架定义/判据 + 归类规则）。点击可编辑。")
            }
            Section {
                Button {
                    editing = AIClassifyTemplate(title: "", description: "")
                } label: {
                    Label("新增模板", systemImage: "plus")
                }
                // 常驻显示（与出厂一致时置灰）——条件隐藏会让人以为功能没了
                Button("恢复默认模板", role: .destructive) {
                    templates = AIClassifyTemplateStore.reset()
                }
                .disabled(AIClassifyTemplateStore.isFactory(templates))
            } footer: {
                Text("恢复默认会用出厂四条模板整体覆盖当前列表。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("分类思路模板")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { t in
            TemplateEditSheet(template: t) { saved in
                templates = AIClassifyTemplateStore.upsert(saved)
            }
        }
        .onAppear { templates = AIClassifyTemplateStore.load() }
    }
}

// MARK: - 模板编辑/新增（标题 + 描述都是商家数据，保存即持久）

private struct TemplateEditSheet: View {
    @State var template: AIClassifyTemplate
    let onSave: (AIClassifyTemplate) -> Void

    @Environment(\.dismiss) private var dismiss

    private var canSave: Bool {
        !template.title.trimmingCharacters(in: .whitespaces).isEmpty
            && !template.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("标题") {
                    TextField("模板标题，如「按烘焙品类」", text: $template.title)
                }
                Section {
                    TextField("框架怎么定（分类有哪些/判据）+ 商品怎么归类（消歧顺序、兜底分类）…",
                              text: $template.description, axis: .vertical)
                        .lineLimit(6...16)
                } header: {
                    Text("思路描述（AI 按此执行）")
                } footer: {
                    Text("建议结构：框架定义/判据 + 归类规则（多类冲突怎么选 + 归不进的放哪）。")
                }
            }
            .navigationTitle("编辑模板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(template)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}
