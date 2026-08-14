import Foundation

// MARK: - 买家域工具：商品 / 购物车 / 订单
//
// 全部只属买家身份（`AIToolName.allowedIdentities` 门控，下发+执行两道），
// 唯一例外是 `get_order_detail`（代购人跟进接单同样需要，服务端按参与方鉴权）。
//
// 搜索与分类感知 `AIToolScope`：进店上下文时硬限定到该店 ——
// 「本店搜索」由代码兑现，不靠提示词许愿（否则模型会把全局数据当本店数据）。

@MainActor
enum AgentShoppingTools {

    static var specs: [AgentToolSpec] { productSpecs + cartSpecs + orderSpecs }

    // MARK: - 商品

    private static var productSpecs: [AgentToolSpec] { [

        AgentToolSpec(
            name: .searchProducts,
            definition: .make(.searchProducts,
                "搜索商品。支持关键词、分类、价格区间、只看有货、排序 —— "
                + "一次问对比翻页筛选高效得多（如「100 元以内、有货、按价格从低到高」）。"
                + "店铺上下文中自动限定在当前店铺内。",
                params: [
                    ("query",     .string("搜索关键词，如「牛排」「咖啡」")),
                    ("category",  .string("分类代码，来自 get_categories")),
                    ("price_min", .number("最低价（元）")),
                    ("price_max", .number("最高价（元）")),
                    ("in_stock",  .boolean("只看有货的，默认 false")),
                    ("sort",      .string("排序方式",
                        values: ["relevance", "price_asc", "price_desc", "discount", "newest"])),
                    ("limit",     .integer("返回数量，默认 10，最多 20")),
                ]),
            kind: .readOnly,
            run: { args, scope in
                let limit = min(20, args.int("limit") ?? 10)
                let resp = try await ProductService.shared.list(
                    merchant: scope.merchantId,
                    category: args.string("category"),
                    keyword: args.string("query"),
                    limit: limit,
                    priceMin: args.double("price_min"),
                    priceMax: args.double("price_max"),
                    inStockOnly: args.bool("in_stock") ?? false,
                    sort: args.string("sort").flatMap(ProductSort.init(rawValue:)),
                    // 精简字段：一次 20 条，完整字段会吃掉大量上下文，
                    // 而挑商品只需要「叫什么、多少钱、有没有货」
                    compact: true,
                    withStats: true
                )
                let place = scope.merchantName.map { "在「\($0)」店内" } ?? ""
                guard !resp.items.isEmpty else {
                    return "\(place)没有找到匹配的商品。可以放宽条件再试（比如去掉价格限制或换个关键词）。"
                }
                let lines = resp.items.prefix(limit).map {
                    "[\($0.code)] \($0.name) ¥\($0.currentPrice?.description ?? "?") \($0.isInStock ? "有货" : "缺货")"
                }
                var out = "\(place)找到 \(resp.pagination.total) 个商品（展示前 \(resp.items.prefix(limit).count) 个）：\n"
                    + lines.joined(separator: "\n")
                // 价格分布让模型能判断「这个价位算便宜还是贵」，省一轮试探
                if let stats = resp.stats, resp.pagination.total > limit {
                    out += "\n（符合条件的商品价格 ¥\(stats.minPrice ?? 0)–¥\(stats.maxPrice ?? 0)，"
                        + "其中 \(stats.inStockCount) 件有货）"
                }
                return out
            }
        ),

        AgentToolSpec(
            name: .getProductDetail,
            definition: .make(.getProductDetail,
                "获取指定商品的详细信息（价格、库存、规格）",
                params: [("code", .string("商品代码，如 123456"))],
                required: ["code"]),
            kind: .readOnly,
            run: { args, _ in
                let p = try await ProductService.shared.detail(code: args.string("code") ?? "")
                return """
                商品：\(p.name)
                价格：¥\(p.currentPrice?.description ?? "未知")
                库存：\(p.stockStatus ?? "未知")
                单位：\(p.unitType ?? "-")
                随机重量：\(p.randomWeight ? "是（按实重计价）" : "否")
                """
            }
        ),

        AgentToolSpec(
            name: .getCategories,
            definition: .make(.getCategories,
                "获取商品分类及各分类的在售商品数，用于了解有哪些品类"
                + "（店铺上下文中返回当前店铺自己的分类）"),
            kind: .readOnly,
            run: { _, scope in
                let cats = try await CategoryService.shared.tree(
                    merchant: scope.merchantId, withCounts: true
                )
                func label(_ c: Category) -> String {
                    let count = c.productCount.map { "，\($0) 件" } ?? ""
                    return "\(c.name)（\(c.code)\(count)）"
                }
                // 进店：返回该店自有分类；店铺没有分类导航时如实说，
                // 绝不回落全局树冒充本店分类
                if scope.merchantId != nil {
                    let place = scope.merchantName.map { "「\($0)」" } ?? "该店铺"
                    guard !cats.isEmpty else {
                        return "\(place)没有分类导航，可用 search_products 直接搜索店内商品。"
                    }
                    return "\(place)的分类：" + cats.prefix(15).map(label).joined(separator: "、")
                }
                let top = cats.filter { $0.level == 1 }.prefix(10)
                return top.map(label).joined(separator: "、")
            }
        ),
    ] }

