import Foundation

// 购物车域 AI 工具：加购（mutation，走 HITL）/ 查看（只读）。
@MainActor
enum CartTools {
    static let specs: [AIToolSpec] = [
        AIToolSpec(
            name: .addToCart,
            tool: AITool(function: AIFunction(
                name: AIToolName.addToCart.rawValue,
                description: "将指定商品加入购物车",
                parameters: AIParameters(
                    properties: [
                        "product_code": AIProperty(type: "string",  description: "商品代码"),
                        "quantity":     AIProperty(type: "integer", description: "数量，默认1"),
                    ],
                    required: ["product_code"]
                )
            )),
            kind: .mutation,
            intentSummary: { args in
                let code = args["product_code"] as? String ?? ""
                let qty  = args["quantity"] as? Int ?? 1
                return "AI 想把商品 \(code) × \(qty) 加入购物车"
            },
            run: { args, _ in
                let code = args["product_code"] as? String ?? ""
                let qty  = args["quantity"] as? Int ?? 1
                try await CartService.shared.addItem(productCode: code, quantity: qty)
                return "已将商品 \(code) × \(qty) 加入购物车"
            }
        ),

        AIToolSpec(
            name: .getCart,
            tool: AITool(function: AIFunction(
                name: AIToolName.getCart.rawValue,
                description: "查看当前购物车内容和总价。**每次询问购物车都必须重新调用，禁止复用历史结果**（用户可能在中间加/删了商品）。",
                parameters: AIParameters(properties: [:], required: [])
            )),
            kind: .readOnly,
            run: { _, _ in
                let cart = try await CartService.shared.get()
                if cart.items.isEmpty { return "购物车是空的" }
                let lines = cart.items.map { "\($0.name) × \($0.quantity)  ¥\($0.currentPrice?.description ?? "?")" }
                return "购物车（共 \(cart.items.count) 种商品）：\n" + lines.joined(separator: "\n") + "\n合计：¥\(cart.itemsTotal)"
            }
        ),
    ]
}
