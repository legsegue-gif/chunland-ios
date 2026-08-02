import Foundation

// 定位反编码 → regions 名称匹配的结果（逐级，匹配不到的级为 nil）
public struct RegionMatch: Sendable {
    public let provinceCode: String?
    public let provinceName: String?
    public let cityCode: String?
    public let cityName: String?
    public let areaCode: String?
    public let areaName: String?
}

public actor RegionService {
    public static let shared = RegionService()
    private let api = APIClient.shared

    // 级联选择器：parent 为空取省级；否则取该节点的直接子级（省→市→区县→街道→村）。
    public func children(parent: String? = nil) async throws -> [Region] {
        let path = parent.map { "/regions?parent=\($0)" } ?? "/regions"
        return try await api.get(path)
    }

    // 定位反编码用：按省/市/区名逐级从 regions 匹配出 code（尽力而为，匹配不到的级返回 nil）。
    // 名称匹配天然有偏差（直辖市错层 / 后缀差异 / 撞名），故结果只作"预填建议"，最终以用户在级联里确认为准。
    public func match(province: String?, city: String?, district: String?) async -> RegionMatch {
        let empty = RegionMatch(provinceCode: nil, provinceName: nil, cityCode: nil, cityName: nil, areaCode: nil, areaName: nil)

        let provinces = (try? await children(parent: nil)) ?? []
        guard let p = Self.fuzzy(provinces, province) else { return empty }

        let cities = (try? await children(parent: p.code)) ?? []
        // 直辖市：city 常为空或等于省名，cities 多为单个"市辖区" → 单元素时直接取
        var c = Self.fuzzy(cities, city)
        if c == nil, cities.count == 1 { c = cities.first }
        guard let c else {
            return RegionMatch(provinceCode: p.code, provinceName: p.name, cityCode: nil, cityName: nil, areaCode: nil, areaName: nil)
        }

        let areas = (try? await children(parent: c.code)) ?? []
        // 区名可能落在 subLocality(district) 或 locality(city)
        let a = Self.fuzzy(areas, district) ?? Self.fuzzy(areas, city)
        return RegionMatch(
            provinceCode: p.code, provinceName: p.name,
            cityCode: c.code, cityName: c.name,
            areaCode: a?.code, areaName: a?.name
        )
    }

    // 名称模糊匹配：精确 → 前缀互含 → 包含
    private static func fuzzy(_ list: [Region], _ raw: String?) -> Region? {
        guard let name = raw?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        if let exact = list.first(where: { $0.name == name }) { return exact }
        if let prefix = list.first(where: { $0.name.hasPrefix(name) || name.hasPrefix($0.name) }) { return prefix }
        return list.first(where: { $0.name.contains(name) || name.contains($0.name) })
    }
}
