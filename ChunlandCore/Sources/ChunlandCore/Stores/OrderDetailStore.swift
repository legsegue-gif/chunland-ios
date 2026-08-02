import Foundation
import Observation

// 订单详情局部 @Observable —— 不是 shared 单例，每个 OrderDetailView 一个 instance。
// 业务方法（load / claim / transition）+ 业务 computed（isOwnerConsumer / isAssignedAgent /
// isAgent）都在 store 内可独立测试。
// 失败时返回错误消息字符串给 View，由 View 渲染为 toast；状态字段直接 @Observable 触发刷新。
@MainActor
@Observable
public final class OrderDetailStore {
    public let orderId: Int

    public var order: OrderDetail?
    public var isLoading = true
    public var error: String?
    public var actionLoading = false

    // 采购凭证
    public var evidences: [OrderEvidence] = []
    public var evidenceLoading = false

    // 缺货改单
    public var adjustments: [OrderAdjustment] = []

    public init(orderId: Int) {
        self.orderId = orderId
    }

    // MARK: - Identity / role computed

    public var isOwnerConsumer: Bool {
        guard let me = AuthManager.shared.currentUserId else { return false }
        return String(order?.consumerId ?? -1) == me
    }

    public var isAssignedAgent: Bool {
        guard let me = AuthManager.shared.currentUserId,
              let agentId = order?.agentId else { return false }
        return String(agentId) == me
    }

    public var isAgent: Bool {
        AuthManager.shared.roles.contains("agent")
    }

    // MARK: - 采购凭证

    // 凭证只在采购及之后阶段、且对本单 consumer/agent 可见（避免浏览大厅的 agent 触发 403）
    private static let evidenceStatuses: Set<String> =
        ["PURCHASING", "DELIVERING", "DELIVERED", "COMPLETED", "REFUNDED"]
    public var showsEvidenceSection: Bool {
        guard let s = order?.status else { return false }
        return (isOwnerConsumer || isAssignedAgent) && Self.evidenceStatuses.contains(s)
    }
    // 仅本单代购人、且在采购阶段可上传小票
    public var canUploadReceipt: Bool {
        isAssignedAgent && order?.status == "PURCHASING"
    }
    public var hasReceipt: Bool { evidences.contains { $0.kind == "receipt" } }

    // MARK: - 缺货改单

    public var pendingAdjustment: OrderAdjustment? { adjustments.first { $0.isPending } }
    // 仅本单代购人、采购阶段、且无待确认改单时可发起
    public var canProposeAdjustment: Bool {
        isAssignedAgent && order?.status == "PURCHASING" && pendingAdjustment == nil
    }
    // 消费者：采购阶段有待确认改单 → 展示决策卡
    public var showsAdjustmentCardForConsumer: Bool {
        isOwnerConsumer && order?.status == "PURCHASING" && pendingAdjustment != nil
    }
    // 代购人：自己发起的改单待消费者确认 → 展示只读状态
    public var hasPendingProposalAsAgent: Bool {
        isAssignedAgent && pendingAdjustment != nil
    }

    // MARK: - Network

    public func load() async {
        isLoading = true
        error = nil
        do {
            // 订单从 PENDING 起即带平台统一定价的 agent_fee，无需再按 agent 自报价预览。
            order = try await OrderService.shared.detail(id: orderId)
        } catch {
            self.error = error.localizedDescription
        }
        await loadEvidence()
        await loadAdjustments()
        isLoading = false
    }

    public func loadEvidence() async {
        guard showsEvidenceSection else { evidences = []; return }
        evidenceLoading = true
        defer { evidenceLoading = false }
        if let list = try? await EvidenceService.shared.list(orderId: orderId) {
            evidences = list
        }
    }

    // 改单与凭证同样的可见条件（本单 consumer/agent + 采购及之后）
    public func loadAdjustments() async {
        guard showsEvidenceSection else { adjustments = []; return }
        if let list = try? await AdjustmentService.shared.list(orderId: orderId) {
            adjustments = list
        }
    }

    /// agent 发起单商品改单。Returns nil on success, error message on failure。
    public func proposeAdjustment(itemId: Int, kind: String, action: String,
                                  newQuantity: Int? = nil, newUnitPrice: Decimal? = nil,
                                  newSize: String? = nil, note: String? = nil) async -> String? {
        actionLoading = true
        defer { actionLoading = false }
        let item = AdjustmentItem(orderItemId: itemId, action: action,
                                  newQuantity: newQuantity, newUnitPrice: newUnitPrice,
                                  newSize: newSize, note: nil)
        do {
            _ = try await AdjustmentService.shared.propose(
                orderId: orderId, kind: kind,
                detail: AdjustmentDetail(items: [item]), note: note)
            await loadAdjustments()
            return nil
        } catch {
            return "发起改单失败：\(error.localizedDescription)"
        }
    }

