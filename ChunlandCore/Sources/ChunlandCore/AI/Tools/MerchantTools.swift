import Foundation

// 商家域 AI 工具（AI 分类路线 A）：读店铺商品/方案（只读）+ 建方案/归类（mutation，走 HITL）。
// AI 只在编辑期参与：生成建议 → 确认弹窗 → 普通 REST 落库；消费者浏览读的是 DB，与 AI 无关。
// 仅商家身份可用（AIToolName.allowedIdentities 门控：下发+执行两道），服务端 requireRole('merchant') 双保险。
@MainActor
enum MerchantTools {
    static let specs: [AIToolSpec] = [
        AIToolSpec(
            name: .listStoreProducts,
            tool: AITool(function: AIFunction(
                name: AIToolName.listStoreProducts.rawValue,
                description: "读取我店铺的全部商品（code、名称、价格、上架状态）。做分类归类前必须先调用它拿到商品清单。**每次重新调用获取最新数据。**",
                parameters: AIParameters(properties: [:], required: [])
            )),
            kind: .readOnly,
            run: { _, _ in
                let products = try await MerchantConsoleService.shared.products()
                if products.isEmpty { return "店里还没有商品。" }
                let lines = products.map { p -> String in
                    let price = p.price.map { "¥\($0)" } ?? "-"
                    return "\(p.code)｜\(p.name)｜\(price)｜\(p.purchasable ? "在售" : "已下架")"
                }
                return "店铺商品（共 \(products.count) 件）：\n" + lines.joined(separator: "\n")
            }
        ),

        AIToolSpec(
            name: .listCategorySchemes,
            tool: AITool(function: AIFunction(
                name: AIToolName.listCategorySchemes.rawValue,
                description: "查看我店铺现有的分类方案（方案 → 分类 → 各分类商品数，含分类的数字 id）。归类商品前先调用它拿 category_id。**每次重新调用获取最新数据。**",
                parameters: AIParameters(properties: [:], required: [])
            )),
            kind: .readOnly,
            run: { _, _ in
                let schemes = try await MerchantConsoleService.shared.schemes()
                if schemes.isEmpty { return "还没有分类方案。可用 create_category_scheme 创建（如「吃穿住行用」）。" }
                let sections = schemes.map { s -> String in
                    let cats = s.categories.flatMap { c -> [String] in
                        var lines = ["  - \(c.name)（category_id:\(c.id)，\(c.productCount ?? 0) 件）"]
                        lines += c.subcategories.map {
                            "    · \($0.name)（category_id:\($0.id)，\($0.productCount ?? 0) 件，二级，属「\(c.name)」）"
                        }
                        return lines
                    }
                    let flags = [s.isDefault ? "默认" : nil, s.isVisible == false ? "已隐藏" : nil]
                        .compactMap { $0 }.joined(separator: "、")
                    return "【\(s.name)】\(flags.isEmpty ? "" : "（\(flags)）")\n"
                        + (cats.isEmpty ? "  （还没有分类）" : cats.joined(separator: "\n"))
                }
                return sections.joined(separator: "\n")
            }
        ),

        AIToolSpec(
            name: .createCategoryScheme,
            tool: AITool(function: AIFunction(
                name: AIToolName.createCategoryScheme.rawValue,
                description: "创建一个分类方案及其分类（最多两级）。categories 两种格式任选：①平铺逗号分隔「吃,穿,住」；②两级用 JSON 数组，如 [{\"name\":\"吃\",\"children\":[\"零食\",\"生鲜\"]},{\"name\":\"穿\"}]。创建后用 list_category_schemes 拿各分类的 category_id，再用 assign_category_products 归类商品（一级/二级均可归类；买家选一级自动含其二级商品）。",
                parameters: AIParameters(
                    properties: [
                        "name":       AIProperty(type: "string", description: "方案名（≤20 字），如「吃穿住行用」"),
                        "categories": AIProperty(type: "string", description: "分类列表：逗号分隔平铺，或 JSON 数组表达两级（每个名 ≤20 字，两级合计最多 30 个）"),
                    ],
                    required: ["name", "categories"]
                )
            )),
            kind: .mutation,
            intentSummary: { args in
                let name = args["name"] as? String ?? ""
                let raw = args["categories"] as? String ?? ""
                let desc = parseSchemeCatDrafts(raw).map { drafts in
                    drafts.map { $0.children.isEmpty ? $0.name : "\($0.name)（含 \($0.children.joined(separator: "/"))）" }
                        .joined(separator: "、")
                } ?? raw
                return "AI 想创建分类方案「\(name)」，包含分类：\(desc)"
            },
            run: { args, _ in
                guard let name = args["name"] as? String, !name.isEmpty else { return "缺少方案名。" }
                guard let drafts = parseSchemeCatDrafts(args["categories"] as? String ?? "") else {
                    return "缺少分类列表（逗号分隔或 JSON 数组）。"
                }
                let scheme = try await MerchantConsoleService.shared.createScheme(name: name)
                for d in drafts {
                    let pid = try await MerchantConsoleService.shared.addSchemeCategory(schemeId: scheme.id, name: d.name)
                    for child in d.children {
                        try await MerchantConsoleService.shared.addSchemeCategory(schemeId: scheme.id, name: child, parentId: pid)
                    }
                }
                let fresh = try await MerchantConsoleService.shared.schemes()
                    .first { $0.id == scheme.id }
                let catList = (fresh?.categories ?? []).map { c -> String in
                    let subs = c.subcategories.map { "\($0.name)（category_id:\($0.id)）" }
                    return "\(c.name)（category_id:\(c.id)\(subs.isEmpty ? "" : "，子分类：" + subs.joined(separator: "、"))）"
                }
                return "方案「\(name)」已创建。分类：\(catList.joined(separator: "、"))。"
                    + "接下来可用 assign_category_products 把商品归入各分类（每个分类调用一次、给全量 code）。"
            }
        ),

        AIToolSpec(
            name: .assignCategoryProducts,
            tool: AITool(function: AIFunction(
                name: AIToolName.assignCategoryProducts.rawValue,
                description: "把商品归入某个方案分类（**整体替换**该分类下的商品，一次给全量）。category_id 来自 list_category_schemes；product_codes 来自 list_store_products。每个分类调用一次。",
                parameters: AIParameters(
                    properties: [
                        "category_id":   AIProperty(type: "integer", description: "分类的数字 id"),
                        "product_codes": AIProperty(type: "string", description: "商品 code 列表，逗号分隔（该分类的全量商品）"),
                    ],
                    required: ["category_id", "product_codes"]
                )
            )),
            kind: .mutation,
            intentSummary: { args in
                let codes = ((args["product_codes"] as? String) ?? "").split(separator: ",").count
                return "AI 想把 \(codes) 个商品归入分类 #\(merchantIntArg(args, "category_id") ?? 0)（整体替换该分类）"
            },
            run: { args, _ in
                guard let catId = merchantIntArg(args, "category_id") else { return "缺少 category_id（先用 list_category_schemes 查）。" }
                let codes = ((args["product_codes"] as? String) ?? "")
                    .split(whereSeparator: { $0 == "," || $0 == "，" })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                try await MerchantConsoleService.shared.setSchemeCategoryProducts(id: catId, codes: codes)
                return "已把 \(codes.count) 个商品归入分类 #\(catId)。"
            }
        ),
    ]
}

