import Foundation
import Observation

// 地址簿状态 —— 全局共享单例。
// CheckoutView 选地址 / Profile 管理地址 / 未来"上次使用地址"等场景共用一份缓存。
@MainActor
@Observable
public final class AddressStore {
    public static let shared = AddressStore()

    public var addresses: [Address] = []
    public var isLoading = false
    public var error: String?

    private init() {}

    public var defaultAddress: Address? {
        addresses.first(where: \.isDefault) ?? addresses.first
    }

    // MARK: - Network

    public func reload() async {
        isLoading = true
        error = nil
        do {
            addresses = try await AddressService.shared.list()
        } catch is CancellationError {
            // user cancel
        } catch let urlError as URLError where urlError.code == .cancelled {
            // URLSession task 被取消
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    /// 乐观删除：先从内存移除，失败回滚 + reload
    public func delete(id: Int) async {
        let snapshot = addresses
        addresses.removeAll { $0.id == id }
        do {
            try await AddressService.shared.delete(id: id)
            await reload()
        } catch {
            addresses = snapshot
        }
    }

    public func create(name: String, phone: String, address: String, note: String?, isDefault: Bool,
                       provinceCode: String? = nil, cityCode: String? = nil, areaCode: String? = nil, detail: String? = nil) async throws -> Address {
        let created = try await AddressService.shared.create(
            name: name, phone: phone, address: address, note: note, isDefault: isDefault,
            provinceCode: provinceCode, cityCode: cityCode, areaCode: areaCode, detail: detail
        )
        await reload()
        return created
    }

    public func update(id: Int, name: String, phone: String, address: String, note: String?, isDefault: Bool,
                       provinceCode: String? = nil, cityCode: String? = nil, areaCode: String? = nil, detail: String? = nil) async throws -> Address {
        let updated = try await AddressService.shared.update(
            id: id, name: name, phone: phone, address: address, note: note, isDefault: isDefault,
            provinceCode: provinceCode, cityCode: cityCode, areaCode: areaCode, detail: detail
        )
        await reload()
        return updated
    }

    public func reset() {
        addresses = []
        error = nil
        isLoading = false
    }
}
