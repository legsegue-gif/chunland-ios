import Foundation

// MARK: - 工具名与身份可用集
//
// **这是三身份工具门控的单一真相源。**
//
// 两侧共用同一判定：
//   下发侧  AgentToolRegistry.availableTools  裁剪发给模型的 schema
//   执行侧  AgentToolRegistry.isAvailable     在管道 preflight 阶段再拦一次
// 执行侧必须存在 —— 会话跨身份留存（切身份不清历史），模型可能从历史里
// 复调旧身份的工具名，「模型看不到」不等于「调不到」。

public enum AIToolName: String, CaseIterable, Sendable {
    case searchProducts   = "search_products"
    case getProductDetail = "get_product_detail"
    case getCategories    = "get_categories"
    case addToCart        = "add_to_cart"
    case getCart          = "get_cart"
    case placeOrder       = "place_order"
    case listMyOrders     = "list_my_orders"
    case getOrderDetail   = "get_order_detail"
    // 代购域：仅显式作用域可见（isAgentScoped），消费者页面的全量工具集不含它们
    case listMyClaims        = "list_my_claims"
    case buildPurchaseList   = "build_purchase_list"
    case summarizeSettlements = "summarize_settlements"
    case proposeAdjustment   = "propose_adjustment"
    // 商家域（AI 分类路线 A）：仅显式作用域可见（isMerchantScoped）
    case listStoreProducts   = "list_store_products"
    case listCategorySchemes = "list_category_schemes"
    case createCategoryScheme = "create_category_scheme"
    case assignCategoryProducts = "assign_category_products"

    // 区分只读 / 变更类工具 —— Mutation 工具走 HITL（aiAutoConfirm=false 时弹窗确认）
    // 扩展点：HITL 自动确认
    public enum Kind: Sendable { case readOnly, mutation }

    public var kind: Kind {
        switch self {
        case .searchProducts, .getProductDetail, .getCategories, .getCart,
             .listMyOrders, .getOrderDetail,
             .listMyClaims, .buildPurchaseList, .summarizeSettlements,
             .listStoreProducts, .listCategorySchemes:
            return .readOnly
        case .addToCart, .placeOrder, .proposeAdjustment,
             .createCategoryScheme, .assignCategoryProducts:
            return .mutation
        }
    }

    /// 三身份可用集 —— AI 可用/可调用的工具是**当前活跃身份的函数**（单一真相源）。
    /// 两侧共用同一判定：下发侧（AgentToolRegistry.availableTools 裁剪发给模型的 schema）+
    /// 执行侧（工具管道 preflight 守卫）。执行侧必须再拦一道 ——
    /// 会话跨身份留存（切身份不清历史），模型可能从历史里复调旧身份的工具名，
    /// 「模型看不到」不等于「调不到」。产品语义：
    /// 购物/下单只属买家身份，代购/商家身份不做买家的事；get_order_detail 是唯一跨域
    /// 例外（代购人跟进接单详情同样需要，服务端按订单参与方鉴权）。
    public var allowedIdentities: Set<String> {
        switch self {
        case .searchProducts, .getProductDetail, .getCategories,
             .addToCart, .getCart, .placeOrder, .listMyOrders:
            return ["consumer"]
        case .getOrderDetail:
            return ["consumer", "agent"]
        case .listMyClaims, .buildPurchaseList, .summarizeSettlements, .proposeAdjustment:
            return ["agent"]
        case .listStoreProducts, .listCategorySchemes, .createCategoryScheme, .assignCategoryProducts:
            return ["merchant"]
        }
    }

    public func isAllowed(for identity: String) -> Bool {
        allowedIdentities.contains(identity)
    }

    /// 身份的中文标签（执行守卫的拒绝文案 / UI 共用）。
    public static func identityLabel(_ identity: String) -> String {
        switch identity {
        case "consumer": return "买家"
        case "agent":    return "代购人"
        case "merchant": return "商家"
        default:          return identity
        }
    }

    // 工具调用指示器的中文名（UI 用）。挂在枚举上 = 单一真相源、nonisolated，
    // 任意隔离域（含非 MainActor 的 SwiftUI 视图辅助）都能直接读，避免重复 switch。
    public var friendlyName: String {
        switch self {
        case .searchProducts:   return "搜索商品"
        case .getProductDetail: return "查看详情"
        case .getCategories:    return "浏览分类"
        case .addToCart:        return "加入购物车"
        case .getCart:          return "查看购物车"
        case .placeOrder:       return "提交订单"
        case .listMyOrders:     return "查看我的订单"
        case .getOrderDetail:   return "查看订单详情"
        case .listMyClaims:        return "查看接单进度"
        case .buildPurchaseList:   return "整理采购清单"
        case .summarizeSettlements: return "查看结算收益"
        case .proposeAdjustment:   return "起草缺货改单"
        case .listStoreProducts:   return "读取店铺商品"
        case .listCategorySchemes: return "查看分类方案"
        case .createCategoryScheme: return "创建分类方案"
        case .assignCategoryProducts: return "归类商品"
        }
    }
}