    // MARK: - 购物车

    private static var cartSpecs: [AgentToolSpec] { [

        AgentToolSpec(
            name: .addToCart,
            definition: .make(.addToCart,
                "将指定商品加入购物车",
                params: [
                    ("product_code", .string("商品代码")),
                    ("quantity",     .integer("数量，默认 1")),
                ],
                required: ["product_code"]),
            kind: .mutation,
            intentSummary: { args in
                let code = args.string("product_code") ?? ""
                let qty = args.int("quantity") ?? 1
                return "加入购物车：商品 \(code) × \(qty)"
            },
            run: { args, _ in
                let code = args.string("product_code") ?? ""
                let qty = args.int("quantity") ?? 1
                try await CartService.shared.addItem(productCode: code, quantity: qty)
                return "已将商品 \(code) × \(qty) 加入购物车"
            }
        ),

        AgentToolSpec(
            name: .getCart,
            definition: .make(.getCart,
                "查看当前购物车内容和总价。**每次询问购物车都必须重新调用，"
                + "禁止复用历史结果**（用户可能在中间加/删了商品）。"),
            kind: .readOnly,
            run: { _, _ in
                let cart = try await CartService.shared.get()
                if cart.items.isEmpty { return "购物车是空的" }
                let lines = cart.items.map {
                    "\($0.name) × \($0.quantity)  ¥\($0.currentPrice?.description ?? "?")"
                }
                return "购物车（共 \(cart.items.count) 种商品）：\n"
                    + lines.joined(separator: "\n") + "\n合计：¥\(cart.itemsTotal)"
            }
        ),
    ] }

    // MARK: - 订单

