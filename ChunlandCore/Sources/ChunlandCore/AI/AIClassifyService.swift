import Foundation

// MARK: - AI 分类草稿
//
// 与聊天链路（AIOrchestrator agentic loop）刻意分离：这里不是对话，是编辑期的
// **单次结构化调用** —— AI 产出草稿 → 预览编辑器（商家改名/挪动/剔除）→ 确认才落库。
// 编辑器本身就是 HITL，不走 mutation 确认弹窗。AI 凭证仍全在端侧（系统 AI / 自配，
// 与聊天同一配置源），不发往本项目服务端；落库走普通商家 REST（origin='ai' 溯源）。

public struct AIClassifyDraft: Sendable {
    public struct Category: Sendable, Identifiable {
        public let id: UUID
        public var name: String
        public var productCodes: [String]
        /// 两级：非 nil = 二级，指向同草稿里某个一级分类的 id（按 id 引用，改名安全）
        public var parentId: UUID?

        public init(name: String, productCodes: [String], parentId: UUID? = nil) {
            self.id = UUID()
            self.name = name
            self.productCodes = productCodes
            self.parentId = parentId
        }
    }

    public var schemeName: String
    public var categories: [Category]

    public init(schemeName: String, categories: [Category]) {
        self.schemeName = schemeName
        self.categories = categories
    }
}

@MainActor
public enum AIClassifyService {

    public enum ClassifyError: LocalizedError {
        case notConfigured
        case serviceUnavailable
        case badResponse(String)

        public var errorDescription: String? {
            switch self {
            case .notConfigured: return "尚未配置 AI 来源，请到「AI 助手 → 配置」选择"
            case .serviceUnavailable: return "AI 服务暂不可用，请稍后再试"
            case .badResponse(let d): return "AI 返回内容无法解析，请重试（\(d)）"
            }
        }
    }

    /// idea：商家的分类思路描述（模板填充 + 可编辑，标准结构 = 框架定义 + 归类规则含兜底）。
    /// **框架由思路与店铺定位驱动，商品只是参考与归类对象** —— 分类方案是前瞻性的经营框架，
    /// 不被当前在售商品窄化；products 允许为空（只起草框架，商品上架后再归类）。
    /// 产出已做净化：剥代码围栏、过滤编造/重复 code、名称截 20 字。
    public static func generateDraft(idea: String, storeName: String? = nil,
                                     products: [MerchantProduct]) async throws -> AIClassifyDraft {
        guard let cfg = resolveEndpoint() else {
            throw UserDefaults.standard.bool(forKey: "ai_use_system")
                ? ClassifyError.serviceUnavailable : ClassifyError.notConfigured
        }

        let store = storeName.map { "「\($0)」" } ?? ""
        let productLines = products.isEmpty
            ? "（暂无商品）"
            : products.map { p in
                let price = p.price.map { "¥\($0)" } ?? "-"
                return "\(p.code)|\(p.name)|\(price)"
            }.joined(separator: "\n")
        let prompt = """
        你是电商商品分类专家。为店铺\(store)起草一套商品分类方案。

        商家的分类思路（首要依据，其中的规则必须严格执行）：
        \(idea)

        当前商品清单（每行：code|名称|价格。仅作参考与归类对象，可能远少于店铺未来的商品）：
        \(productLines)

        要求：
        1. 分类框架以商家思路和店铺定位为准，覆盖本店经营的商品空间，不要被当前在售商品窄化；思路中已固定分类名单的，严格照用、不得增减改名
        2. 方案名不超过 20 字；一级分类 2–8 个，每个分类名不超过 20 字
        3. 支持两级：某个一级需要细分时，给细分分类加 "parent" 字段（值 = 一级分类名）；最多两级、两级合计不超过 30 个；思路要求了层级就按思路，思路没要求时只在明显必要处使用二级
        4. 归类：每个商品按思路中的规则归入且仅归入一个分类（一级或二级均可；思路未给规则时归最贴切的）；只允许引用清单中出现的 code，绝不编造；清单为空时所有 productCodes 为空数组
        5. 只输出 JSON，不要任何解释文字，格式：
        {"schemeName":"...","categories":[{"name":"吃","productCodes":[]},{"name":"零食","parent":"吃","productCodes":["..."]}]}
        """

        let raw = try await completeOnce(cfg: cfg, prompt: prompt)
        return try parseDraft(raw, validCodes: Set(products.map(\.code)))
    }

