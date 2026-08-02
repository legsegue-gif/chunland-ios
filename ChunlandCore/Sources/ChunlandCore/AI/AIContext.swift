import Foundation

// MARK: - AIToolScope —— 工具执行的结构化作用域
//
// seedNote 是喂给模型的散文（模型可以理解错、也可以不理会）；这个是工具执行时的硬约束。
// 进店等场景据此把查询真正限定到当前商家 —— 「搜索默认作用于当前店」必须由代码兑现，
// 不能靠提示词许愿（否则模型会把全局结果一本正经地当成本店数据，见 store ✨ 编造目录 bug）。
public struct AIToolScope: Sendable, Equatable {
    /// 当前进店商家 id（nil = 全局，不限定）。
    public let merchantId: Int?
    /// 商家名（仅用于工具输出文案，如「在 X 店内找到…」）。
    public let merchantName: String?

    public static let global = AIToolScope()

    public init(merchantId: Int? = nil, merchantName: String? = nil) {
        self.merchantId = merchantId
        self.merchantName = merchantName
    }
}

// MARK: - AIContext —— 页面与 AI 之间「唯一的耦合面」（纯值）
//
// 任意页面唤起 AI 时只产出一个 AIContext，经 AICoordinator 递给核心。
// 页面不持有任何 AI 逻辑/工具/模型接线 —— 这是「高内聚低耦合 + 页面零波及」的关键。
//
// 五件事被它显式分开：
//   - title      : sheet 头部展示（「关于 <商品名>」）+ 该会话历史标题
//   - seedNote   : 注入 system 的事实（用户不可见，只喂模型），省一轮工具调用
//   - tools      : 该上下文建议的工具子集（nil = 全量）。聚焦但仍保留跨域，提升命中率
//   - scope      : 工具执行的结构化作用域（给代码，不是给模型），见 AIToolScope
//   - contextKey : 会话续聊的稳定 key（如 "product:123456"）。同 key 的近期会话被复用，
//                  解决「问一半收起再开就没了」+ 抽屉堆满一次性死会话；nil = 每次新开
public struct AIContext: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let seedNote: String?
    public let welcome: String?
    public let tools: Set<AIToolName>?
    public let scope: AIToolScope
    public let contextKey: String?

    public init(id: UUID = UUID(),
                title: String,
                seedNote: String? = nil,
                welcome: String? = nil,
                tools: Set<AIToolName>? = nil,
                scope: AIToolScope = .global,
                contextKey: String? = nil) {
        self.id = id
        self.title = title
        self.seedNote = seedNote
        self.welcome = welcome
        self.tools = tools
        self.scope = scope
        self.contextKey = contextKey
    }
}

// MARK: - 便捷构造器
//
// 把「哪个页面配哪些工具 / 怎样的引导语」收口在核心一处 ——
// 页面调用点只写 `.product(code:name:)`，不关心背后的工具集。
// 调整某页的工具范围/文案 = 改这里一处，所有调用方同步生效。
public extension AIContext {
    /// 商品详情页：聚焦商品/购物车/下单，砍掉分类等噪音，但保留跨域（加购→下单）能力。
    static func product(code: String, name: String) -> AIContext {
        AIContext(
            title: name,
            seedNote: "用户正在浏览商品「\(name)」（商品代码 \(code)）。涉及该商品的库存/价格/详情请调用 get_product_detail 用代码 \(code) 获取最新数据。",
            welcome: "关于「\(name)」，有什么可以帮你？比如它值不值得买、加入购物车。",
            tools: [.getProductDetail, .addToCart, .getCart, .placeOrder],
            contextKey: "product:\(code)"
        )
    }

    /// 购物车页：聚焦购物车与下单，允许再搜商品补单。
    static func cart() -> AIContext {
        AIContext(
            title: "购物车",
            seedNote: "用户正在查看购物车。涉及购物车内容请每次调用 get_cart 获取最新数据，不要复用历史结果。",
            welcome: "需要我帮你看看购物车、凑单或直接下单吗？",
            tools: [.getCart, .searchProducts, .placeOrder],
            contextKey: "cart"
        )
    }

