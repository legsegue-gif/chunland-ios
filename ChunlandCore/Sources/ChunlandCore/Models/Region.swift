import Foundation

// 行政区划字典项（GET /api/v1/regions）。
// level: 1省 2市 3区县 4街道。code 为国标区划码（区县级 code = 地址匹配键 / agent 服务区单元）。
public struct Region: Decodable, Identifiable, Sendable, Hashable {
    public let code: String
    public let name: String
    public let level: Int
    public var id: String { code }
}
