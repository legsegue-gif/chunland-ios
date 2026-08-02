import Foundation

/// 举报对象类型（与服务端 target_type 对齐）。
public enum ReportTargetType: String, Sendable {
    case feedItem = "feed_item"
    case product
    case agent
    case order
    case aiMessage = "ai_message"
    case general
}

/// 举报理由（与服务端 reason_code 对齐）。
public enum ReportReason: String, CaseIterable, Identifiable, Sendable {
    case illegal
    case fraud
    case porn
    case infringement
    case harassment
    case other

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .illegal:      return "违法违禁"
        case .fraud:        return "虚假欺诈"
        case .porn:         return "色情低俗"
        case .infringement: return "侵权"
        case .harassment:   return "骚扰辱骂"
        case .other:        return "其他"
        }
    }
}
