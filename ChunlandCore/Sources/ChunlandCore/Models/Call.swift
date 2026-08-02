import Foundation

// 音视频通话 wire 模型（买家 ↔ 代购人）。契约与服务端通话信令约定对应。
// 边界：媒体走 TRTC（UserSig 服务端签发），SDKAppID 由服务端下发（不硬编码）；信令类型见 CallSignalType。
// ⚠️ ChunlandCore 只管「取凭证/发起」的网络层，不 import 任何音视频 SDK —— 引擎在 app 层。

/// 通话媒体类型
public enum CallMedia: String, Sendable, Codable {
    case audio
    case video
}

/// 通话信令类型（IM 信令 payload.type / 推送 data.signal，真相源在服务端）。
/// iOS 主要靠推送投递 INVITE + 房间事件驱动接听/挂断；显式信令为增强路径。
public enum CallSignalType {
    public static let invite = 200
    public static let accept = 201
    public static let reject = 202
    public static let cancel = 203
    public static let hangup = 204
    public static let busy   = 205
}

/// POST /calls/sig —— 当前用户进房凭证（与房间无关，任意房可用）
public struct CallSigInfo: Decodable, Sendable {
    public let sdkAppId: Int
    public let userId: String
    public let userSig: String
    public let expireSeconds: Int?
}

/// POST /calls/invite —— 发起通话后主叫进房凭证（含房号 + 对端）
public struct CallInviteResult: Decodable, Sendable {
    public let roomId: String
    public let media: String
    public let sdkAppId: Int
    public let userId: String
    public let userSig: String
    public let expireSeconds: Int?
    public let peerUserId: Int?

    /// 媒体类型（未知值兜底 audio）
    public var mediaType: CallMedia { CallMedia(rawValue: media) ?? .audio }
}
