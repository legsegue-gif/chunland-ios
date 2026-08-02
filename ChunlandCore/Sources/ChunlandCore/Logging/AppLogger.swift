import Foundation
import OSLog

// AppLogger —— OSLog 包装，提供四级日志 + 预定义 category。
//
// 命名为 AppLogger 而非 Logger，避免与 OSLog 的 `Logger` 冲突。
//
// 使用：
//   AppLogger.network.info("request.start", metadata: ["path": path])
//   AppLogger.auth.error(error)
//
// 未来若要切换到 swift-log 或自建结构化日志，仅替换本文件实现即可。
public struct AppLogger: Sendable {
    public let subsystem: String
    public let category: String
    private let osLog: os.Logger

    public init(subsystem: String, category: String) {
        self.subsystem = subsystem
        self.category = category
        self.osLog = os.Logger(subsystem: subsystem, category: category)
    }

    public func debug(_ message: String, metadata: [String: String] = [:]) {
        osLog.debug("\(format(message, metadata), privacy: .public)")
    }

    public func info(_ message: String, metadata: [String: String] = [:]) {
        osLog.info("\(format(message, metadata), privacy: .public)")
    }

    public func warn(_ message: String, metadata: [String: String] = [:]) {
        osLog.warning("\(format(message, metadata), privacy: .public)")
    }

    public func error(_ message: String, metadata: [String: String] = [:]) {
        osLog.error("\(format(message, metadata), privacy: .public)")
    }

    public func error(_ error: Error, metadata: [String: String] = [:]) {
        var meta = metadata
        meta["error"] = String(describing: error)
        osLog.error("\(format("error", meta), privacy: .public)")
    }

    private func format(_ message: String, _ metadata: [String: String]) -> String {
        guard !metadata.isEmpty else { return message }
        let pairs = metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        return "\(message) \(pairs)"
    }
}

public extension AppLogger {
    static let subsystem = "com.chunland.app"

    static let network = AppLogger(subsystem: subsystem, category: "network")
    static let auth    = AppLogger(subsystem: subsystem, category: "auth")
    static let ai      = AppLogger(subsystem: subsystem, category: "ai")
    static let app     = AppLogger(subsystem: subsystem, category: "app")
}
