import Darwin
import Foundation

/// Asks the Codex CLI for its rate limits over `codex app-server` (JSON-RPC, one message per line),
/// the way CodexBar falls back when the saved sign-in has lapsed. Codex renews its own token while
/// answering, so `~/.codex/auth.json` is fresh again for the next direct fetch. Read-only sandbox,
/// never asks for approval, and no model is called.
actor CodexAppServer {
    static let shared = CodexAppServer()

    private var lastAttempt = Date.distantPast
    private var running: Task<PlanLimits?, Never>?

    func rateLimits() async -> PlanLimits? {
        if let running { return await running.value }
        // One launch per 20 seconds at most, whatever asks.
        guard Date().timeIntervalSince(self.lastAttempt) >= 20 else { return nil }
        self.lastAttempt = Date()
        let task = Task.detached(priority: .utility) { Self.read(timeout: 12).flatMap { CodexLimits.parse($0, now: Date()) } }
        self.running = task
        let result = await task.value
        self.running = nil
        return result
    }

    /// The limits in the same shape as chatgpt.com's `wham/usage`, or nil.
    private static func read(timeout: TimeInterval) -> [String: Any]? {
        guard let binary = CLITool.find("codex") else { return nil }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["-s", "read-only", "-a", "never", "app-server"]
        process.environment = CLITool.environment()
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                for _ in 0 ..< 10 where process.isRunning { usleep(100_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        let fd = output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let deadline = Date().addingTimeInterval(timeout)

        func send(_ message: [String: Any]) -> Bool {
            guard var data = try? JSONSerialization.data(withJSONObject: message) else { return false }
            data.append(0x0A)
            do { try input.fileHandleForWriting.write(contentsOf: data) } catch { return false }
            return true
        }
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        /// The reply to `id`, skipping notifications and other replies.
        func reply(_ id: Int) -> [String: Any]? {
            while Date() < deadline {
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = pending[pending.startIndex ..< newline]
                    pending.removeSubrange(pending.startIndex ... newline)
                    guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          JSONValue.number(message["id"]).map(Int.init) == id
                    else { continue }
                    return message["result"] as? [String: Any]
                }
                let count = Darwin.read(fd, &chunk, chunk.count)
                if count > 0 {
                    pending.append(contentsOf: chunk[0 ..< count])
                    if pending.count > 4_000_000 { return nil }
                } else if count == 0 || !process.isRunning {
                    return nil
                } else {
                    usleep(20000)
                }
            }
            return nil
        }

        guard send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "countyotokens", "version": "1"]]]),
              reply(1) != nil,
              send(["method": "initialized", "params": [:]]),
              send(["id": 2, "method": "account/rateLimits/read", "params": [:]]),
              let result = reply(2)
        else { return nil }
        return self.whamShape(result)
    }

    /// `{rateLimits: {primary: {usedPercent, windowDurationMins, resetsAt}, …}}` → `wham/usage`'s
    /// `{rate_limit: {primary_window: {used_percent, limit_window_seconds, reset_at}}}`.
    static func whamShape(_ result: [String: Any]) -> [String: Any]? {
        func value(_ entry: [String: Any], _ camel: String, _ snake: String) -> Any? { entry[camel] ?? entry[snake] }
        func window(_ raw: Any?) -> [String: Any]? {
            guard let raw = raw as? [String: Any], let used = JSONValue.number(value(raw, "usedPercent", "used_percent")) else { return nil }
            var window: [String: Any] = ["used_percent": used]
            if let minutes = JSONValue.number(value(raw, "windowDurationMins", "window_minutes")) { window["limit_window_seconds"] = minutes * 60 }
            if let reset = JSONValue.number(value(raw, "resetsAt", "resets_at")) { window["reset_at"] = reset }
            return window
        }
        func rateLimit(_ snapshot: [String: Any]) -> [String: Any] {
            var limit: [String: Any] = [:]
            limit["primary_window"] = window(snapshot["primary"])
            limit["secondary_window"] = window(snapshot["secondary"])
            return limit
        }
        guard let main = (result["rateLimits"] ?? result["rate_limits"]) as? [String: Any] else { return nil }
        var json: [String: Any] = ["rate_limit": rateLimit(main)]
        if let plan = JSONValue.string(value(main, "planType", "plan_type")) { json["plan_type"] = plan }
        let mainID = JSONValue.string(value(main, "limitId", "limit_id"))
        let byID = (result["rateLimitsByLimitId"] ?? result["rate_limits_by_limit_id"]) as? [String: Any] ?? [:]
        json["additional_rate_limits"] = byID.keys.sorted().compactMap { key -> [String: Any]? in
            guard key != mainID, key != "codex", let snapshot = byID[key] as? [String: Any] else { return nil }
            let name = JSONValue.string(value(snapshot, "limitName", "limit_name")) ?? key
            return ["limit_name": name, "rate_limit": rateLimit(snapshot)]
        }
        return json
    }
}
