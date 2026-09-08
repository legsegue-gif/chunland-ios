import Foundation

// MARK: - 代购域 + 商家域工具
//
// 两域都只对各自身份可用（`AIToolName.allowedIdentities` 门控，下发+执行两道），
// 服务端另有 `requireRole` 双保险。

@MainActor
enum AgentBusinessTools {

    static var specs: [AgentToolSpec] { agentSpecs + merchantSpecs }

    // MARK: - 代购域

    private static var agentSpecs: [AgentToolSpec] { [

        AgentToolSpec(
            name: .listMyClaims,
            definition: .make(.listMyClaims,
                "查看我（代购人）的接单进度：待办分组计数 + 接单列表（订单号、状态、金额）。"
                + "可选 status 只看某一状态。**每次重新调用获取最新状态，禁止复用历史结果。**",
                params: [("status", .string("可选。只看某状态的接单",
                    values: ["CLAIMED", "PAID", "PURCHASING", "DELIVERING", "DELIVERED"]))]),
            kind: .readOnly,
            remote: true,
            // 工具体在服务端（R5）。`run` 不可达 —— 注册表见 remote=true 就直接打端点。
            run: { _, _ in "内部错误：list_my_claims 的工具体在服务端，不应走本地执行。" }
        ),

        AgentToolSpec(
            name: .buildPurchaseList,
            definition: .make(.buildPurchaseList,
                "整理合并采购清单：把我待采购/采购中的订单按商家分组、同商品跨单聚合数量，"
                + "并标注各单小票凭证状态。进店采购前调用。**每次重新调用获取最新数据。**"),
            kind: .readOnly,
            remote: true,
            // 工具体在服务端（R5）。`run` 不可达 —— 注册表见 remote=true 就直接打端点。
            run: { _, _ in "内部错误：build_purchase_list 的工具体在服务端，不应走本地执行。" }
        ),

        AgentToolSpec(
            name: .summarizeSettlements,
            definition: .make(.summarizeSettlements,
                "查看我（代购人）的结算收益：待结算/已结算总额 + 最近结算明细"
                + "（每单的货款返还、代购费、平台费）。问及收入/结算/某单赚多少时调用。"
                + "**每次重新调用获取最新数据。**"),
            kind: .readOnly,
            remote: true,
            // 工具体在服务端（R5）。`run` 不可达 —— 注册表见 remote=true 就直接打端点。
            run: { _, _ in "内部错误：summarize_settlements 的工具体在服务端，不应走本地执行。" }
        ),

        AgentToolSpec(
            name: .proposeAdjustment,
            definition: .make(.proposeAdjustment,
                "缺货改单：对采购中的某个订单商品发起「缺货移除」或「减量」，提交后由买家确认。"
                + "order_id/order_item_id 先用 get_order_detail 查到。MVP 只支持下调，不能加价加量。",
                params: [
                    ("order_id",      .integer("订单的数字 id")),
                    ("order_item_id", .integer("订单内商品条目的数字 id（get_order_detail 可查）")),
                    ("action",        .string("remove=缺货整项移除；reduce_qty=按缺货数量下调",
                        values: ["remove", "reduce_qty"])),
                    ("new_quantity",  .integer("action=reduce_qty 时必填：下调后的数量（须小于原数量）")),
                    ("note",          .string("给买家看的说明（可选），如「到店只剩 1 件」")),
                ],
                required: ["order_id", "order_item_id", "action"]),
            kind: .mutation,
            remote: true,
            intentSummary: { args in
                let itemId = args.int("order_item_id") ?? 0
                let what = args.string("action") == "remove"
                    ? "缺货移除商品条目 #\(itemId)"
                    : "商品条目 #\(itemId) 数量下调为 \(args.int("new_quantity") ?? 0)"
                return "对订单 #\(args.int("order_id") ?? 0) 发起缺货改单：\(what)（提交后需买家确认）"
            },
            // 工具体在服务端（R5）。`run` 不可达 —— 注册表见 remote=true 就直接打端点。
            run: { _, _ in "内部错误：propose_adjustment 的工具体在服务端，不应走本地执行。" }
        ),
    ] }

    // MARK: - 商家域
    //
    // AI 只在编辑期参与：生成建议 → 确认弹窗 → 普通 REST 落库；
    // 消费者浏览读的是 DB，与 AI 无关。

