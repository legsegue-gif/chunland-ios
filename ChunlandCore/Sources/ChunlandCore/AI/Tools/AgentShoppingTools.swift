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
            remote: true,
            // 工具体在服务端（R5）。`run` 不可达 —— 注册表见 remote=true 就直接打端点。
            run: { _, _ in "内部错误：search_products 的工具体在服务端，不应走本地执行。" }
        ),

        AgentToolSpec(
            name: .getProductDetail,
            definition: .make(.getProductDetail,
                "获取指定商品的详细信息（价格、库存、规格）",
                params: [("code", .string("商品代码，如 123456"))],
                required: ["code"]),
            kind: .readOnly,
            remote: true,
            // 工具体在服务端（R5）。`run` 不可达 —— 注册表见 remote=true 就直接打端点。
            run: { _, _ in "内部错误：get_product_detail 的工具体在服务端，不应走本地执行。" }
        ),

        AgentToolSpec(
            name: .getCategories,
            definition: .make(.getCategories,
                "获取商品分类及各分类的在售商品数，用于了解有哪些品类"
                + "（店铺上下文中返回当前店铺自己的分类）"),
            kind: .readOnly,
            remote: true,
            // 工具体在服务端（R5）。`run` 不可达 —— 注册表见 remote=true 就直接打端点。
            run: { _, _ in "内部错误：get_categories 的工具体在服务端，不应走本地执行。" }
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
            remote: true,
            intentSummary: { args in
                let code = args.string("product_code") ?? ""
                let qty = args.int("quantity") ?? 1
                return "加入购物车：商品 \(code) × \(qty)"
            },
            // 工具体在服务端（R5）。`run` 不可达 —— 注册表见 remote=true 就直接打端点。
            run: { _, _ in "内部错误：add_to_cart 的工具体在服务端，不应走本地执行。" }
        ),

        AgentToolSpec(
            name: .getCart,
            definition: .make(.getCart,
                "查看当前购物车内容和总价。**每次询问购物车都必须重新调用，"
                + "禁止复用历史结果**（用户可能在中间加/删了商品）。"),
            kind: .readOnly,
            remote: true,
            // 工具体在服务端（R5）。`run` 不可达 —— 注册表见 remote=true 就直接打端点。
            run: { _, _ in "内部错误：get_cart 的工具体在服务端，不应走本地执行。" }
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
            remote: true,
            remotePrepare: true,
            // 执行期解析在服务端（R5）：地址取地址簿、费用取服务端报价（与结算页同一
            // quote 端点，含距离代购费与起送校验），**快照留在服务端**，确认弹窗展示的
            // 与实际执行的由票据绑定。模型全程接触不到地址明细 —— 既堵住「让用户口述
            // 地址 → areaCode 丢失 → 距离费静默为 0」的计费旁路，地址簿 PII 也不进模型上下文。
            run: { _, _ in "内部错误：place_order 必须经确认流程执行。" }
        ),

        AgentToolSpec(
            name: .listMyOrders,
            definition: .make(.listMyOrders,
                "查看「我的订单」列表（订单号、状态、金额）。问及订单进度/历史时调用。"
                + "**每次都重新调用获取最新状态，禁止复用历史结果。**"),
            kind: .readOnly,
            remote: true,
            // 工具体在服务端（R5）。`run` 不可达 —— 注册表见 remote=true 就直接打端点。
            run: { _, _ in "内部错误：list_my_orders 的工具体在服务端，不应走本地执行。" }
        ),

        AgentToolSpec(
            name: .getOrderDetail,
            definition: .make(.getOrderDetail,
                "查看某一订单的详情（状态、金额构成、商品、收货信息、当前可执行的操作）。"
                + "order_id 来自 list_my_orders 的 id 或当前页面上下文。**每次重新调用获取最新状态。**",
                params: [("order_id", .integer("订单的数字 id"))],
                required: ["order_id"]),
            kind: .readOnly,
            remote: true,
            // 工具体在服务端（R5）。`run` 不可达 —— 注册表见 remote=true 就直接打端点。
            run: { _, _ in "内部错误：get_order_detail 的工具体在服务端，不应走本地执行。" }
        ),
    ] }
}