private func merchantIntArg(_ args: [String: Any], _ key: String) -> Int? {
    (args[key] as? Int) ?? Int((args[key] as? String) ?? "")
}

// create_category_scheme 的 categories 参数解析：JSON 数组（两级）优先，逗号分隔平铺兜底（旧契约兼容）。
// JSON 元素可以是字符串（一级）或 {name, children:[String]}（一级+二级）。
struct SchemeCatDraft {
    let name: String
    let children: [String]
}

func parseSchemeCatDrafts(_ raw: String) -> [SchemeCatDraft]? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("["), let data = trimmed.data(using: .utf8),
       let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
        var out: [SchemeCatDraft] = []
        for item in arr {
            if let s = item as? String {
                let n = s.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { out.append(SchemeCatDraft(name: n, children: [])) }
            } else if let obj = item as? [String: Any],
                      let n = (obj["name"] as? String)?.trimmingCharacters(in: .whitespaces), !n.isEmpty {
                let children = ((obj["children"] as? [Any]) ?? [])
                    .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                out.append(SchemeCatDraft(name: n, children: children))
            }
        }
        return out.isEmpty ? nil : out
    }
    let flat = trimmed.split(whereSeparator: { $0 == "," || $0 == "，" })
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    return flat.isEmpty ? nil : flat.map { SchemeCatDraft(name: $0, children: []) }
}
