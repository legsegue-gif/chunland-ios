import Foundation

// 订单域 AI 工具：下单（mutation，走 HITL）+ 查我的订单 / 看某单详情（只读）。
// 订单的状态流转（确认收货 / 取消 / 退款等）敏感，暂不交给 AI（押后）。
@MainActor
enum OrderTools {
    static let specs: [AIToolSpec] = [
        AIToolSpec(
            name: .placeOrder,
            tool: AITool(function: AIFunction(
                name: AIToolName.placeOrder.rawValue,
                description: "用购物车当前内容下单。收货地址自动使用用户地址簿的默认地址、费用以服务端报价为准，两者都会在确认弹窗中展示给用户 —— **不要向用户索要姓名/电话/地址，也不要自行报费用**。用户没有地址时引导其到「我的 → 地址管理」添加；想换地址时告知其到购物车结算页选择。",
                parameters: AIParameters(
                    properties: [
                        "note": AIProperty(type: "string", description: "配送备注（可选）"),
                    ],
                    required: []
                )
            )),
            kind: .mutation,
            // 执行期解析（PreparedMutation）：地址取地址簿、费用取服务端报价（与结算页同一
            // quote 端点，含 距离代购费与起送校验），确认弹窗展示并执行的都是这份快照。
            // 模型全程接触不到地址明细 —— 既堵住「让用户口述地址 → areaCode 丢失 → 距离费
            // 静默为 0」的计费旁路，地址簿 PII 也不进模型上下文。
            prepare: { args, _ in
                let addresses = try await AddressService.shared.list()
                guard !addresses.isEmpty else {
                    return .abort("用户的地址簿还没有收货地址，无法下单。请引导用户到「我的 → 地址管理」添加收货地址后再试；不要让用户在对话里口述地址。")
                }
                let chosen = addresses.first { $0.isDefault } ?? addresses[0]
                let quote = try await OrderService.shared.quote(areaCode: chosen.areaCode)
                if let short = quote.groups.first(where: { !$0.meetsMinOrder }) {
                    return .abort("「\(short.merchantName)」商品小计 ¥\(short.itemsTotal) 未达起送金额 ¥\(short.minOrderAmount)，无法下单。可建议用户补足该店商品，或从购物车移除该店商品后再下单。")
                }
                let delivery = DeliveryAddress(
                    name: chosen.name, phone: chosen.phone, address: chosen.address,
                    note: args["note"] as? String, areaCode: chosen.areaCode
                )
                let fees = quote.groups.count == 1
                    ? quote.groups.map { "费用：商品 ¥\($0.itemsTotal) + 平台费 ¥\($0.platformFee) + 代购费 ¥\($0.agentFee)" }
                    : quote.groups.map { "\($0.merchantName)：商品 ¥\($0.itemsTotal) + 平台费 ¥\($0.platformFee) + 代购费 ¥\($0.agentFee)" }
                let summary = """
                AI 想用购物车内容下单\(quote.groups.count > 1 ? "（\(quote.groups.count) 个商家，分别成单）" : "")
                收货：\(chosen.name) \(chosen.phone)\(chosen.isDefault ? "（默认地址）" : "")
                地址：\(chosen.address)
                \(fees.joined(separator: "\n"))
                合计 ¥\(quote.grandTotal)
                """
                return .ready(
                    intent: MutationIntent(
                        toolName: .placeOrder,
                        summary: summary,
                        payload: ["address_id": "\(chosen.id)", "grand_total": "\(quote.grandTotal)"]
                    ),
                    execute: {
                        let batch = try await OrderService.shared.placeOrder(deliveryAddress: delivery)
                        let dest = "收货地址用的是用户确认过的地址簿地址（\(chosen.name)，\(chosen.address)）"
                        if batch.orderCount == 1, let only = batch.orders.first {
                            return "下单成功！订单号：\(only.orderNumber)，总金额：¥\(only.totalAmount)，等待代购人接单。\(dest)。"
                        }
                        return "下单成功！已按商家拆为 \(batch.orderCount) 笔订单，合计 ¥\(batch.grandTotal)，等待代购人接单。\(dest)。"
                    }
                )
            },
            run: { _, _ in
                // 不可达：place_order 恒经 prepare 的确认流程执行（executeTool 优先走 prepare）
                "内部错误：place_order 只能经确认流程执行。"
            }
        ),

        AIToolSpec(
            name: .listMyOrders,
            tool: AITool(function: AIFunction(
                name: AIToolName.listMyOrders.rawValue,
                description: "查看「我的订单」列表（订单号、状态、金额）。问及订单进度/历史时调用。**每次都重新调用获取最新状态，禁止复用历史结果。**",
                parameters: AIParameters(properties: [:], required: [])
            )),
            kind: .readOnly,
            run: { _, _ in
                let orders = try await OrderService.shared.list()
                if orders.isEmpty { return "你还没有订单。" }
                let lines = orders.prefix(20).map { o -> String in
                    let cnt = o.itemCount.map { "\($0)件" } ?? ""
                    return "#\(o.orderNumber)（id:\(o.id)）｜\(orderStatusLabel(o.status))｜¥\(o.totalAmount)｜\(cnt)"
                }
                return "你的订单（共 \(orders.count) 笔）：\n" + lines.joined(separator: "\n")
                    + "\n（需要某单详情时用 get_order_detail，order_id 传上面的 id）"
            }
        ),

        AIToolSpec(
            name: .getOrderDetail,
            tool: AITool(function: AIFunction(
                name: AIToolName.getOrderDetail.rawValue,
                description: "查看某一订单的详情（状态、金额构成、商品、收货信息、当前可执行的操作）。order_id 来自 list_my_orders 的 id 或当前页面上下文。**每次重新调用获取最新状态。**",
                parameters: AIParameters(
                    properties: ["order_id": AIProperty(type: "integer", description: "订单的数字 id")],
                    required: ["order_id"]
                )
            )),
            kind: .readOnly,
            run: { args, _ in
                guard let oid = (args["order_id"] as? Int) ?? Int((args["order_id"] as? String) ?? "") else {
                    return "请提供 order_id（订单的数字 id）。可先用 list_my_orders 查到 id。"
                }
                let o = try await OrderService.shared.detail(id: oid)
                var s = """
                订单 #\(o.orderNumber)
                状态：\(orderStatusLabel(o.status))
                合计：¥\(o.totalAmount)（商品 ¥\(o.itemsTotal) + 平台费 ¥\(o.platformFee) + 代购费 ¥\(o.agentFee)）
                商品：\(o.items.map { "\($0.productSnapshot.name) × \($0.quantity)" }.joined(separator: "、"))
                收货：\(o.deliveryAddress.name) \(o.deliveryAddress.address)
                下单时间：\(o.createdAt)
                """
                if let actions = o.availableActions, !actions.isEmpty {
                    s += "\n你现在可以：\(actions.map(\.label).joined(separator: "、"))"
                }
                return s
            }
        ),
    ]
}

// 订单状态码 → 中文（工具输出用，帮模型准确表述）。与 UI 的 StatusBadge 文案保持语义一致。
private func orderStatusLabel(_ status: String) -> String {
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
