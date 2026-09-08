import Foundation

// MARK: - 线上下发的工具（wire tools）
//
// R5 之后工具体在服务端，但 schema 仍钉死在端上 —— 于是「加一个只读查询工具」
// 这种纯增量的事，仍要改两端代码并各自重新发布。
//
// 这里放开的正是这一件事：**只读工具的 schema 可以由服务端下发**
// （`GET /ai/tools/schema`），新增只读工具不必改端上代码。
//
// ⚠️ **变更工具永远不下发,永远钉死在端上。** 判据是安不安全，不是新不旧：
// `kind: .mutation` 决定弹不弹 HITL 确认框，那是模型「想下单」与「真下单」
// 之间唯一的人工闸门。它若由下发内容决定，一个服务端 bug 就能让确认框静默消失。
//
// 这条不是靠纪律守的，是靠**类型**守的 —— 见下面 `AgentRemoteToolSpec` 的注释。

/// 一个线上下发的工具。
///
/// **刻意没有 `kind` 字段,也没有 `run`**：不是「有个字段但我们记得检查它」，
/// 而是结构上就表达不出「这是个变更工具」「这个在本地执行」。
/// 于是「wire 工具一律只读、一律走服务端」由构造保证，不存在写错的路径。
public struct AgentRemoteToolSpec: Sendable, Equatable {

    public let definition: AgentToolDefinition

    /// 仅用于下发裁剪（决定给模型看不看得到）。
    ///
    /// **不是权限门** —— 真正的门在服务端：`aiToolCatalog` 的身份判定 +
    /// 各 service 自己的所有权校验。端上这份只是让模型少看见几个用不了的工具。
    public let identities: Set<String>

    public var name: String { definition.name }

    public func isAllowed(for identity: String) -> Bool {
        identities.contains(identity)
    }
}

// MARK: - 下发内容的解码

/// 服务端下发的一个工具。
///
/// ⚠️ **参数是数组不是字典。** 参数名本身是 snake_case（`price_min` 这类），
/// 当成 JSON 的 key 会被 `JSONDecoder.convertFromSnakeCase` 一并转成 `priceMin`，
/// 于是发给模型的参数名与钉死工具的口径对不上 —— 而且不报错。
/// 放进 `name` 字段（是值不是键）就没这问题。
struct WireToolDTO: Codable, Sendable {
    let name: String
    let description: String
    let identities: [String]
    let params: [WireParamDTO]
}

struct WireParamDTO: Codable, Sendable {
    let name: String
    let type: String
    let description: String
    let required: Bool
    let enumValues: [String]?
    let itemType: String?
}

struct WireSchemaDTO: Codable, Sendable {
    let version: Int
    let tools: [WireToolDTO]
}

extension WireToolDTO {
    /// DTO → spec。类型名不认识就退回 `.string` —— 服务端将来加新类型时，
    /// 老客户端应当**退化而不是整条丢弃**（丢弃 = 那个工具静默消失）。
    func toSpec() -> AgentRemoteToolSpec {
        var parameters: [String: AgentToolParam] = [:]
        var required: [String] = []
        for p in params {
            parameters[p.name] = AgentToolParam(
                type: AgentParamType(rawValue: p.type) ?? .string,
                description: p.description,
                enumValues: p.enumValues,
                itemType: p.itemType.flatMap(AgentParamType.init(rawValue:))
            )
            if p.required { required.append(p.name) }
        }
        return AgentRemoteToolSpec(
            definition: AgentToolDefinition(
                name: name,
                description: description,
                parameters: parameters,
                required: required,
                // 数组顺序就是生成顺序 —— 部分模型对参数顺序敏感
                propertyOrdering: params.map(\.name)
            ),
            identities: Set(identities)
        )
    }
}

// MARK: - 合并

public enum AIWireTools {

