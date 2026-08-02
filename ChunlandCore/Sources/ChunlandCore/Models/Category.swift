import Foundation

public struct Category: Decodable, Identifiable, Hashable, Sendable {
    public let code: String
    public let name: String
    public let englishName: String?
    public let parentCode: String?
    public let level: Int
    public let sequence: Int?
    public var children: [Category]

    public var id: String { code }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(String.self, forKey: .code)
        name = try c.decode(String.self, forKey: .name)
        englishName = try c.decodeIfPresent(String.self, forKey: .englishName)
        parentCode  = try c.decodeIfPresent(String.self, forKey: .parentCode)
        level       = try c.decodeIfPresent(Int.self, forKey: .level) ?? 1
        sequence    = try c.decodeIfPresent(Int.self, forKey: .sequence)
        children    = try c.decodeIfPresent([Category].self, forKey: .children) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case code, name, englishName, parentCode, level, sequence, children
    }

    public static func == (lhs: Category, rhs: Category) -> Bool { lhs.code == rhs.code }
    public func hash(into hasher: inout Hasher) { hasher.combine(code) }
}
