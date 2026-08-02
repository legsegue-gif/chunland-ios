import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 客户端基础遥测，拼成 `X-Client-Info` header 随每个请求发出。
/// 服务端 requestAudit 中间件解析 `key=value; …` 落 api_request_logs 的 app/os/device 列。
/// 只含 app 版本 / 系统版本 / 机型 —— 标准遥测，无隐私敏感数据。
enum ClientInfo {
    /// 形如 `app=1.0.3; build=12; os=iOS 17.4; model=iPhone16,2`。进程内只算一次。
    static let headerValue: String = {
        var parts: [String] = []
        if let app = bundleString("CFBundleShortVersionString") { parts.append("app=\(app)") }
        if let build = bundleString("CFBundleVersion") { parts.append("build=\(build)") }
        parts.append("os=\(osString)")
        parts.append("model=\(deviceModel)")
        return parts.joined(separator: "; ")
    }()

    private static func bundleString(_ key: String) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespaces)
            .nilIfEmpty
    }

    private static var osString: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let base = v.patchVersion > 0
            ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
            : "\(v.majorVersion).\(v.minorVersion)"
        #if os(iOS)
        return "iOS \(base)"
        #elseif os(macOS)
        return "macOS \(base)"
        #else
        return base
        #endif
    }

    /// 硬件标识（真机 `iPhone16,2`）。模拟器优先取被模拟机型，否则回退 uname machine。
    private static var deviceModel: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafeBytes(of: &sysinfo.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return machine.nilIfEmpty ?? "unknown"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
