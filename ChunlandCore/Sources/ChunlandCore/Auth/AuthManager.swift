import Foundation
import Security

// MARK: - Keychain helpers

private enum Keychain {
    static func save(_ value: String, forKey key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrAccount as String:      key,
            kSecAttrService as String:      "com.chunland.app",
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func load(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrAccount as String:      key,
            kSecAttrService as String:      "com.chunland.app",
            kSecReturnData as String:       true,
            kSecMatchLimit as String:       kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.chunland.app",
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// 暴露给 AuthManager.init 的 nonisolated 闭包用 —— 避免 @MainActor 隔离阻碍同步注入
private enum AuthKeys {
    static let accessToken  = "access_token"
    static let refreshToken = "refresh_token"
    static let userId       = "user_id"
    static let roles          = "user_roles"
    static let activeIdentity = "active_identity"
    static let aiApiKey       = "ai_api_key"
}

// MARK: - AuthManager

@MainActor
public final class AuthManager: ObservableObject {
    public static let shared = AuthManager()

    @Published public var isLoggedIn: Bool = false
    @Published public var currentUserId: String?
    @Published public var roles: [String] = []
    /// 当前活跃身份（"consumer" / "agent"）。始终落在 roles 内，驱动 MainTabView 选哪套布局。
    @Published public var activeIdentity: String = "consumer"

    private let api = APIClient.shared

    public init() {
        let stored = Keychain.load(forKey: AuthKeys.userId)
        currentUserId = stored
        isLoggedIn = stored != nil
        // 恢复缓存的 roles，避免启动瞬间 tab 闪烁
        if let s = Keychain.load(forKey: AuthKeys.roles), !s.isEmpty {
            roles = s.split(separator: ",").map(String.init)
        }
        // 恢复并规整活跃身份（必须落在 roles 内，否则回退）
        reconcileActiveIdentity(preferred: Keychain.load(forKey: AuthKeys.activeIdentity))

        // 同步注入 token providers —— 避免启动竞态
        // Keychain.load 不需要 actor 隔离，闭包 nonisolated 即可
        APIClient.shared.setTokenProvider {
            Keychain.load(forKey: AuthKeys.accessToken)
        }
        APIClient.shared.setTokenRefresher { [weak self] in
            guard let self else { throw APIError.unauthorized }
            do {
                try await self.refreshTokens()
            } catch {
                // refresh token 也过期了 → 强制登出，UI 跳回 AuthView
                await MainActor.run { self.logout() }
                throw APIError.unauthorized
            }
            guard let token = Keychain.load(forKey: AuthKeys.accessToken) else {
                await MainActor.run { self.logout() }
                throw APIError.unauthorized
            }
            return token
        }

        // 启动时若已登录，拉一次 /me 把 roles 拿到最新（providers 已注入，可直接调）
        Task {
            if Keychain.load(forKey: AuthKeys.accessToken) != nil {
                if let me = try? await AuthService.shared.me() {
                    await MainActor.run {
                        self.roles = me.roles
                        Keychain.save(me.roles.joined(separator: ","), forKey: AuthKeys.roles)
                        self.reconcileActiveIdentity()
                    }
                }
            }
        }
    }

    // MARK: - Token access

    public var accessToken: String? { Keychain.load(forKey: AuthKeys.accessToken) }
    public var refreshToken: String? { Keychain.load(forKey: AuthKeys.refreshToken) }

    // AI API key — stored entirely on device, never sent to our server
    public var aiApiKey: String? {
        get { Keychain.load(forKey: AuthKeys.aiApiKey) }
        set {
            if let v = newValue { Keychain.save(v, forKey: AuthKeys.aiApiKey) }
            else { Keychain.delete(forKey: AuthKeys.aiApiKey) }
        }
    }

    // MARK: - Auth actions

    public func register(phone: String? = nil, email: String? = nil, password: String, role: String = "consumer") async throws {
        struct Body: Encodable { let phone: String?; let email: String?; let password: String; let role: String }
        let result: AuthResult = try await api.post("/auth/register", body: Body(phone: phone, email: email, password: password, role: role))
        persist(result)
    }

    public func login(phone: String? = nil, email: String? = nil, password: String) async throws {
        struct Body: Encodable { let phone: String?; let email: String?; let password: String }
        let result: AuthResult = try await api.post("/auth/login", body: Body(phone: phone, email: email, password: password))
        persist(result)
    }

    // MARK: - OTP（验证码登录/注册，主路径）

    /// 申请验证码。channel: "sms" | "email"。返回 cooldown / expiresIn 给 UI 做倒计时。
    public func sendOtp(channel: String, target: String, purpose: String = "login") async throws -> OtpSendResult {
        struct Body: Encodable { let channel: String; let target: String; let purpose: String }
        return try await api.post("/auth/otp/send", body: Body(channel: channel, target: target, purpose: purpose))
    }

    /// 校验验证码 → 服务端 find-or-create（默认 consumer）→ 落 token。无账号即自动注册。
    public func loginWithOtp(channel: String, target: String, code: String) async throws {
        struct Body: Encodable { let channel: String; let target: String; let code: String }
        let result: AuthResult = try await api.post("/auth/otp/login", body: Body(channel: channel, target: target, code: code))
        persist(result)
    }

    // MARK: - 密码重置 / 设置

    /// 忘记密码（未登录）：验证码（purpose=reset，先经 sendOtp(purpose:"reset") 发码）+ 设新密码 → 自动登录。
    public func resetPassword(channel: String, target: String, code: String, newPassword: String) async throws {
        struct Body: Encodable { let channel: String; let target: String; let code: String; let newPassword: String }
        let result: AuthResult = try await api.post("/auth/password/reset", body: Body(channel: channel, target: target, code: code, newPassword: newPassword))
        persist(result)
    }

    /// 设置/修改密码（已登录）。OTP 账号首次设密码时 oldPassword 传 nil。不换 token。
    public func setPassword(oldPassword: String?, newPassword: String) async throws {
        struct Body: Encodable { let oldPassword: String?; let newPassword: String }
        struct Result: Decodable { let ok: Bool; let hadPassword: Bool }
        let _: Result = try await api.post("/auth/password", body: Body(oldPassword: oldPassword, newPassword: newPassword))
    }

    // MARK: - 账户管理

    /// 绑定/换绑手机号或邮箱（已登录，OTP purpose=bind）。目标被占用时服务端报 409。
    public func bindContact(channel: String, target: String, code: String) async throws {
        struct Body: Encodable { let channel: String; let target: String; let code: String }
        let _: UserProfile = try await api.post("/auth/bind", body: Body(channel: channel, target: target, code: code))
    }

    /// 注销账号（软删 + 脱敏）。成功后本地登出，回到登录页。
    public func deleteAccount() async throws {
        try await api.deleteVoid("/auth/me")
        logout()
    }

    public func refreshTokens() async throws {
        guard let rt = refreshToken else { throw APIError.unauthorized }
        struct Body: Encodable { let refreshToken: String }
        struct Tokens: Decodable { let accessToken: String; let refreshToken: String }
        let tokens: Tokens = try await api.post("/auth/refresh", body: Body(refreshToken: rt))
        Keychain.save(tokens.accessToken, forKey: AuthKeys.accessToken)
        Keychain.save(tokens.refreshToken, forKey: AuthKeys.refreshToken)
    }

    public func logout() {
        Keychain.delete(forKey: AuthKeys.accessToken)
        Keychain.delete(forKey: AuthKeys.refreshToken)
        Keychain.delete(forKey: AuthKeys.userId)
        Keychain.delete(forKey: AuthKeys.roles)
        Keychain.delete(forKey: AuthKeys.activeIdentity)
        currentUserId = nil
        roles = []
        activeIdentity = "consumer"
        isLoggedIn = false
    }

    // MARK: - Multi-identity

    /// 切换当前活跃身份（仅当账号已拥有该角色）。纯本地状态，后端零感知。
    public func switchIdentity(to identity: String) {
        guard roles.contains(identity), identity != activeIdentity else { return }
        activeIdentity = identity
        Keychain.save(identity, forKey: AuthKeys.activeIdentity)
    }

    /// 为当前账号追加一个身份（开通买家 / 代购人）。
    /// 后端追加角色并重签 token；成功后自动切到新身份。
    public func addRole(_ role: String) async throws {
        struct Body: Encodable { let role: String }
        let result: AuthResult = try await api.post("/auth/roles", body: Body(role: role))
        persist(result)            // 存新 token + 更新 roles（reconcile 保留旧偏好）
        switchIdentity(to: role)   // 开通后落到新身份的视图
    }

    /// 开店（自建商家）：一步建店 + 授予 merchant 身份 + 重签 token，成功后切到商家视图。
    /// 走 /merchants/self 而非 /auth/roles —— merchant 身份必须随店铺一起创建。
    public func openMerchantStore(name: String, areaCode: String?) async throws {
        struct Body: Encodable { let name: String; let areaCode: String? }
        let result: AuthResult = try await api.post("/merchants/self", body: Body(name: name, areaCode: areaCode))
        persist(result)
        switchIdentity(to: "merchant")
    }

    // MARK: - Private

    private func persist(_ result: AuthResult) {
        Keychain.save(result.accessToken, forKey: AuthKeys.accessToken)
        Keychain.save(result.refreshToken, forKey: AuthKeys.refreshToken)
        Keychain.save(String(result.userId), forKey: AuthKeys.userId)
        let rs = result.roles ?? []
        Keychain.save(rs.joined(separator: ","), forKey: AuthKeys.roles)
        currentUserId = String(result.userId)
        roles = rs
        reconcileActiveIdentity()
        isLoggedIn = true
    }

    /// 规整「当前活跃身份」：必须落在 roles 内。
    /// 优先保留偏好（preferred 或当前值），否则回退 consumer，再否则 roles.first。
    /// 单角色时天然锁定到那个角色。
    private func reconcileActiveIdentity(preferred: String? = nil) {
        let pref = preferred ?? activeIdentity
        let resolved: String
        if roles.contains(pref) {
            resolved = pref
        } else if roles.contains("consumer") {
            resolved = "consumer"
        } else {
            resolved = roles.first ?? "consumer"
        }
        activeIdentity = resolved
        Keychain.save(resolved, forKey: AuthKeys.activeIdentity)
    }
}
