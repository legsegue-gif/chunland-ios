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
            run: { args, _ in
                let status = args.string("status")
                async let dashboardTask = AgentProfileService.shared.dashboard()
                async let ordersTask = OrderService.shared.list(status: status, scope: "mine")
                let (d, orders) = try await (dashboardTask, ordersTask)

                var out = "待办概览：待买家支付 \(d.counts.claimed)｜待采购 \(d.counts.paid)"
                    + "｜采购中 \(d.counts.purchasing)（缺小票 \(d.counts.purchasingNoReceipt)、"
                    + "改单待答复 \(d.counts.purchasingPendingAdjustment)）"
                    + "｜配送中 \(d.counts.delivering)｜待买家确认 \(d.counts.delivered)"

                if orders.isEmpty {
                    out += status != nil ? "\n该状态下暂无订单。" : "\n还没有接过单。"
                } else {
                    let lines = orders.prefix(20).map {
                        "#\($0.orderNumber)（id:\($0.id)）｜\(OrderStatusText.agent($0.status))｜¥\($0.totalAmount)"
                    }
                    out += "\n接单列表（共 \(orders.count) 笔）：\n" + lines.joined(separator: "\n")
                        + "\n（某单详情用 get_order_detail，order_id 传上面的 id）"
                }
                return out
            }
        ),

        AgentToolSpec(
            name: .buildPurchaseList,
            definition: .make(.buildPurchaseList,
                "整理合并采购清单：把我待采购/采购中的订单按商家分组、同商品跨单聚合数量，"
                + "并标注各单小票凭证状态。进店采购前调用。**每次重新调用获取最新数据。**"),
            kind: .readOnly,
            run: { _, _ in
                let list = try await AgentProfileService.shared.purchaseList()
                guard !list.groups.isEmpty else {
                    return "当前没有待采购的订单（待采购/采购中状态才会进清单）。"
                }
                let sections = list.groups.map { g -> String in
                    let items = g.items.map { item -> String in
                        let size = item.selectedSize.map { "（尺码 \($0)）" } ?? ""
                        let from = item.breakdown
                            .map { "…\($0.orderNumber.suffix(6)) ×\($0.quantity)" }
                            .joined(separator: "、")
                        return "· \(item.name)\(size) ×\(item.totalQuantity)（来自 \(from)）"
                    }.joined(separator: "\n")
                    let receipts = g.orders.map {
                        "…\($0.orderNumber.suffix(6))（id:\($0.id)）\($0.hasReceipt ? "已传小票" : "待传小票")"
                    }.joined(separator: "、")
                    return "【\(g.merchantName)】\(g.orders.count) 单 \(g.items.count) 种商品\n"
                        + "\(items)\n小票状态：\(receipts)"
                }
                return sections.joined(separator: "\n\n")
            }
        ),

        AgentToolSpec(
            name: .summarizeSettlements,
            definition: .make(.summarizeSettlements,
                "查看我（代购人）的结算收益：待结算/已结算总额 + 最近结算明细"
                + "（每单的货款返还、代购费、平台费）。问及收入/结算/某单赚多少时调用。"
                + "**每次重新调用获取最新数据。**"),
            kind: .readOnly,
            run: { _, _ in
                let s = try await SettlementService.shared.mine()
                var out = "待结算 ¥\(s.pendingTotal)｜已结算 ¥\(s.paidTotal)"
                if s.items.isEmpty {
                    out += "\n还没有结算记录（订单完成后自动记账）。"
                } else {
                    let lines = s.items.prefix(15).map {
                        "#\($0.orderNumber)｜应结 ¥\($0.netPayable)"
                            + "（货款 ¥\($0.itemsReimburse) + 代购费 ¥\($0.agentFee)）"
                            + "｜\(OrderStatusText.settlement($0.status))"
                    }
                    out += "\n最近结算（共 \(s.items.count) 笔）：\n" + lines.joined(separator: "\n")
                }
                return out
            }
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
            intentSummary: { args in
                let itemId = args.int("order_item_id") ?? 0
                let what = args.string("action") == "remove"
                    ? "缺货移除商品条目 #\(itemId)"
                    : "商品条目 #\(itemId) 数量下调为 \(args.int("new_quantity") ?? 0)"
                return "对订单 #\(args.int("order_id") ?? 0) 发起缺货改单：\(what)（提交后需买家确认）"
            },
            run: { args, _ in
                guard let orderId = args.int("order_id"),
                      let itemId = args.int("order_item_id"),
                      let action = args.string("action"),
                      ["remove", "reduce_qty"].contains(action) else {
                    return "参数不全：需要 order_id、order_item_id 和 action（remove/reduce_qty）。"
                        + "可先用 get_order_detail 查条目 id。"
                }
                let newQuantity = args.int("new_quantity")
                if action == "reduce_qty" && newQuantity == nil {
                    return "action=reduce_qty 时必须提供 new_quantity（下调后的数量）。"
                }
                let item = AdjustmentItem(orderItemId: itemId, action: action, newQuantity: newQuantity)
                let adj = try await AdjustmentService.shared.propose(
                    orderId: orderId,
                    kind: "out_of_stock",
                    detail: AdjustmentDetail(items: [item]),
                    note: args.string("note")
                )
                return "改单已提交（金额变化 ¥\(adj.amountDelta)），等待买家确认。"
                    + "买家接受后差额自动部分退款。"
            }
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

        AgentToolSpec(
            name: .listCategorySchemes,
            definition: .make(.listCategorySchemes,
                "查看我店铺现有的分类方案（方案 → 分类 → 各分类商品数，含分类的数字 id）。"
                + "归类商品前先调用它拿 category_id。**每次重新调用获取最新数据。**"),
            kind: .readOnly,
            run: { _, _ in
                let schemes = try await MerchantConsoleService.shared.schemes()
                guard !schemes.isEmpty else {
                    return "还没有分类方案。可用 create_category_scheme 创建（如「吃穿住行用」）。"
                }
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
            run: { args, _ in
                let name = args.string("name") ?? ""
                guard !name.isEmpty else { return "缺少方案名。" }
                guard let drafts = AgentSchemeInput.parse(args.string("categories") ?? "") else {
                    return "缺少分类列表（逗号分隔或 JSON 数组）。"
                }
                // origin=ai 记方案来源，供 AI 分类溯源（与归类的 assignedBy 同一条线）
                let scheme = try await MerchantConsoleService.shared.createScheme(name: name, origin: "ai")
                for draft in drafts {
                    let parentId = try await MerchantConsoleService.shared
                        .addSchemeCategory(schemeId: scheme.id, name: draft.name)
                    for child in draft.children {
                        try await MerchantConsoleService.shared
                            .addSchemeCategory(schemeId: scheme.id, name: child, parentId: parentId)
                    }
                }
                // 回读一次拿 category_id —— 归类要用它，不回读模型就得再调一次 list
                let fresh = try await MerchantConsoleService.shared.schemes()
                    .first { $0.id == scheme.id }
                let catList = (fresh?.categories ?? []).map { c -> String in
                    let subs = c.subcategories.map { "\($0.name)（category_id:\($0.id)）" }
                    return "\(c.name)（category_id:\(c.id)"
                        + (subs.isEmpty ? "" : "，子分类：" + subs.joined(separator: "、")) + "）"
                }
                return "方案「\(name)」已创建。分类：\(catList.joined(separator: "、"))。"
                    + "接下来可用 assign_category_products 把商品归入各分类"
                    + "（每个分类调用一次、给全量 code）。"
            }
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
            intentSummary: { args in
                let codes = (args.string("product_codes") ?? "")
                    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                return "归类到分类 #\(args.int("category_id") ?? 0)：共 \(codes.count) 件商品（整体替换）"
            },
            run: { args, _ in
                guard let categoryId = args.int("category_id") else {
                    return "需要 category_id（分类的数字 id），可用 list_category_schemes 查。"
                }
                let codes = AgentSchemeInput.codes(args.string("product_codes") ?? "")
                try await MerchantConsoleService.shared
                    .setSchemeCategoryProducts(id: categoryId, codes: codes, assignedBy: "ai")
                return "已把 \(codes.count) 件商品归入分类 #\(categoryId)（整体替换）。"
            }
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