    private static var orderSpecs: [AgentToolSpec] { [

        AgentToolSpec(
            name: .placeOrder,
            definition: .make(.placeOrder,
                "用购物车当前内容下单。收货地址自动使用用户地址簿的默认地址、"
                + "费用以服务端报价为准，两者都会在确认弹窗中展示给用户 —— "
                + "**不要向用户索要姓名/电话/地址，也不要自行报费用**。"
                + "用户没有地址时引导其到「我的 → 地址管理」添加；"
                + "想换地址时告知其到购物车结算页选择。",
                params: [("note", .string("配送备注（可选）"))]),
            kind: .mutation,
            // 执行期解析：地址取地址簿、费用取服务端报价（与结算页同一 quote 端点，
            // 含距离代购费与起送校验），确认弹窗展示并执行的都是这份快照。
            // 模型全程接触不到地址明细 —— 既堵住「让用户口述地址 → areaCode 丢失 →
            // 距离费静默为 0」的计费旁路，地址簿 PII 也不进模型上下文。
            prepare: { args, _ in
                let addresses = try await AddressService.shared.list()
                guard !addresses.isEmpty else {
                    return .abort("用户的地址簿还没有收货地址，无法下单。请引导用户到"
                        + "「我的 → 地址管理」添加收货地址后再试；不要让用户在对话里口述地址。")
                }
                let chosen = addresses.first { $0.isDefault } ?? addresses[0]
                let quote = try await OrderService.shared.quote(areaCode: chosen.areaCode)
                if let short = quote.groups.first(where: { !$0.meetsMinOrder }) {
                    return .abort("「\(short.merchantName)」商品小计 ¥\(short.itemsTotal) "
                        + "未达起送金额 ¥\(short.minOrderAmount)，无法下单。"
                        + "可建议用户补足该店商品，或从购物车移除该店商品后再下单。")
                }
                let delivery = DeliveryAddress(
                    name: chosen.name, phone: chosen.phone, address: chosen.address,
                    note: args.string("note"), areaCode: chosen.areaCode
                )
                var details: [String: String] = [
                    "收货": "\(chosen.name) \(chosen.phone)",
                    "地址": chosen.address,
                    "合计": "¥\(quote.grandTotal)",
                ]
                for group in quote.groups {
                    let key = quote.groups.count == 1 ? "费用" : group.merchantName
                    details[key] = "商品 ¥\(group.itemsTotal) + 平台费 ¥\(group.platformFee)"
                        + " + 代购费 ¥\(group.agentFee)"
                }
                let summary = quote.groups.count > 1
                    ? "用购物车内容下单（\(quote.groups.count) 个商家，分别成单）"
                    : "用购物车内容下单"

                return .ready(
                    intent: AgentMutationIntent(
                        id: UUID().uuidString,
                        toolName: AIToolName.placeOrder.rawValue,
                        summary: summary,
                        details: details
                    ),
                    execute: {
                        let batch = try await OrderService.shared.placeOrder(deliveryAddress: delivery)
                        let dest = "收货地址用的是用户确认过的地址簿地址"
                            + "（\(chosen.name)，\(chosen.address)）"
                        if batch.orderCount == 1, let only = batch.orders.first {
                            return "下单成功！订单号：\(only.orderNumber)，"
                                + "总金额：¥\(only.totalAmount)，等待代购人接单。\(dest)。"
                        }
                        return "下单成功！已按商家拆为 \(batch.orderCount) 笔订单，"
                            + "合计 ¥\(batch.grandTotal)，等待代购人接单。\(dest)。"
                    }
                )
            },
            run: { _, _ in
                // 不可达：place_order 恒经 prepare 的确认流程执行（管道优先走 prepare）
                "内部错误：place_order 只能经确认流程执行。"
            }
        ),

        AgentToolSpec(
            name: .listMyOrders,
            definition: .make(.listMyOrders,
                "查看「我的订单」列表（订单号、状态、金额）。问及订单进度/历史时调用。"
                + "**每次都重新调用获取最新状态，禁止复用历史结果。**"),
            kind: .readOnly,
            run: { _, _ in
                let orders = try await OrderService.shared.list()
                if orders.isEmpty { return "你还没有订单。" }
                let lines = orders.prefix(20).map { o -> String in
                    let count = o.itemCount.map { "\($0)件" } ?? ""
                    return "#\(o.orderNumber)（id:\(o.id)）｜\(OrderStatusText.consumer(o.status))"
                        + "｜¥\(o.totalAmount)｜\(count)"
                }
                return "你的订单（共 \(orders.count) 笔）：\n" + lines.joined(separator: "\n")
                    + "\n（需要某单详情时用 get_order_detail，order_id 传上面的 id）"
            }
        ),

        AgentToolSpec(
            name: .getOrderDetail,
            definition: .make(.getOrderDetail,
                "查看某一订单的详情（状态、金额构成、商品、收货信息、当前可执行的操作）。"
                + "order_id 来自 list_my_orders 的 id 或当前页面上下文。**每次重新调用获取最新状态。**",
                params: [("order_id", .integer("订单的数字 id"))],
                required: ["order_id"]),
            kind: .readOnly,
            run: { args, _ in
                guard let orderId = args.int("order_id") else {
                    return "请提供 order_id（订单的数字 id）。可先用 list_my_orders 查到 id。"
                }
                let o = try await OrderService.shared.detail(id: orderId)
                var out = """
                订单 #\(o.orderNumber)
                状态：\(OrderStatusText.consumer(o.status))
                合计：¥\(o.totalAmount)（商品 ¥\(o.itemsTotal) + 平台费 ¥\(o.platformFee) + 代购费 ¥\(o.agentFee)）
                商品：\(o.items.map { "\($0.productSnapshot.name) × \($0.quantity)" }.joined(separator: "、"))
                收货：\(o.deliveryAddress.name) \(o.deliveryAddress.address)
                下单时间：\(o.createdAt)
                """
                if let actions = o.availableActions, !actions.isEmpty {
                    out += "\n你现在可以：\(actions.map(\.label).joined(separator: "、"))"
                }
                return out
            }
        ),
    ] }
}

// MARK: - 状态文案
//
// 状态码直接给模型会让它照抄英文大写词（「你的订单现在是 PURCHASING」）。
// 这里统一成中文，且**买家与代购人两套措辞** —— 同一个状态在两边的含义不同：
// PAID 对买家是「已支付」，对代购人是「待采购」。

enum OrderStatusText {

    static func consumer(_ status: String) -> String {
        switch status.uppercased() {
        case "PENDING":    return "待接单"
        case "CLAIMED":    return "已接单·待支付"
        case "PAID":       return "已支付·待采购"
        case "PURCHASING": return "采购中"
        case "DELIVERING": return "配送中"
        case "DELIVERED":  return "已送达·待确认收货"
        case "COMPLETED":  return "已完成"
        case "CANCELLED":  return "已取消"
        case "REFUNDED":   return "已退款"
        default:           return status
        }
    }

    static func agent(_ status: String) -> String {
        switch status.uppercased() {
        case "CLAIMED":    return "待买家支付"
        case "PAID":       return "待采购"
        case "PURCHASING": return "采购中"
        case "DELIVERING": return "配送中"
        case "DELIVERED":  return "待买家确认"
        case "COMPLETED":  return "已完成"
        case "CANCELLED":  return "已取消"
        case "REFUNDED":   return "已退款"
        default:           return status
        }
    }

    static func settlement(_ status: String) -> String {
        switch status.uppercased() {
        case "PENDING", "PAYABLE": return "待结算"
        case "PAID":               return "已结算"
        case "VOID":               return "已冲销"
        default:                   return status
        }
    }
}
