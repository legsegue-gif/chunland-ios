import Foundation

public actor AddressService {
    public static let shared = AddressService()
    private let api = APIClient.shared

    public func list() async throws -> [Address] {
        try await api.get("/addresses")
    }

    public func create(name: String, phone: String, address: String, note: String? = nil, isDefault: Bool = false,
                       provinceCode: String? = nil, cityCode: String? = nil, areaCode: String? = nil, detail: String? = nil) async throws -> Address {
        struct Body: Encodable {
            let name: String
            let phone: String
            let address: String
            let note: String?
            let isDefault: Bool
            let provinceCode: String?
            let cityCode: String?
            let areaCode: String?
            let detail: String?
        }
        return try await api.post(
            "/addresses",
            body: Body(name: name, phone: phone, address: address, note: note, isDefault: isDefault,
                       provinceCode: provinceCode, cityCode: cityCode, areaCode: areaCode, detail: detail)
        )
    }

    public func update(id: Int, name: String? = nil, phone: String? = nil, address: String? = nil, note: String? = nil, isDefault: Bool? = nil,
                       provinceCode: String? = nil, cityCode: String? = nil, areaCode: String? = nil, detail: String? = nil) async throws -> Address {
        struct Body: Encodable {
            let name: String?
            let phone: String?
            let address: String?
            let note: String?
            let isDefault: Bool?
            let provinceCode: String?
            let cityCode: String?
            let areaCode: String?
            let detail: String?
        }
        return try await api.patch(
            "/addresses/\(id)",
            body: Body(name: name, phone: phone, address: address, note: note, isDefault: isDefault,
                       provinceCode: provinceCode, cityCode: cityCode, areaCode: areaCode, detail: detail)
        )
    }

    public func delete(id: Int) async throws {
        try await api.deleteVoid("/addresses/\(id)")
    }
}