    private static var merchantSpecs: [AgentToolSpec] { [

        AgentToolSpec(
            name: .listStoreProducts,
            definition: .make(.listStoreProducts,
                "读取我店铺的全部商品（code、名称、价格、上架状态）。"
                + "做分类归类前必须先调用它拿到商品清单。**每次重新调用获取最新数据。**"),
            kind: .readOnly,
            remote: true,
            // 工具体在服务端（R5）。`run` 不可达 —— 注册表见 remote=true 就直接打端点。
            run: { _, _ in "内部错误：list_store_products 的工具体在服务端，不应走本地执行。" }
        ),

        AgentToolSpec(
            name: .listCategorySchemes,
            definition: .make(.listCategorySchemes,
                "查看我店铺现有的分类方案（方案 → 分类 → 各分类商品数，含分类的数字 id）。"
                + "归类商品前先调用它拿 category_id。**每次重新调用获取最新数据。**"),
            kind: .readOnly,
            remote: true,
            // 工具体在服务端（R5）。`run` 不可达 —— 注册表见 remote=true 就直接打端点。
            run: { _, _ in "内部错误：list_category_schemes 的工具体在服务端，不应走本地执行。" }
        ),

        AgentToolSpec(
            name: .createCategoryScheme,
            definition: .make(.createCategoryScheme,
                "创建一个分类方案及其分类（最多两级）。categories 两种格式任选："
                + "①平铺逗号分隔「吃,穿,住」；②两级用 JSON 数组，如 "
                + "[{\"name\":\"吃\",\"children\":[\"零食\",\"生鲜\"]},{\"name\":\"穿\"}]。"
                + "创建后用 list_category_schemes 拿各分类的 category_id，"
                + "再用 assign_category_products 归类商品（一级/二级均可归类；"
                + "买家选一级自动含其二级商品）。",
                params: [
                    ("name",       .string("方案名，如「吃穿住行用」")),
                    ("categories", .string("分类列表：逗号分隔或两级 JSON 数组")),
                ],
                required: ["name", "categories"]),
            kind: .mutation,
            remote: true,
            intentSummary: { args in
                // 摘要要给人读 —— 原样回显 JSON 等于让用户在确认框里读代码。
                // 参数原文仍在 details 里（确认框的安全语义是「看到什么就执行什么」）。
                let raw = args.string("categories") ?? ""
                let desc = AgentSchemeInput.parse(raw)?.map { draft in
                    draft.children.isEmpty
                        ? draft.name
                        : "\(draft.name)（含 \(draft.children.joined(separator: "/"))）"
                }.joined(separator: "、") ?? raw
                return "创建分类方案「\(args.string("name") ?? "")」，包含分类：\(desc)"
            },
            // 工具体在服务端（R5）。`run` 不可达 —— 注册表见 remote=true 就直接打端点。
            run: { _, _ in "内部错误：create_category_scheme 的工具体在服务端，不应走本地执行。" }
        ),

        AgentToolSpec(
            name: .assignCategoryProducts,
            definition: .make(.assignCategoryProducts,
                "把商品归入某个分类（**整体替换**语义：给该分类的全量商品 code，"
                + "没列出的会被移出该分类）。每个分类调用一次。"
                + "category_id 来自 list_category_schemes。",
                params: [
                    ("category_id",   .integer("分类的数字 id")),
                    ("product_codes", .string("该分类的全量商品 code，逗号分隔")),
                ],
                required: ["category_id", "product_codes"]),
            kind: .mutation,
            remote: true,
            intentSummary: { args in
                let codes = (args.string("product_codes") ?? "")
                    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                return "归类到分类 #\(args.int("category_id") ?? 0)：共 \(codes.count) 件商品（整体替换）"
            },
            // 工具体在服务端（R5）。`run` 不可达 —— 注册表见 remote=true 就直接打端点。
            run: { _, _ in "内部错误：assign_category_products 的工具体在服务端，不应走本地执行。" }
        ),
    ] }
}

// MARK: - 分类输入解析
//
// 模型给分类列表有两种写法，都要吃：
//   平铺：「吃,穿,住」
//   两级：[{"name":"吃","children":["零食","生鲜"]},{"name":"穿"}]
// 强制它只用一种会平白增加出错面 —— 解析成本远低于让模型反复试。

enum AgentSchemeInput {

    struct Draft {
        let name: String
        let children: [String]
    }

    static func parse(_ raw: String) -> [Draft]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("["),
           let data = trimmed.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            var out: [Draft] = []
            for item in array {
                if let name = (item as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                    out.append(Draft(name: name, children: []))
                } else if let obj = item as? [String: Any],
                          let name = (obj["name"] as? String)?.trimmingCharacters(in: .whitespaces),
                          !name.isEmpty {
                    let children = ((obj["children"] as? [Any]) ?? [])
                        .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    out.append(Draft(name: name, children: children))
                }
            }
            return out.isEmpty ? nil : out
        }

        // 中英文逗号都认 —— 中文输入法下模型常打出「，」
        let flat = trimmed.split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return flat.isEmpty ? nil : flat.map { Draft(name: $0, children: []) }
    }

    static func codes(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