    /// AI 归类（作用于**既有方案**）：把选定商品归入方案的固定分类集合，不起草新框架。
    /// 与 generateDraft 是两个不同动作 —— 起草=建框架（全店视角）；归类=往框架里放商品（可选范围）。
    /// 返回 分类名 → 商品 code 列表；模型认为归不进任何分类的商品会缺席（= 保持原状）。
    public static func assignProducts(schemeName: String, storeName: String? = nil,
                                      categories: [String], products: [MerchantProduct],
                                      note: String? = nil) async throws -> [String: [String]] {
        guard let cfg = resolveEndpoint() else {
            throw UserDefaults.standard.bool(forKey: "ai_use_system")
                ? ClassifyError.serviceUnavailable : ClassifyError.notConfigured
        }

        let store = storeName.map { "「\($0)」" } ?? ""
        let catList = categories.map { "「\($0)」" }.joined(separator: "、")
        let productLines = products.map { p in
            let price = p.price.map { "¥\($0)" } ?? "-"
            return "\(p.code)|\(p.name)|\(price)"
        }.joined(separator: "\n")
        let extra = (note?.isEmpty == false) ? "\n商家补充的归类规则（优先遵守）：\(note!)\n" : ""
        let prompt = """
        你是电商商品分类专家。店铺\(store)的分类方案「\(schemeName)」有固定分类：\(catList)。
        请把下面的商品逐一归入上述分类：
        - 分类名严格照用，不得新增、改名；名称含「/」的是二级分类（父/子），输出时整体原样照用
        - 同一商品在「父」与「父/子」都合适时，优先归入更具体的「父/子」
        - 每个商品归入且仅归入一个最贴切的分类
        - 确实无法归入任何分类的商品，不要出现在输出里（它将保持原状）
        \(extra)
        商品清单（每行：code|名称|价格；只允许引用清单中的 code，绝不编造）：
        \(productLines)

        只输出 JSON，不要任何解释文字，格式：
        {"categories":[{"name":"...","productCodes":["...","..."]}]}
        """

        let raw = try await completeOnce(cfg: cfg, prompt: prompt)
        return try parseAssignments(raw, validCategories: Set(categories),
                                    validCodes: Set(products.map(\.code)))
    }

    // MARK: - 配置解析（与 AIOrchestrator.restoreConfig 同一真相源：UserDefaults + Keychain + SystemAIProvider）

    private static func resolveEndpoint() -> (base: String, model: String, key: String)? {
        if UserDefaults.standard.bool(forKey: "ai_use_system") {
            guard let ep = SystemAIProvider.endpoint else { return nil }
            return (ep.absoluteString, SystemAIProvider.defaultModel, SystemAIProvider.internalKey)
        }
        guard let base = UserDefaults.standard.string(forKey: "ai_base_url"),
              let model = UserDefaults.standard.string(forKey: "ai_model"),
              let key = AuthManager.shared.aiApiKey, !key.isEmpty else { return nil }
        return (base, model, key)
    }

    // MARK: - 单次补全（SSE 聚合）
    //
    // 走 stream:true 后聚合 —— 与聊天链路同一协议路径，系统 AI / 自配端点都实测可用；
    // 不押注端点实现了非流式。

