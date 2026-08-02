import Foundation
import Observation

// 购物车状态 —— 全局共享单例，跨 View 复用（Cart tab、Checkout、未来 Profile 角标等）。
//
// 业务逻辑（计算、选择、增删改、reload）全部在 store 内可独立测试。
// CartView 只负责 UI 渲染 + 局部 UI 状态（sheet/toast/confirmation）。
@MainActor
@Observable
public final class CartStore {
    public static let shared = CartStore()

    public var cart: Cart?
    public var isLoading = false
    public var error: String?
    // 选择 / 行身份用 cart_items.id（同款不同码是不同行，productCode 不再唯一）
    public var selected: Set<Int> = []

    private init() {}

    // MARK: - Computed views over cart + selected

    public var allItems: [CartItem] { cart?.items ?? [] }
    public var availableItems: [CartItem] { allItems.filter { $0.stockStatus != "outOfStock" } }
    public var invalidItems: [CartItem] { allItems.filter { $0.stockStatus == "outOfStock" } }
    public var selectableItems: [CartItem] { availableItems }
    public var selectedItems: [CartItem] { allItems.filter { selected.contains($0.id) } }

    public var allSelectableSelected: Bool {
        !selectableItems.isEmpty && selectableItems.allSatisfy { selected.contains($0.id) }
    }

    public var selectedTotal: Decimal {
        selectedItems.reduce(Decimal(0)) { acc, item in
            acc + (item.currentPrice ?? 0) * Decimal(item.quantity)
        }
    }

    // MARK: - 按商家分组（Model A：跨店购物车 + 结算拆单）

    public struct MerchantGroup: Identifiable, Sendable {
        public let merchantId: Int
        public let merchantName: String
        public let items: [CartItem]
        public var id: Int { merchantId }
    }

    /// 有货商品按商家分组（保持加入顺序），用于购物车按店 section 展示。
    public var availableGroups: [MerchantGroup] { Self.groupByMerchant(availableItems) }
    /// 选中商品按商家分组，用于结算预览与拆单。
    public var selectedGroups: [MerchantGroup] { Self.groupByMerchant(selectedItems) }

    private static func groupByMerchant(_ items: [CartItem]) -> [MerchantGroup] {
        var order: [Int] = []
        var byId: [Int: [CartItem]] = [:]
        var names: [Int: String] = [:]
        for it in items {
            if byId[it.merchantId] == nil {
                order.append(it.merchantId)
                names[it.merchantId] = it.merchantName
            }
            byId[it.merchantId, default: []].append(it)
        }
        return order.map {
            MerchantGroup(merchantId: $0, merchantName: names[$0] ?? "", items: byId[$0] ?? [])
        }
    }

    // MARK: - 计费预览
    //
    // 与服务端计费同公式：platformFee = round2(subtotal × platformRate)，
    // agentFee = round2(subtotal × agentRate)，total = round2(subtotal + platformFee + agentFee)；
    // 费率 / 起送取 per-merchant（ConfigStore）。仅作 UI 预览，下单最终账单以 server 返回为准。

    public func subtotal(of items: [CartItem]) -> Decimal {
        items.reduce(Decimal(0)) { $0 + ($1.currentPrice ?? 0) * Decimal($1.quantity) }
    }
    public func platformFee(of group: MerchantGroup) -> Decimal {
        Self.round2(subtotal(of: group.items) * ConfigStore.shared.platformFeeRate(merchant: group.merchantId))
    }
    // 代购费平台统一定价，下单即算入（与 server calcAgentFee 同公式）。
    public func agentFee(of group: MerchantGroup) -> Decimal {
        Self.round2(subtotal(of: group.items) * ConfigStore.shared.agentFeeRate(merchant: group.merchantId))
    }
    public func total(of group: MerchantGroup) -> Decimal {
        Self.round2(subtotal(of: group.items) + platformFee(of: group) + agentFee(of: group))
    }
    public func minOrderAmount(of group: MerchantGroup) -> Decimal {
        ConfigStore.shared.minOrderAmount(merchant: group.merchantId)
    }
    public func meetsMinOrder(_ group: MerchantGroup) -> Bool {
        subtotal(of: group.items) >= minOrderAmount(of: group)
    }