    /// consumer 接受/拒绝改单。接受后金额变化 → 重载整张订单。
    public func decideAdjustment(_ adjustmentId: Int, accept: Bool, reason: String? = nil) async -> String? {
        actionLoading = true
        defer { actionLoading = false }
        do {
            try await AdjustmentService.shared.decide(
                orderId: orderId, adjustmentId: adjustmentId, accept: accept, reason: reason)
            await load()
            return nil
        } catch {
            return "\(accept ? "接受" : "拒绝")改单失败：\(error.localizedDescription)"
        }
    }

    /// agent 上传小票。Returns nil on success, error message on failure (caller shows toast)。
    public func uploadReceipt(jpeg: Data) async -> String? {
        actionLoading = true
        defer { actionLoading = false }
        do {
            _ = try await EvidenceService.shared.upload(orderId: orderId, kind: "receipt", jpeg: jpeg)
            await loadEvidence()
            return nil
        } catch {
            return "上传失败：\(error.localizedDescription)"
        }
    }

    /// Returns nil on success, error message on failure (caller shows toast).
    public func claim() async -> String? {
        actionLoading = true
        defer { actionLoading = false }
        do {
            _ = try await OrderService.shared.claim(orderId: orderId)
            order = try await OrderService.shared.detail(id: orderId)
            return nil
        } catch {
            return "接单失败：\(error.localizedDescription)"
        }
    }

    public func transition(toStatus: String, label: String) async -> String? {
        actionLoading = true
        defer { actionLoading = false }
        do {
            try await OrderService.shared.updateStatus(orderId: orderId, status: toStatus)
            order = try await OrderService.shared.detail(id: orderId)
            return nil
        } catch {
            return "\(label)失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 支付 / 退款

    // 支付宝回跳 scheme（与 Info.plist CFBundleURLSchemes / server return_url 一致）——
    // appid 由 Config.xcconfig (ALIPAY_APP_ID) 注入 Info.plist，运行时读取，源码不含真实 appid。
    static let alipayScheme = "alipay" + (Bundle.main.object(forInfoDictionaryKey: "AlipayAppID") as? String ?? "")

    /// 发起支付。Mock 模式立即 PAID；alipay 唤起后端上回调仅触发 reload，
    /// 订单状态以服务端 notify 为准。
    public func pay() async -> String? {
        actionLoading = true
        do {
            let result = try await PaymentService.shared.createPayment(orderId: orderId)
            if result.paid {
                order = try await OrderService.shared.detail(id: orderId)
                actionLoading = false
                return nil
            }
            guard let orderStr = result.orderStr else {
                actionLoading = false
                return "支付发起失败：缺少支付参数"
            }
            let oid = orderId
            let launched = AlipayBridgeManager.shared.pay(
                orderString: orderStr, scheme: Self.alipayScheme
            ) { [weak self] success, _ in
                // 端上结果不作准，订单状态以服务端 notify 为准：
                // - 成功：短轮询等 notify 把订单推进到 PAID（SDK completion 几乎总早于 notify 到达）
                // - 取消/失败：刷新一次即可
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if success {
                        self.actionLoading = true
                        await self.pollUntilLeavesClaimed()
                        self.actionLoading = false
                    } else {
                        self.order = try? await OrderService.shared.detail(id: oid)
                    }
                }
            }
            actionLoading = false
            return launched ? nil : "未检测到支付宝，请确认已安装"
        } catch {
            actionLoading = false
            return "支付失败：\(error.localizedDescription)"
        }
    }

    /// 支付成功后短轮询：等 server 收到支付宝异步 notify 把订单推进到 PAID。
    /// 支付宝 SDK 的 completion 几乎总早于 notify 到达，单次回查会落空，故重试。
    /// 状态一旦离开 CLAIMED（→ PAID 等）立即停；约 12 秒（8×1.5s）后放弃，留待用户下拉刷新。
    private func pollUntilLeavesClaimed(maxAttempts: Int = 8,
                                        intervalNanos: UInt64 = 1_500_000_000) async {
        for attempt in 0..<maxAttempts {
            if let fresh = try? await OrderService.shared.detail(id: orderId) {
                order = fresh
                if fresh.status != "CLAIMED" { return }
            }
            if attempt < maxAttempts - 1 {
                try? await Task.sleep(nanoseconds: intervalNanos)
            }
        }
    }

    /// agent 退款（全额）。
    public func refund() async -> String? {
        actionLoading = true
        defer { actionLoading = false }
        do {
            try await PaymentService.shared.refund(orderId: orderId)
            order = try await OrderService.shared.detail(id: orderId)
            return nil
        } catch {
            return "退款失败：\(error.localizedDescription)"
        }
    }
}
