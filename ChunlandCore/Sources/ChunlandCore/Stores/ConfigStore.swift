import Foundation
import Observation

// 服务端公开配置的进程内缓存。
// SwiftUI View 直接读 ConfigStore.shared.platformFeeRate / minOrderAmount，
// 内部 lazy fetch + 兜底默认值，避免每个 View 各自请求。
//
// 其余 Store（CartStore / OrderStore 等）同在 Stores/ 目录。
@MainActor
@Observable
public final class ConfigStore {
    public static let shared = ConfigStore()

    public var checkoutConfig: CheckoutConfig?               // 全局配置（merchant 为空）
    public private(set) var merchantConfigs: [Int: CheckoutConfig] = [:]  // per-merchant 覆盖

    private init() {}

    // 取不到时给一个稳定的兜底（与 init_data.sql 一致），避免页面渲染挂掉。
    public var platformFeeRate: Decimal {
        checkoutConfig?.platformFeeRate ?? Decimal(string: "0.05")!
    }
    public var agentFeeRate: Decimal {
        checkoutConfig?.agentFeeRate ?? Decimal(string: "0.05")!
    }
    public var minOrderAmount: Decimal {
        checkoutConfig?.minOrderAmount ?? Decimal(0)
    }

    // per-merchant getter：命中商家配置则用之，否则回退全局兜底。
    public func config(merchant: Int?) -> CheckoutConfig? {
        guard let m = merchant else { return checkoutConfig }
        return merchantConfigs[m] ?? checkoutConfig
    }
    public func platformFeeRate(merchant: Int?) -> Decimal {
        config(merchant: merchant)?.platformFeeRate ?? platformFeeRate
    }
    public func agentFeeRate(merchant: Int?) -> Decimal {
        config(merchant: merchant)?.agentFeeRate ?? agentFeeRate
    }
    public func minOrderAmount(merchant: Int?) -> Decimal {
        config(merchant: merchant)?.minOrderAmount ?? minOrderAmount
    }

    // 进入需要费率的页面时 await 调用。已加载则立即返回。
    public func loadIfNeeded() async {
        if checkoutConfig != nil { return }
        do {
            checkoutConfig = try await ConfigService.shared.getCheckout()
        } catch {
            // 网络失败时保持 nil，由 getter 走兜底
            AppLogger.app.warn("ConfigStore.loadIfNeeded failed", metadata: ["error": String(describing: error)])
        }
    }

    // 某商家费率，进店 / 结算前 await。已加载则立即返回；失败时静默由 getter 回退全局。
    public func loadIfNeeded(merchant: Int) async {
        if merchantConfigs[merchant] != nil { return }
        do {
            merchantConfigs[merchant] = try await ConfigService.shared.getCheckout(merchant: merchant)
        } catch {
            AppLogger.app.warn("ConfigStore.loadIfNeeded(merchant:) failed", metadata: ["merchant": "\(merchant)", "error": String(describing: error)])
        }
    }

    public func reload() async {
        checkoutConfig = nil
        merchantConfigs.removeAll()
        await loadIfNeeded()
    }
}
