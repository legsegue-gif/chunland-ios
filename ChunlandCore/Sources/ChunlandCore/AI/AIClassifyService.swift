import Foundation

// MARK: - AI 分类草稿
//
// 与聊天链路刻意分离：这里不是对话，是编辑期的**单次结构化调用** ——
// AI 产出草稿 → 预览编辑器（商家改名/挪动/剔除）→ 确认才落库。
// 编辑器本身就是 HITL，不走 mutation 确认弹窗。
//
// 走 `LLMProvider`（单次协议）而不是自建一套传输：与对话链路共用同一份
// endpoint 解析、SSE 解析、错误分类，**顺带白拿重试与降级** ——
// 单次调用一样会遇到限流和空响应，旧实现只有三个 error case 直接抛给用户。

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

        \(AIPrompts.classificationRules)

        输出：二级分类用 "parent" 字段指向一级分类名；清单为空时所有 productCodes 为空数组。
        只输出 JSON，不要任何解释文字，格式：
        {"schemeName":"...","categories":[{"name":"吃","productCodes":[]},{"name":"零食","parent":"吃","productCodes":["..."]}]}
        """

        let raw = try await complete(prompt: prompt)
        return try parseDraft(raw, validCodes: Set(products.map(\.code)))
    }

    /// AI 归类（作用于**既有方案**）：把选定商品归入方案的固定分类集合，不起草新框架。
    /// 与 generateDraft 是两个不同动作 —— 起草=建框架（全店视角）；归类=往框架里放商品（可选范围）。
    /// 返回 分类名 → 商品 code 列表；模型认为归不进任何分类的商品会缺席（= 保持原状）。
    public static func assignProducts(schemeName: String, storeName: String? = nil,
                                      categories: [String], products: [MerchantProduct],
                                      note: String? = nil) async throws -> [String: [String]] {
        let store = storeName.map { "「\($0)」" } ?? ""
        let catList = categories.map { "「\($0)」" }.joined(separator: "、")
        let productLines = products.map { p in
            let price = p.price.map { "¥\($0)" } ?? "-"
            return "\(p.code)|\(p.name)|\(price)"
        }.joined(separator: "\n")
        let extra = (note?.isEmpty == false) ? "\n商家补充的归类规则（优先遵守）：\(note!)\n" : ""
        let prompt = """
        你是电商商品分类专家。店铺\(store)的分类方案「\(schemeName)」有固定分类：\(catList)。
        请把下面的商品逐一归入上述分类（**不要新建分类**）。

        \(AIPrompts.classificationRules)

        本路径补充：名称含「/」的是二级分类（父/子），输出时整体原样照用；
        归不进任何分类的商品不要出现在输出里。
        \(extra)
        商品清单（每行：code|名称|价格；只允许引用清单中的 code，绝不编造）：
        \(productLines)

        只输出 JSON，不要任何解释文字，格式：
        {"categories":[{"name":"...","productCodes":["...","..."]}]}
        """

        let raw = try await complete(prompt: prompt)
        return try parseAssignments(raw, validCategories: Set(categories),
                                    validCodes: Set(products.map(\.code)))
    }

    // MARK: - 单次调用
    //
    // 经 ProviderRouter 拿 provider：自动带上重试与降级（首选来源限流/维护时
    // 切到下一个），失败原因也统一成人话。旧实现在这里自己写了一套
    // endpoint 解析 + SSE 解析 + 错误处理，与对话链路完全平行。

    private static func complete(prompt: String) async throws -> String {
        let runtime = AIRuntime.shared
        await runtime.bootstrap()
        guard runtime.isReady else {
            throw ClassifyError.serviceUnavailable
        }
        guard let entry = await runtime.config.resolveEntry(binding: nil) else {
            throw ClassifyError.notConfigured
        }
        let factory = ProviderFactory(config: runtime.config)
        do {
            let provider = try await factory.make(entry: entry)
            // 分类是一次性结构化输出，用满额度让它别把 JSON 写一半就截断
            return try await provider.completeText(
                messages: [.user(prompt)],
                maxTokens: entry.maxOutputTokens
            )
        } catch let error as LLMError {
            switch error {
            case .notConfigured:                 throw ClassifyError.notConfigured
            case .systemProviderUnavailable,
                 .transientError, .rateLimited:  throw ClassifyError.serviceUnavailable
            default:
                throw ClassifyError.badResponse(error.errorDescription ?? "调用失败")
            }
        }
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