    private static func completeOnce(cfg: (base: String, model: String, key: String),
                                     prompt: String) async throws -> String {
        guard let url = URL(string: cfg.base + "/chat/completions") else {
            throw ClassifyError.notConfigured
        }
        struct Req: Encodable {
            let model: String
            let messages: [[String: String]]
            let stream: Bool
        }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(cfg.key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(
            Req(model: cfg.model, messages: [["role": "user", "content": prompt]], stream: true)
        )

        struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String? }
                let delta: Delta
            }
            let choices: [Choice]?
        }

        let (stream, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw ClassifyError.badResponse("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let decoder = JSONDecoder()
        var out = ""
        for try await line in stream.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? decoder.decode(Chunk.self, from: data),
                  let delta = chunk.choices?.first?.delta.content else { continue }
            out += delta
        }
        return out
    }

    // MARK: - 解析与净化

    /// 剥 markdown 代码围栏 + 截取首个 { 到末个 }（有些模型前后附言）。
    private static func jsonSlice(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b {
            s = String(s[a...b])
        }
        return s
    }

    /// AI 归类结果解析：过滤未知分类名/编造 code，跨分类重复归属保留首个。
    static func parseAssignments(_ raw: String, validCategories: Set<String>,
                                 validCodes: Set<String>) throws -> [String: [String]] {
        struct Wire: Decodable {
            struct C: Decodable { let name: String; let productCodes: [String]? }
            let categories: [C]
        }
        guard let data = jsonSlice(raw).data(using: .utf8),
              let wire = try? JSONDecoder().decode(Wire.self, from: data),
              !wire.categories.isEmpty else {
            throw ClassifyError.badResponse(String(raw.prefix(80)))
        }
        var seen = Set<String>()
        var out: [String: [String]] = [:]
        for c in wire.categories {
            let name = c.name.trimmingCharacters(in: .whitespaces)
            guard validCategories.contains(name) else { continue }
            let codes = (c.productCodes ?? []).filter { validCodes.contains($0) && seen.insert($0).inserted }
            if !codes.isEmpty { out[name, default: []].append(contentsOf: codes) }
        }
        return out
    }

    static func parseDraft(_ raw: String, validCodes: Set<String>) throws -> AIClassifyDraft {
        let s = jsonSlice(raw)
        struct Wire: Decodable {
            struct C: Decodable { let name: String; let parent: String?; let productCodes: [String]? }
            let schemeName: String
            let categories: [C]
        }
        guard let data = s.data(using: .utf8),
              let wire = try? JSONDecoder().decode(Wire.self, from: data) else {
            throw ClassifyError.badResponse(String(raw.prefix(80)))
        }
        var seen = Set<String>()
        // 第一遍：净化名称/过滤编造 code（跨分类重复归属只保留首个），暂存 parent 名
        let tmp = wire.categories.compactMap { c -> (cat: AIClassifyDraft.Category, parentName: String?)? in
            let name = c.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            let codes = (c.productCodes ?? []).filter { validCodes.contains($0) && seen.insert($0).inserted }
            let parent = c.parent?.trimmingCharacters(in: .whitespaces)
            return (AIClassifyDraft.Category(name: String(name.prefix(20)), productCodes: codes),
                    (parent?.isEmpty ?? true) ? nil : parent)
        }
        // 第二遍：parent 名解析成一级 id（只有无 parent 的行算一级；同名取首个）。
        // 无效 parent（不存在/指向二级/自指）→ 降级为一级，绝不因模型笔误丢分类
        var topByName: [String: UUID] = [:]
        for (cat, parent) in tmp where parent == nil {
            if topByName[cat.name] == nil { topByName[cat.name] = cat.id }
        }
        let cats = tmp.map { entry -> AIClassifyDraft.Category in
            var cat = entry.cat
            if let p = entry.parentName, let pid = topByName[p], pid != cat.id {
                cat.parentId = pid
            }
            return cat
        }
        guard !cats.isEmpty else { throw ClassifyError.badResponse("空分类") }
        let name = wire.schemeName.trimmingCharacters(in: .whitespaces)
        return AIClassifyDraft(schemeName: String((name.isEmpty ? "AI 分类" : name).prefix(20)),
                               categories: cats)
    }
}