    /// 订单详情页：聚焦订单只读工具（查状态/进度）。number 用于 sheet 头部与 seedNote。
    static func order(id: Int, number: String?) -> AIContext {
        let label = number.map { "订单 \($0)" } ?? "订单"
        return AIContext(
            title: label,
            seedNote: "用户正在查看\(label)（内部 id \(id)）。涉及该订单状态/进度请用 get_order_detail 传 order_id=\(id) 获取最新数据，不要复用历史结果。",
            welcome: "关于这笔订单，有什么可以帮你？比如它到哪了、怎么退、现在还能做什么。",
            tools: [.getOrderDetail, .listMyOrders],
            contextKey: "order:\(id)"
        )
    }

    /// 「我的订单」列表页：订单只读工具。
    static func orders() -> AIContext {
        AIContext(
            title: "我的订单",
            seedNote: "用户正在看「我的订单」列表。用 list_my_orders 查列表、get_order_detail 看某单详情；每次重新调用获取最新状态，不要复用历史结果。",
            welcome: "想了解哪笔订单？我可以帮你查进度、说明状态。",
            tools: [.listMyOrders, .getOrderDetail],
            contextKey: "orders"
        )
    }

    /// 代购工作台：代购域全套工具 + 订单详情钻取。
    static func workbench() -> AIContext {
        AIContext(
            title: "代购工作台",
            seedNote: "用户是代购人，正在看代购工作台。查接单进度用 list_my_claims，进店前整理清单用 build_purchase_list，收入/结算用 summarize_settlements，遇缺货可用 propose_adjustment 起草改单（需用户确认）；某单细节用 get_order_detail。每次重新调用获取最新状态，不要复用历史结果。",
            welcome: "我可以帮你梳理接单进度、整理进店采购清单、算结算收益；遇到缺货还能帮你起草改单。",
            tools: [.listMyClaims, .buildPurchaseList, .summarizeSettlements, .proposeAdjustment, .getOrderDetail],
            contextKey: "agent-workbench"
        )
    }

    /// 商家控制台（AI 分类）：读商品/方案 + 建方案/归类（mutation 走确认）。
    static func merchantConsole(storeName: String? = nil) -> AIContext {
        let label = storeName.map { "「\($0)」" } ?? "你的店铺"
        return AIContext(
            title: storeName ?? "店铺助手",
            seedNote: "用户是商家，正在管理\(label)。帮其做商品分类：先 list_store_products 拿商品、list_category_schemes 看现有方案；建新方案用 create_category_scheme（会弹确认）；归类用 assign_category_products（每个分类调用一次、给该分类全量商品 code，整体替换语义）。归类要覆盖全部商品，不确定归属的放最接近的分类。",
            welcome: "我可以帮你打理店铺分类——比如说「按吃穿住行用给我的店分类」，我会生成方案并把商品归好类（执行前会请你确认）。",
            tools: [.listStoreProducts, .listCategorySchemes, .createCategoryScheme, .assignCategoryProducts],
            contextKey: "merchant-console"
        )
    }

    /// 店铺/首页：全量工具（入口宽泛，不预设范围）。
    /// merchantId 非空（进店内 StoreView）→ 搜索/分类工具经 AIToolScope 硬限定到该店；
    /// nil（店铺选择页/首页）→ 全局。
    static func store(merchantId: Int? = nil, merchantName: String? = nil) -> AIContext {
        let label = merchantName.map { "「\($0)」" } ?? "店铺"
        let inStore = merchantId != nil
        return AIContext(
            title: merchantName ?? "选购助手",
            seedNote: inStore
                ? "用户正在逛\(label)。可帮其搜索商品、查看分类、加购下单；search_products / get_categories 已自动限定在该店范围内，返回的就是本店数据。"
                : "用户正在逛\(label)。可帮其搜索商品、查看分类、加购下单。",
            welcome: "想在\(label)买点什么？我可以帮你搜商品、加购、下单。",
            tools: nil,
            scope: AIToolScope(merchantId: merchantId, merchantName: merchantName),
            contextKey: merchantId.map { "store:\($0)" } ?? "store"
        )
    }
}
