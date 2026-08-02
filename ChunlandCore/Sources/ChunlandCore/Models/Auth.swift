import Foundation

public struct AuthResult: Decodable, Sendable {
    public let userId: Int
    public let roles: [String]?
    public let accessToken: String
    public let refreshToken: String
}

/// 验证码申请结果。cooldown 驱动「X 秒后重发」倒计时；expiresIn 是验证码有效期。
public struct OtpSendResult: Decodable, Sendable {
    public let cooldown: Int
    public let expiresIn: Int
}

public struct UserProfile: Decodable, Identifiable, Sendable {
    public let id: Int
    public let phone: String?
    public let email: String?
    public let isPhoneVerified: Bool
    public let isEmailVerified: Bool
    public let hasPassword: Bool      // 是否已设密码（OTP 注册账号为 false）→ 决定「设置」vs「修改」
    public let roles: [String]
    public let createdAt: String
}
