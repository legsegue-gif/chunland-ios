#if DEBUG
import Foundation

// AI 对话调试日志 —— 仅 DEBUG 编译存在，Release（TestFlight / App Store）整段代码物理不存在，
// 不产生任何文件 IO，正式包不落一行日志。
//
// 落盘到沙盒 Caches/ai-debug.log，格式：
// `[ts] LEVEL msg {compact json}`，本地模拟器调试时可直接 tail 查看完整请求/响应。
// 因为整段只在本机 DEBUG 编译存在、不进正式包，记录完整对话内容（不像 server 端日志需脱 body）。
public enum AIDebugFileLog {
    /// 日志文件路径 —— 供「开发者」页分享/清空按钮用。访问即会（幂等）确保文件存在。
    public static let fileURL: URL? = {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let url = dir.appendingPathComponent("ai-debug.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        return url
    }()

    private static func ts() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    private static func fmt(_ extra: [String: Any]) -> String {
        guard !extra.isEmpty,
              JSONSerialization.isValidJSONObject(extra),
              let data = try? JSONSerialization.data(withJSONObject: extra),
              let json = String(data: data, encoding: .utf8)
        else { return "" }
        return " \(json)"
    }

    // 打终端（print，Xcode 控制台可见）+ 追加落盘。落盘失败静默吞掉 —— 日志不该成为业务故障源。
    private static func emit(_ level: String, _ msg: String, _ extra: [String: Any]) {
        let line = "[\(ts())] \(level) \(msg)\(fmt(extra))"
        print(line)
        guard let fileURL, let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// 发起请求前记录：model / 工具列表 / 完整历史（按 domain 形状序列化）。
    static func request(model: String, toolNames: [String], messages: [AgentMessage]) {
        emit("INFO ", "ai.request", [
            "model": model,
            "tools": toolNames,
            "messages": messages.map(describe),
        ])
    }

    /// 一轮结束时记录：结束原因 + 本轮产出。
    static func response(outcome: String, text: String?, toolNames: [String] = [], detail: String? = nil) {
        var extra: [String: Any] = ["outcome": outcome]
        if let text, !text.isEmpty { extra["text"] = text }
        if !toolNames.isEmpty { extra["toolCalls"] = toolNames }
        if let detail { extra["detail"] = detail }
        emit("INFO ", "ai.response", extra)
    }

    /// domain 消息 → 可读结构。不落图片字节，只记引用（日志不该变成图床）。
    private static func describe(_ message: AgentMessage) -> [String: Any] {
        var parts: [[String: Any]] = []
        for part in message.parts {
            switch part {
            case .text(let t):
                parts.append(["kind": "text", "text": t])
            case .toolUse(let id, let name, let input):
                parts.append(["kind": "tool_use", "id": id, "name": name,
                              "input": input.jsonString()])
            case .toolResult(let id, let name, let text, let isError, _, let offloadRef):
                var entry: [String: Any] = ["kind": "tool_result", "id": id,
                                            "name": name, "isError": isError, "text": text]
                if let offloadRef { entry["offloadRef"] = offloadRef }
                parts.append(entry)
            case .image(let ref):
                parts.append(["kind": "image", "sha256": ref.sha256, "bytes": ref.bytes])
            }
        }
        var out: [String: Any] = ["role": message.role.rawValue, "parts": parts]
        if message.isInterrupted { out["interrupted"] = true }
        if let reasoning = message.reasoning { out["reasoning"] = reasoning }
        return out
    }

    /// 清空日志内容（截断为 0 字节，文件本身保留）。「开发者」页清空按钮用。
    public static func clear() {
        guard let fileURL else { return }
        try? Data().write(to: fileURL, options: .atomic)
    }
}
#endif
