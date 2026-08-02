import Foundation
import Observation

// store picker 的商家列表缓存 + 当前进入的店 + 定位锚点（城市选择器）。
// merchants 几乎不变，进程内缓存即可；currentMerchant 供进店后的上下文消费
// （AI 的 search / add_to_cart 需要「当前店」上下文 —— 见 P4d）。
@MainActor
@Observable
public final class MerchantStore {
    public static let shared = MerchantStore()

    public private(set) var merchants: [Merchant] = []
    public var currentMerchant: Merchant?

    // 定位锚点：用户选中的地点，可为省/市/区县任一级（region code）。nil = 全国（不排序、不算距离）。
    // 设了锚点 → server 按距离升序返回全部在售店（不过滤）；近店直接展示、远店折叠（见 nearby/farther）。
    // UserDefaults 持久化跨启动生效；不随登出 reset —— 位置是设备语境不是账号数据。
    // 展示名以 server 回显（list 响应 anchor）为准，本地传入值只作乐观兜底。
    public private(set) var anchorCode: String?
    /// 选中地点名（省/市/区县，顶栏显示）
    public private(set) var anchorName: String?
    /// 选中地点所属市 code（省级 anchor 为 nil）：店铺卡「同市省略市名」分组判断
    public private(set) var anchorCityCode: String?

    /// 近店/远店折叠阈值（km）。代购可达半径的经验值：覆盖邻市代购（如扬州↔南京 ~100km），
    /// 超出的（跨省远店）默认折叠、不隐藏。后续可迁移到 system_configs 做成可配。
    public static let nearbyRadiusKm: Double = 150

    private static let anchorCodeKey = "merchants.anchor.code"
    private static let anchorNameKey = "merchants.anchor.name"
    private static let anchorCityCodeKey = "merchants.anchor.cityCode"

    private init() {
        let d = UserDefaults.standard
        anchorCode = d.string(forKey: Self.anchorCodeKey)
        anchorName = d.string(forKey: Self.anchorNameKey)
        anchorCityCode = d.string(forKey: Self.anchorCityCodeKey)
    }

    public func loadIfNeeded() async {
        if !merchants.isEmpty { return }
        do {
            let (items, anchor) = try await MerchantService.shared.list(anchor: anchorCode)
            merchants = items
            applyAnchorEcho(anchor)
        } catch {
            AppLogger.app.warn("MerchantStore.loadIfNeeded failed", metadata: ["error": String(describing: error)])
        }
    }

    public func reload() async {
        merchants = []
        await loadIfNeeded()
    }

    /// 切换定位锚点（省/市/区县任一级 code）并重载列表。
    /// displayName 只作立即显示的兜底，reload 后被 server 回显的地点名/所属市覆盖。
    public func setAnchor(code: String, displayName: String?) async {
        anchorCode = code
        anchorName = displayName
        anchorCityCode = nil          // 待 server 回显确定所属市
        persistAnchor()
        await reload()
    }

    /// 清除锚点（「全国」）。
    public func clearAnchor() async {
        anchorCode = nil
        anchorName = nil
        anchorCityCode = nil
        persistAnchor()
        await reload()
    }

    public func reset() {
        merchants = []
        currentMerchant = nil
    }

    // MARK: - 近店/远店（折叠展示；server 已按距离升序，这里只按阈值切分）

    /// 近店（distanceKm ≤ 阈值），直接展示。未设锚点 = 全国：全部当近店（不折叠）。
    public var nearbyMerchants: [Merchant] {
        guard anchorCode != nil else { return merchants }
        return merchants.filter { ($0.distanceKm ?? .infinity) <= Self.nearbyRadiusKm }
    }

    /// 远店（distanceKm > 阈值，含无发货地的店），默认折叠。未设锚点为空。
    public var fartherMerchants: [Merchant] {
        guard anchorCode != nil else { return [] }
        return merchants.filter { ($0.distanceKm ?? .infinity) > Self.nearbyRadiusKm }
    }

    // server 回显锚点：地点名/所属市以回显为准；code 无效（字典变更/脏持久化）→ 回退全国。
    private func applyAnchorEcho(_ anchor: MerchantListAnchor?) {
        guard anchorCode != nil else { return }
        if let anchor {
            if let name = anchor.name { anchorName = name }
            anchorCityCode = anchor.cityCode   // 省级 anchor 为 nil
        } else {
            anchorCode = nil
            anchorName = nil
            anchorCityCode = nil
        }
        persistAnchor()
    }

    private func persistAnchor() {
        let d = UserDefaults.standard
        d.set(anchorCode, forKey: Self.anchorCodeKey)
        d.set(anchorName, forKey: Self.anchorNameKey)
        d.set(anchorCityCode, forKey: Self.anchorCityCodeKey)
    }
}
