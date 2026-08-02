import Foundation
import CoreLocation

public enum LocationError: Error, Sendable { case denied, unavailable }

// 定位 + 反编码结果（坐标 + 省/市/区中文名）
public struct GeoResult: Sendable {
    public let lat: Double
    public let lng: Double
    public let province: String?
    public let city: String?
    public let district: String?
    // 精确定位增强：用户授权精确(.fullAccuracy) 且本次水平精度 ≤100m 时，streetDetail 带街道+门牌
    //（如「知行路149号」），供详细地址在标准省市区后追加；非精确为 nil。
    public let streetDetail: String?
    // POI 兴趣点（areasOfInterest 首项，如「德基广场」「南京南站」）：同精确门槛才取，
    // 拼到详细地址最末作地标补充；非精确坐标被抖到 ~5km，POI 会指错地标故为 nil。
    public let poi: String?
}

// 一次性定位 + 反向地理编码（CLGeocoder，Apple 自带、免费、无需第三方 key）。
// @MainActor：CLLocationManager 的回调在主线程，统一在主 actor 上管理 continuation。
@MainActor
public final class LocationService: NSObject, CLLocationManagerDelegate {
    public static let shared = LocationService()
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    override private init() {
        super.init()
        manager.delegate = self
    }

    // 定位 → 反编码出省/市/区名。坐标系：Apple 在中国大陆返回 GCJ-02（与项目约定一致）。
    public func locateAndGeocode() async throws -> GeoResult {
        let loc = try await currentLocation()
        return try await geocode(loc)
    }

    /// 已授权才静默定位 + 反编码，**绝不触发授权弹窗**（同 coordinateIfAuthorized 纪律）。
    /// 供店铺页首次进入预填城市 —— 授权询问只发生在用户主动点「使用当前定位」。
    public func geocodeIfAuthorized() async -> GeoResult? {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            guard let loc = try? await currentLocation() else { return nil }
            return try? await geocode(loc)
        default:
            return nil
        }
    }

    private func geocode(_ loc: CLLocation) async throws -> GeoResult {
        // 强制 zh_CN：否则 CLGeocoder 跟随系统语言，英文环境返回 "Jiangsu/Nanjing/Gulou" 无法匹配中文 regions
        let placemarks = try await CLGeocoder().reverseGeocodeLocation(loc, preferredLocale: Locale(identifier: "zh_CN"))
        let pm = placemarks.first

        // 精确判定：用户授权精确 且 本次实测水平精度可信(≥0 且 ≤100m，门牌级)。
        // 非精确授权时坐标被抖到 ~5km 网格，街道/门牌无意义，故只在精确时取 streetDetail。
        let accuracy = loc.horizontalAccuracy
        let isPrecise = manager.accuracyAuthorization == .fullAccuracy && accuracy >= 0 && accuracy <= 100
        let street = [pm?.thoroughfare, pm?.subThoroughfare].compactMap { $0 }.joined()
        let streetDetail = (isPrecise && !street.isEmpty) ? street : nil
        // POI：areasOfInterest 首项（地标/建筑名），同精确门槛
        let poi = isPrecise ? pm?.areasOfInterest?.first : nil

        return GeoResult(
            lat: loc.coordinate.latitude,
            lng: loc.coordinate.longitude,
            province: pm?.administrativeArea,
            city: pm?.locality,
            district: pm?.subLocality,
            streetDetail: streetDetail,
            poi: poi
        )
    }

    /// 已授权才取当前坐标，**绝不触发授权弹窗**（notDetermined/denied 直接返回 nil）。
    /// 供静默场景用（如代购人坐标上报供大厅距离兜底）——授权询问只发生在用户主动
    /// 点定位按钮的场景（locateAndGeocode），静默路径蹭已有授权。
    public func coordinateIfAuthorized() async -> (lat: Double, lng: Double)? {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            guard let loc = try? await currentLocation() else { return nil }
            return (loc.coordinate.latitude, loc.coordinate.longitude)
        default:
            return nil
        }
    }

    private func currentLocation() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            switch manager.authorizationStatus {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()      // 授权回调里再 requestLocation
            case .authorizedWhenInUse, .authorizedAlways:
                manager.requestLocation()
            default:
                finish(.failure(LocationError.denied))
            }
        }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(with: result)
    }

    // MARK: - CLLocationManagerDelegate

    public nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let status = m.authorizationStatus
        Task { @MainActor in
            switch status {
            case .authorizedWhenInUse, .authorizedAlways: self.manager.requestLocation()
            case .denied, .restricted: self.finish(.failure(LocationError.denied))
            default: break   // notDetermined：等用户决定
            }
        }
    }

    public nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        let first = locs.first
        Task { @MainActor in
            if let loc = first { self.finish(.success(loc)) }
        }
    }

    public nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(.failure(error)) }
    }
}
