import Foundation

public struct Category: Decodable, Identifiable, Hashable, Sendable {
    public let code: String
    public let name: String
    public let englishName: String?
    public let parentCode: String?
    public let level: Int
    public let sequence: Int?
    public var children: [Category]
    /// 该分类的在售商品数（`withCounts=true` 时才有；父节点含其子节点）。
    /// 给 AI 用：知道每类有多少东西，就不会推荐一个空分类再查一次发现没货。
    public let productCount: Int?

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
        productCount = try c.decodeIfPresent(Int.self, forKey: .productCount)
    }

    enum CodingKeys: String, CodingKey {
        case code, name, englishName, parentCode, level, sequence, children, productCount
    }

    public static func == (lhs: Category, rhs: Category) -> Bool { lhs.code == rhs.code }
    public func hash(into hasher: inout Hasher) { hasher.combine(code) }
}