    /// 钉死的 + 下发的 → 发给模型的工具集。
    ///
    /// 抽成纯函数是为了它能被直接测到 —— 规则只有两条，但都不能错：
    /// 1. **重名时钉死的赢**：防服务端下发一个叫 `place_order` 的「只读」工具来遮蔽真的那个
    /// 2. 按身份裁剪（端上这道只是让模型少看见几个用不了的，真正的门在服务端）
    ///
    /// ⚠️ 与另一端客户端的同名实现保持一致，改一边要同步另一边。
    static func merge(pinned: [AgentToolDefinition],
                      pinnedNames: Set<String>,
                      wire: [AgentRemoteToolSpec],
                      identity: String,
                      onCollision: (String) -> Void = { _ in }) -> [AgentToolDefinition] {
        var out = pinned
        for spec in wire {
            if pinnedNames.contains(spec.name) {
                onCollision(spec.name)
                continue
            }
            guard spec.isAllowed(for: identity) else { continue }
            out.append(spec.definition)
        }
        return out
    }
}

// MARK: - 下发内容的缓存

/// 按身份缓存下发的工具集。
///
/// **永远不阻塞对话**：取不到就用缓存，没缓存就只有钉死的那批 ——
/// AI 照常能聊，只是少几个工具。这是一条硬规则，别为了「保证拿到最新」去等。
public actor AIWireToolCatalog {

    public static let shared = AIWireToolCatalog()

    /// 缓存有效期。取不到新的就继续用旧的，所以这个值偏保守没有代价。
    static let ttl: TimeInterval = 30 * 60

    private var cache: [String: [AgentRemoteToolSpec]] = [:]
    private var fetchedAt: [String: Date] = [:]
    private var inFlight: [String: Task<[AgentRemoteToolSpec], Never>] = [:]

    private let defaults = UserDefaults.standard
    private func storeKey(_ identity: String) -> String { "ai.wireTools.\(identity)" }

    /// 当前身份可用的下发工具。
    ///
    /// 内存有且新鲜 → 直接给；否则拉一次（同身份并发只拉一次）；
    /// 拉失败 → 落盘缓存 → 空。任何一步都不抛。
    public func tools(for identity: String) async -> [AgentRemoteToolSpec] {
        if let cached = cache[identity],
           let at = fetchedAt[identity],
           Date().timeIntervalSince(at) < Self.ttl {
            return cached
        }
        if let running = inFlight[identity] { return await running.value }

        let task = Task<[AgentRemoteToolSpec], Never> { [identity] in
            await self.fetch(identity)
        }
        inFlight[identity] = task
        let result = await task.value
        inFlight[identity] = nil
        return result
    }

    private func fetch(_ identity: String) async -> [AgentRemoteToolSpec] {
        do {
            let dto: WireSchemaDTO = try await APIClient.shared
                .get("/ai/tools/schema?identity=\(identity)")
            let specs = dto.tools.map { $0.toSpec() }
            cache[identity] = specs
            fetchedAt[identity] = Date()
            persist(dto, identity: identity)
            return specs
        } catch {
            AppLogger.ai.debug("下发工具拉取失败，回落缓存: \(error.localizedDescription)")
            // 拉不到就用上一次的 —— 离线冷启动仍有工具可用
            let restored = restore(identity)
            cache[identity] = restored
            // 刻意**不**更新 fetchedAt：下一次调用还会再试一次
            return restored
        }
    }

    private func persist(_ dto: WireSchemaDTO, identity: String) {
        guard let data = try? JSONEncoder().encode(dto) else { return }
        defaults.set(data, forKey: storeKey(identity))
    }

    private func restore(_ identity: String) -> [AgentRemoteToolSpec] {
        guard let data = defaults.data(forKey: storeKey(identity)),
              let dto = try? JSONDecoder().decode(WireSchemaDTO.self, from: data)
        else { return [] }
        return dto.tools.map { $0.toSpec() }
    }

    /// 登出 / 切账号时清 —— 下一个账号的身份集可能不同。
    public func reset() {
        cache.removeAll()
        fetchedAt.removeAll()
        for identity in ["consumer", "agent", "merchant"] {
            defaults.removeObject(forKey: storeKey(identity))
        }
    }

    /// 仅供测试注入，绕开网络。
    func seedForTesting(_ specs: [AgentRemoteToolSpec], identity: String) {
        cache[identity] = specs
        fetchedAt[identity] = Date()
    }
}
