import Foundation

// 下单时随订单冻结的地址快照（不依赖地址簿）
public struct DeliveryAddress: Codable, Sendable {
    public let name: String
    public let phone: String
    public let address: String
    public let note: String?
    public let areaCode: String?   // P1 接单匹配：收货区县 code（可空，兼容旧地址）

    public init(name: String, phone: String, address: String, note: String? = nil, areaCode: String? = nil) {
        self.name = name; self.phone = phone
        self.address = address; self.note = note
        self.areaCode = areaCode
    }
}

// 服务端地址簿条目
public struct Address: Decodable, Identifiable, Sendable, Hashable {
    public let id: Int
    public let name: String
    public let phone: String
    public let address: String
    public let note: String?
    public let isDefault: Bool
    // 结构化区划（均可空，兼容旧的纯 address 录入）+ 坐标地基（押后）
    public let provinceCode: String?
    public let cityCode: String?
    public let areaCode: String?
    public let detail: String?
    public let lat: Double?
    public let lng: Double?

    public var snapshot: DeliveryAddress {
        DeliveryAddress(name: name, phone: phone, address: address, note: note, areaCode: areaCode)
    }
}
