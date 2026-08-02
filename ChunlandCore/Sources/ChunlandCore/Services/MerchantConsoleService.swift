import Foundation

// 商家自助（自建商家）：店铺信息 + 商品管理。
// 开店走 AuthManager.openMerchantStore（要重签 token，归 auth 流程管）。
public actor MerchantConsoleService {
    public static let shared = MerchantConsoleService()
    private let api = APIClient.shared

    public func myStore() async throws -> MyStore {
        try await api.get("/merchants/self")
    }

    // 店铺设置。areaCode/minOrderAmount 传 nil = 不改；后端 null = 清空回退全局，
    // 本方法不支持清空（表单语义没有「清空」入口，简化）。
    public func updateStore(name: String? = nil, areaCode: String? = nil,
                            minOrderAmount: Decimal? = nil) async throws -> MyStore {
        struct Body: Encodable {
            let name: String?
            let areaCode: String?
            let minOrderAmount: Decimal?
        }
        return try await api.patch("/merchants/self",
                                   body: Body(name: name, areaCode: areaCode, minOrderAmount: minOrderAmount))
    }

    /// 店铺 logo（选中即上传，raw JPEG）。返回更新后的店铺信息。
    public func uploadLogo(jpeg: Data) async throws -> MyStore {
        try await api.postData("/merchants/self/logo", data: jpeg, contentType: "image/jpeg")
    }

    // ---- 分类方案（lens）----

    public func schemes() async throws -> [CategoryScheme] {
        let page: CategorySchemePage = try await api.get("/merchants/self/schemes")
        return page.items
    }

    /// origin/isVisible 供 AI 分类产品化：AI 草稿以 origin="ai" + isVisible=false（隐藏态）落库，
    /// 商家检查满意后再手动「显示」；手动建方案两参缺省（manual + 可见）。
    public func createScheme(name: String, origin: String? = nil, isVisible: Bool? = nil) async throws -> CategoryScheme {
        struct Body: Encodable { let name: String; let origin: String?; let isVisible: Bool? }
        return try await api.post("/merchants/self/schemes",
                                  body: Body(name: name, origin: origin, isVisible: isVisible))
    }

    public func updateScheme(id: Int, name: String? = nil, isVisible: Bool? = nil,
                             isDefault: Bool? = nil) async throws -> CategoryScheme {
        struct Body: Encodable { let name: String?; let isVisible: Bool?; let isDefault: Bool? }
        return try await api.patch("/merchants/self/schemes/\(id)",
                                   body: Body(name: name, isVisible: isVisible, isDefault: isDefault))
    }

    public func deleteScheme(id: Int) async throws {
        try await api.deleteVoid("/merchants/self/schemes/\(id)")
    }

    /// 返回新分类 id（AI 草稿保存流程建完分类立刻归类要用）。
    /// parentId 非空 = 建二级分类（挂该一级下；最多两级，服务端校验）。
    @discardableResult
    public func addSchemeCategory(schemeId: Int, name: String, parentId: Int? = nil) async throws -> Int {
        struct Body: Encodable { let name: String; let parentId: Int? }
        struct Resp: Decodable { let id: Int }
        let resp: Resp = try await api.post("/merchants/self/schemes/\(schemeId)/categories",
                                            body: Body(name: name, parentId: parentId))
        return resp.id
    }

    public func renameSchemeCategory(id: Int, name: String) async throws {
        struct Body: Encodable { let name: String }
        try await api.patchVoid("/merchants/self/scheme-categories/\(id)", body: Body(name: name))
    }

    /// re-parent（改层级）。parentId=nil → 升为一级；非空 → 挂到该一级下。
    /// 必须显式发 parent_id:null（用 encode 而非 encodeIfPresent），否则服务端当「不改」。
    public func moveSchemeCategory(id: Int, parentId: Int?) async throws {
        struct Body: Encodable {
            let parentId: Int?
            enum CodingKeys: String, CodingKey { case parentId }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(parentId, forKey: .parentId)   // 恒发（含 null），不用 encodeIfPresent
            }
        }
        try await api.patchVoid("/merchants/self/scheme-categories/\(id)", body: Body(parentId: parentId))
    }

    public func deleteSchemeCategory(id: Int) async throws {
        try await api.deleteVoid("/merchants/self/scheme-categories/\(id)")
    }

    public func schemeCategoryProducts(id: Int) async throws -> [String] {
        let resp: SchemeCategoryProducts = try await api.get("/merchants/self/scheme-categories/\(id)/products")
        return resp.productCodes
    }

    /// 分类下商品整体替换（编辑器保存语义）。assignedBy="ai" 记 AI 归类来源，缺省 manual。
    public func setSchemeCategoryProducts(id: Int, codes: [String], assignedBy: String? = nil) async throws {
        struct Body: Encodable { let codes: [String]; let assignedBy: String? }
        struct Resp: Decodable { let id: Int }
        let _: Resp = try await api.put("/merchants/self/scheme-categories/\(id)/products",
                                        body: Body(codes: codes, assignedBy: assignedBy))
    }

    // 订单只读视图
    public func orders(status: String? = nil) async throws -> [MerchantOrderSummary] {
        let path = status.map { "/merchants/self/orders?status=\($0)" } ?? "/merchants/self/orders"
        let page: MerchantOrderPage = try await api.get(path)
        return page.items
    }

    public func order(id: Int) async throws -> MerchantOrderDetail {
        try await api.get("/merchants/self/orders/\(id)")
    }

    public func products() async throws -> [MerchantProduct] {
        let page: MerchantProductPage = try await api.get("/merchants/self/products")
        return page.items
    }

    public func createProduct(name: String, price: Decimal, description: String?,
                              sizes: [String]? = nil) async throws -> MerchantProduct {
        struct Body: Encodable {
            let name: String
            let price: Decimal
            let description: String?
            let sizes: [String]?
        }
        return try await api.post("/merchants/self/products",
                                  body: Body(name: name, price: price, description: description, sizes: sizes))
    }

    public func updateProduct(code: String, name: String? = nil, price: Decimal? = nil,
                              description: String? = nil, purchasable: Bool? = nil,
                              sizes: [String]? = nil, stockStatus: String? = nil) async throws -> MerchantProduct {
        struct Body: Encodable {
            let name: String?
            let price: Decimal?
            let description: String?
            let purchasable: Bool?
            let sizes: [String]?
            let stockStatus: String?
        }
        return try await api.patch("/merchants/self/products/\(code)",
                                   body: Body(name: name, price: price, description: description,
                                              purchasable: purchasable, sizes: sizes, stockStatus: stockStatus))
    }

    /// 商品图上传（两步式：传图拿 key → setProductImages 批量挂载）。
    public func uploadProductAsset(jpeg: Data) async throws -> PostImage {
        try await api.postData("/merchants/self/product-images", data: jpeg, contentType: "image/jpeg")
    }

    /// 商品图整体替换（keys[0] 为主图，空数组 = 清空）。
    public func setProductImages(code: String, keys: [String]) async throws -> MerchantProduct {
        struct Body: Encodable { let keys: [String] }
        return try await api.put("/merchants/self/products/\(code)/images", body: Body(keys: keys))
    }

    // ---- 经营数据 + 店铺动态 ----

    public func stats() async throws -> MerchantStats {
        try await api.get("/merchants/self/stats")
    }

    public func posts() async throws -> [MerchantPost] {
        let page: MerchantPostPage = try await api.get("/merchants/self/posts")
        return page.items
    }

    /// 动态配图（先传图拿 key，再随 createPost 引用）。
    public func uploadPostImage(jpeg: Data) async throws -> PostImage {
        try await api.postData("/merchants/self/post-images", data: jpeg, contentType: "image/jpeg")
    }

    public func createPost(text: String?, mediaKeys: [String], productCode: String? = nil) async throws -> MerchantPost {
        struct Body: Encodable { let text: String?; let mediaKeys: [String]; let productCode: String? }
        return try await api.post("/merchants/self/posts",
                                  body: Body(text: text, mediaKeys: mediaKeys, productCode: productCode))
    }

    public func deletePost(id: Int) async throws {
        try await api.deleteVoid("/merchants/self/posts/\(id)")
    }
}
