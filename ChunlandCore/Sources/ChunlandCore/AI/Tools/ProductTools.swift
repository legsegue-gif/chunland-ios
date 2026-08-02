import Foundation

// 商品域 AI 工具：搜索 / 详情 / 分类。全只读，直接执行。
// 搜索与分类感知 AIToolScope：进店上下文（scope.merchantId 非空）时硬限定到该店 ——
// 「本店搜索/本店分类」由代码兑现，不靠 seedNote 许愿（否则模型会把全局数据当本店数据）。
@MainActor
enum ProductTools {
    static let specs: [AIToolSpec] = [
        AIToolSpec(
            name: .searchProducts,
            tool: AITool(function: AIFunction(
                name: AIToolName.searchProducts.rawValue,
                description: "搜索商品列表，支持关键词和分类筛选（店铺上下文中自动限定在当前店铺内）",
                parameters: AIParameters(
                    properties: [
                        "query":    AIProperty(type: "string",  description: "搜索关键词，如\"牛排\"\"咖啡\""),
                        "category": AIProperty(type: "string",  description: "分类代码，如 CN141401"),
                        "limit":    AIProperty(type: "integer", description: "返回数量，默认10，最多20"),
                    ],
                    required: []
                )
            )),
            kind: .readOnly,
            run: { args, scope in
                let query    = args["query"] as? String
                let category = args["category"] as? String
                let limit    = args["limit"] as? Int ?? 10
                let resp = try await ProductService.shared.list(merchant: scope.merchantId,
                                                                category: category,
                                                                keyword: query,
                                                                limit: limit)
                let where_ = scope.merchantName.map { "在「\($0)」店内" } ?? ""
                if resp.items.isEmpty {
                    return "\(where_)没有找到匹配的商品。"
                }
                let summary = resp.items.prefix(limit).map {
                    "[\($0.code)] \($0.name) ¥\($0.currentPrice?.description ?? "?") \($0.isInStock ? "有货" : "缺货")"
                }.joined(separator: "\n")
                return "\(where_)找到 \(resp.pagination.total) 个商品（展示前 \(resp.items.prefix(limit).count) 个）：\n\(summary)"
            }
        ),

        AIToolSpec(
            name: .getProductDetail,
            tool: AITool(function: AIFunction(
                name: AIToolName.getProductDetail.rawValue,
                description: "获取指定商品的详细信息（价格、库存、图片等）",
                parameters: AIParameters(
                    properties: ["code": AIProperty(type: "string", description: "商品代码，如 123456")],
                    required: ["code"]
                )
            )),
            kind: .readOnly,
            run: { args, _ in
                let code = args["code"] as? String ?? ""
                let p = try await ProductService.shared.detail(code: code)
                return """
                商品：\(p.name)
                价格：¥\(p.currentPrice?.description ?? "未知")
                库存：\(p.stockStatus ?? "未知")
                单位：\(p.unitType ?? "-")
                随机重量：\(p.randomWeight ? "是（按实重计价）" : "否")
                """
            }
        ),

        AIToolSpec(
            name: .getCategories,
            tool: AITool(function: AIFunction(
                name: AIToolName.getCategories.rawValue,
                description: "获取商品分类，用于了解有哪些品类（店铺上下文中返回当前店铺自己的分类）",
                parameters: AIParameters(properties: [:], required: [])
            )),
            kind: .readOnly,
            run: { _, scope in
                let cats = try await CategoryService.shared.tree(merchant: scope.merchantId)
                // 进店：返回该店自有分类；店铺没有分类导航时如实说，绝不回落全局树冒充本店分类
                if scope.merchantId != nil {
                    let label = scope.merchantName.map { "「\($0)」" } ?? "该店铺"
                    guard !cats.isEmpty else {
                        return "\(label)没有分类导航，可用 search_products 直接搜索店内商品。"
                    }
                    return "\(label)的分类：" + cats.prefix(15)
                        .map { "\($0.name)（\($0.code)）" }.joined(separator: "、")
                }
                let top = cats.filter { $0.level == 1 }.prefix(10)
                return top.map { "\($0.name)（\($0.code)）" }.joined(separator: "、")
            }
        ),
    ]
}