    /// 选中项按店计费后的总额预览。
    public var selectedGrandTotal: Decimal {
        selectedGroups.reduce(Decimal(0)) { $0 + total(of: $1) }
    }
    /// 选中项里未满起送的商家组（结算前需提示，server 也会拒绝）。
    public var blockingGroups: [MerchantGroup] {
        selectedGroups.filter { !meetsMinOrder($0) }
    }
    public var canCheckout: Bool {
        !selectedGroups.isEmpty && blockingGroups.isEmpty
    }

    private static func round2(_ d: Decimal) -> Decimal {
        var input = d
        var result = Decimal()
        NSDecimalRound(&result, &input, 2, .plain)
        return result
    }

    // MARK: - Selection mutators

    public func toggleSelect(_ id: Int) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    public func toggleSelectAll() {
        if allSelectableSelected {
            selected.removeAll()
        } else {
            selected = Set(selectableItems.map(\.id))
        }
    }

    // MARK: - Network

    public func reload() async {
        let wasNil = cart == nil
        let previousIds = Set(cart?.items.map(\.id) ?? [])
        isLoading = true
        error = nil
        do {
            cart = try await CartService.shared.get()
        } catch is CancellationError {
            // 用户取消（切 tab / 重新刷新），不视为错误
        } catch let urlError as URLError where urlError.code == .cancelled {
            // URLSession task 被取消
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false

        // 同步 selected 与最新的购物车内容（按行 id）
        if let c = cart {
            let currentIds = Set(c.items.map(\.id))
            if wasNil {
                // 首次加载：默认全选有货商品
                selected = Set(c.items.filter { $0.stockStatus != "outOfStock" }.map(\.id))
            } else {
                // 保留用户选择，丢弃已不在购物车的行
                selected.formIntersection(currentIds)
                // 新加入的有货商品默认勾选
                let newlyAddedIds = currentIds.subtracting(previousIds)
                let newSelectable = c.items
                    .filter { newlyAddedIds.contains($0.id) && $0.stockStatus != "outOfStock" }
                    .map(\.id)
                selected.formUnion(newSelectable)
            }
        }
    }

    /// 预热购物车涉及的所有商家费率，保证按店计费 / 起送校验可用。
    /// 进入购物车与结算页时调用（ConfigStore 内部按 merchant 缓存，重复调用便宜）。
    public func loadMerchantConfigs() async {
        await ConfigStore.shared.loadIfNeeded()   // 全局兜底费率
        for id in Set(allItems.map(\.merchantId)) {
            await ConfigStore.shared.loadIfNeeded(merchant: id)
        }
    }

    /// Returns nil on success / silenced cancellation, or error message on failure (caller shows toast).
    /// 按行 id 定位（同款不同码各一行），调 API 传 (productCode, selectedSize)。
    public func updateItem(_ item: CartItem, quantity: Int) async -> String? {
        guard quantity > 0 else { return await deleteItem(item) }
        guard var c = cart else { return nil }
        let snapshot = c
        if let idx = c.items.firstIndex(where: { $0.id == item.id }) {
            c.items[idx].quantity = quantity
        }
        cart = c
        do {
            try await CartService.shared.updateItem(
                productCode: item.productCode, quantity: quantity, selectedSize: item.selectedSize)
            return nil
        } catch is CancellationError {
            return nil
        } catch let urlError as URLError where urlError.code == .cancelled {
            return nil
        } catch {
            cart = snapshot
            return "修改数量失败：\(error.localizedDescription)"
        }
    }

    public func deleteItem(_ item: CartItem) async -> String? {
        guard var c = cart else { return nil }
        let snapshot = c
        c.items.removeAll { $0.id == item.id }
        cart = c
        selected.remove(item.id)
        do {
            try await CartService.shared.removeItem(
                productCode: item.productCode, selectedSize: item.selectedSize)
            return nil
        } catch is CancellationError {
            return nil
        } catch let urlError as URLError where urlError.code == .cancelled {
            return nil
        } catch {
            cart = snapshot
            return "删除失败：\(error.localizedDescription)"
        }
    }

    public func clearInvalid() async {
        for item in invalidItems {
            _ = await deleteItem(item)
        }
    }

    // 登出后清空，避免下次登录看到上个用户的 cart
    public func reset() {
        cart = nil
        selected.removeAll()
        error = nil
        isLoading = false
    }
}
