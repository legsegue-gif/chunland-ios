import Foundation

// MARK: - Tool 名 / 分类（共享类型）
//
// 工具的「定义（schema）+ 执行（handler）」已按域拆到 Tools/ 下各文件自注册（见 AIToolRegistry）。
// 本文件只留跨域共享的类型：工具名枚举、读/写分类、确认意图、OpenAI function schema 结构。

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
    /// 两侧共用同一判定：下发侧（AIToolRegistry.tools 裁剪发给模型的 schema）+
    /// 执行侧（AIOrchestrator.executeTool 守卫）。执行侧必须再拦一道 ——
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

    /// 实时类工具 —— 结果随时间失效（购物车/订单/接单/店铺快照）。发送期把历史轮的
    /// 这类结果折叠成过期占位（AIOrchestrator.wireHistory），物理杜绝模型复用过期数据；
    /// 搜索/详情/分类结果刻意不折叠（prompt 规则 3 明确允许复用），mutation 的简短
    /// 确认文本（含订单号）保留作对话叙事。Android 同构（AiToolName.resultVolatile）。
    public var resultIsVolatile: Bool {
        switch self {
        case .getCart, .listMyOrders, .getOrderDetail,
             .listMyClaims, .buildPurchaseList, .summarizeSettlements,
             .listStoreProducts, .listCategorySchemes:
            return true
        case .searchProducts, .getProductDetail, .getCategories,
             .addToCart, .placeOrder, .proposeAdjustment,
             .createCategoryScheme, .assignCategoryProducts:
            return false
        }
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

// MutationIntent —— AI 想执行变更操作时先返回一个意图，由 UI 弹确认窗
public struct MutationIntent: Identifiable, Sendable {
    public let id = UUID()
    public let toolName: AIToolName
    public let summary: String                 // 给用户看的中文摘要
    public let payload: [String: String]       // 给开发者 debug，纯 String 便于 Sendable

    public init(toolName: AIToolName, summary: String, payload: [String: String]) {
        self.toolName = toolName
        self.summary = summary
        self.payload = payload
    }
}

// MARK: - OpenAI function schema 结构（发给 AI 的工具描述）

public struct AITool: Encodable {
    public let type = "function"
    public let function: AIFunction
    public init(function: AIFunction) { self.function = function }
}

public struct AIFunction: Encodable {
    public let name: String
    public let description: String
    public let parameters: AIParameters
    public init(name: String, description: String, parameters: AIParameters) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct AIParameters: Encodable {
    public let type = "object"
    public let properties: [String: AIProperty]
    public let required: [String]
    public init(properties: [String: AIProperty], required: [String]) {
        self.properties = properties
        self.required = required
    }
}

public struct AIProperty: Encodable {
    public let type: String
    public let description: String
    public let `enum`: [String]?

    public init(type: String, description: String, enum cases: [String]? = nil) {
        self.type = type
        self.description = description
        self.enum = cases
    }
}
