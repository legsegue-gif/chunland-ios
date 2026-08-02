import Foundation

// 代购域 AI 工具：接单进度 / 合并采购清单 / 结算收益（只读）+ 缺货改单起草（mutation，走 HITL）。
// 仅代购身份可用（AIToolName.allowedIdentities 门控：下发+执行两道），
// 买家/商家身份的会话既看不到也调不到。服务端仍有 requireRole('agent') 双保险。
@MainActor
enum AgentTools {
    static let specs: [AIToolSpec] = [
        AIToolSpec(
            name: .listMyClaims,
            tool: AITool(function: AIFunction(
                name: AIToolName.listMyClaims.rawValue,
                description: "查看我（代购人）的接单进度：待办分组计数 + 接单列表（订单号、状态、金额）。可选 status 只看某一状态。**每次重新调用获取最新状态，禁止复用历史结果。**",
                parameters: AIParameters(
                    properties: [
                        "status": AIProperty(
                            type: "string",
                            description: "可选。只看某状态的接单",
                            enum: ["CLAIMED", "PAID", "PURCHASING", "DELIVERING", "DELIVERED"]
                        ),
                    ],
                    required: []
                )
            )),
            kind: .readOnly,
            run: { args, _ in
                let status = args["status"] as? String
                async let dashboardTask = AgentProfileService.shared.dashboard()
                async let ordersTask = OrderService.shared.list(status: status, scope: "mine")
                let (d, orders) = try await (dashboardTask, ordersTask)
                var s = """
                待办概览：待买家支付 \(d.counts.claimed)｜待采购 \(d.counts.paid)｜采购中 \(d.counts.purchasing)（缺小票 \(d.counts.purchasingNoReceipt)、改单待答复 \(d.counts.purchasingPendingAdjustment)）｜配送中 \(d.counts.delivering)｜待买家确认 \(d.counts.delivered)
                """
                if orders.isEmpty {
                    s += status != nil ? "\n该状态下暂无订单。" : "\n还没有接过单。"
                } else {
                    let lines = orders.prefix(20).map { o -> String in
                        "#\(o.orderNumber)（id:\(o.id)）｜\(claimStatusLabel(o.status))｜¥\(o.totalAmount)"
                    }
                    s += "\n接单列表（共 \(orders.count) 笔）：\n" + lines.joined(separator: "\n")
                        + "\n（某单详情用 get_order_detail，order_id 传上面的 id）"
                }
                return s
            }
        ),

        AIToolSpec(
            name: .buildPurchaseList,
            tool: AITool(function: AIFunction(
                name: AIToolName.buildPurchaseList.rawValue,
                description: "整理合并采购清单：把我待采购/采购中的订单按商家分组、同商品跨单聚合数量，并标注各单小票凭证状态。进店采购前调用。**每次重新调用获取最新数据。**",
                parameters: AIParameters(properties: [:], required: [])
            )),
            kind: .readOnly,
            run: { _, _ in
                let list = try await AgentProfileService.shared.purchaseList()
                if list.groups.isEmpty { return "当前没有待采购的订单（待采购/采购中状态才会进清单）。" }
                let sections = list.groups.map { g -> String in
                    let items = g.items.map { it -> String in
                        let size = it.selectedSize.map { "（尺码 \($0)）" } ?? ""
                        let from = it.breakdown.map { "…\($0.orderNumber.suffix(6)) ×\($0.quantity)" }.joined(separator: "、")
                        return "· \(it.name)\(size) ×\(it.totalQuantity)（来自 \(from)）"
                    }.joined(separator: "\n")
                    let receipts = g.orders.map { o in
                        "…\(o.orderNumber.suffix(6))（id:\(o.id)）\(o.hasReceipt ? "已传小票" : "待传小票")"
                    }.joined(separator: "、")
                    return "【\(g.merchantName)】\(g.orders.count) 单 \(g.items.count) 种商品\n\(items)\n小票状态：\(receipts)"
                }
                return sections.joined(separator: "\n\n")
            }
        ),

        AIToolSpec(
            name: .summarizeSettlements,
            tool: AITool(function: AIFunction(
                name: AIToolName.summarizeSettlements.rawValue,
                description: "查看我（代购人）的结算收益：待结算/已结算总额 + 最近结算明细（每单的货款返还、代购费、平台费）。问及收入/结算/某单赚多少时调用。**每次重新调用获取最新数据。**",
                parameters: AIParameters(properties: [:], required: [])
            )),
            kind: .readOnly,
            run: { _, _ in
                let s = try await SettlementService.shared.mine()
                var out = "待结算 ¥\(s.pendingTotal)｜已结算 ¥\(s.paidTotal)"
                if s.items.isEmpty {
                    out += "\n还没有结算记录（订单完成后自动记账）。"
                } else {
                    let lines = s.items.prefix(15).map { r -> String in
                        "#\(r.orderNumber)｜应结 ¥\(r.netPayable)（货款 ¥\(r.itemsReimburse) + 代购费 ¥\(r.agentFee)）｜\(settlementStatusLabel(r.status))"
                    }
                    out += "\n最近结算（共 \(s.items.count) 笔）：\n" + lines.joined(separator: "\n")
                }
                return out
            }
        ),

        AIToolSpec(
            name: .proposeAdjustment,
            tool: AITool(function: AIFunction(
                name: AIToolName.proposeAdjustment.rawValue,
                description: "缺货改单：对采购中的某个订单商品发起「缺货移除」或「减量」，提交后由买家确认。order_id/order_item_id 先用 get_order_detail 查到。MVP 只支持下调，不能加价加量。",
                parameters: AIParameters(
                    properties: [
                        "order_id":      AIProperty(type: "integer", description: "订单的数字 id"),
                        "order_item_id": AIProperty(type: "integer", description: "订单内商品条目的数字 id（get_order_detail 可查）"),
                        "action":        AIProperty(type: "string", description: "remove=缺货整项移除；reduce_qty=按缺货数量下调", enum: ["remove", "reduce_qty"]),
                        "new_quantity":  AIProperty(type: "integer", description: "action=reduce_qty 时必填：下调后的数量（须小于原数量）"),
                        "note":          AIProperty(type: "string", description: "给买家看的说明（可选），如「到店只剩 1 件」"),
                    ],
                    required: ["order_id", "order_item_id", "action"]
                )
            )),
            kind: .mutation,
            intentSummary: { args in
                let action = args["action"] as? String ?? ""
                let desc = action == "remove"
                    ? "缺货移除商品条目 #\(intArg(args, "order_item_id") ?? 0)"
                    : "商品条目 #\(intArg(args, "order_item_id") ?? 0) 数量下调为 \(intArg(args, "new_quantity") ?? 0)"
                return "AI 想对订单 #\(intArg(args, "order_id") ?? 0) 发起缺货改单：\(desc)，提交后需买家确认"
            },
            run: { args, _ in
                guard let orderId = intArg(args, "order_id"),
                      let itemId = intArg(args, "order_item_id"),
                      let action = args["action"] as? String, ["remove", "reduce_qty"].contains(action) else {
                    return "参数不全：需要 order_id、order_item_id 和 action（remove/reduce_qty）。可先用 get_order_detail 查条目 id。"
                }
                let newQuantity = intArg(args, "new_quantity")
                if action == "reduce_qty" && newQuantity == nil {
                    return "action=reduce_qty 时必须提供 new_quantity（下调后的数量）。"
                }
                let item = AdjustmentItem(orderItemId: itemId, action: action, newQuantity: newQuantity)
                let adj = try await AdjustmentService.shared.propose(
                    orderId: orderId,
                    kind: "out_of_stock",
                    detail: AdjustmentDetail(items: [item]),
                    note: args["note"] as? String
                )
                return "改单已提交（金额变化 ¥\(adj.amountDelta)），等待买家确认。买家接受后差额自动部分退款。"
            }
        ),
    ]
}

// 参数取整：模型可能传 Int 也可能传字符串数字，双兜底。
private func intArg(_ args: [String: Any], _ key: String) -> Int? {
    (args[key] as? Int) ?? Int((args[key] as? String) ?? "")
}

// 接单视角的状态文案（与 StatusBadge 语义一致，但站在代购人立场）。
private func claimStatusLabel(_ status: String) -> String {
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

private func settlementStatusLabel(_ status: String) -> String {
    switch status.uppercased() {
    case "PENDING", "PAYABLE": return "待结算"
    case "PAID":               return "已结算"
    case "VOID":               return "已冲销"
    default:                   return status
    }
}
