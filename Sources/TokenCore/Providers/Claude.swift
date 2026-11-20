import Foundation

/// Reads Claude Code's own OAuth token and asks Anthropic for the plan's limits. The token is only
/// ever sent to api.anthropic.com, never stored, logged or refreshed here (refreshing would rotate
/// Claude Code's refresh token from under it).
public enum ClaudeLimits {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let keychainService = "Claude Code-credentials"

    struct Credentials {
        var accessToken: String
        var expiresAt: Date?
    }

    public static func fetch() async throws(LimitsError) -> PlanLimits {
        guard let credentials = self.readCredentials() else { throw .signedOut }
        if let expiry = credentials.expiresAt, expiry < Date() { throw .expired }
        let json = try await HTTP.json(self.endpoint, headers: [
            "Authorization": "Bearer \(credentials.accessToken)",
            "Content-Type": "application/json",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-cli/2.1.0 (external, cli)",
        ])
        guard let limits = self.parse(json, now: Date()) else { throw .failed }
        return limits
    }

    static func parse(_ json: [String: Any], now: Date) -> PlanLimits? {
        func window(_ key: String, id: String, title: String, duration: TimeInterval) -> PlanLimits.Limit? {
            guard let entry = json[key] as? [String: Any], let used = JSONValue.number(entry["utilization"]) else { return nil }
            return PlanLimits.Limit(id: id, title: title, usedPercent: used, resetsAt: JSONValue.date(entry["resets_at"]), duration: duration)
        }
        var items = [
            window("five_hour", id: "session", title: "Session", duration: PlanLimits.Window.session),
            window("seven_day", id: "weekly", title: "Weekly", duration: PlanLimits.Window.week),
        ].compactMap(\.self)
        for case let entry as [String: Any] in json["limits"] as? [Any] ?? [] {
            guard entry["group"] as? String == "weekly", entry["kind"] as? String == "weekly_scoped",
                  let used = JSONValue.number(entry["percent"]),
                  let model = (entry["scope"] as? [String: Any])?["model"] as? [String: Any],
                  let name = JSONValue.string(model["display_name"])
            else { continue }
            let id = "weekly-" + (JSONValue.string(model["id"]) ?? name).lowercased()
            guard !items.contains(where: { $0.id == id }) else { continue }
            items.append(PlanLimits.Limit(
                id: id, title: "\(name) weekly", usedPercent: used,
                resetsAt: JSONValue.date(entry["resets_at"]), duration: PlanLimits.Window.week))
        }
        return items.isEmpty ? nil : PlanLimits(items: items, fetchedAt: now)
    }

    // MARK: Credentials

    /// Claude Code keeps its sign-in in the login Keychain, written with `/usr/bin/security`. Reading it
    /// through the same tool matches the item's access list, so macOS doesn't prompt.
    static func readCredentials() -> Credentials? {
        if let data = Self.keychainItem(), let credentials = self.parseCredentials(data) { return credentials }
        let root = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        guard let data = try? Data(contentsOf: root.appendingPathComponent(".credentials.json")) else { return nil }
        return self.parseCredentials(data)
    }

    private static func keychainItem() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", self.keychainService, "-a", NSUserName(), "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    static func parseCredentials(_ data: Data) -> Credentials? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = JSONValue.string(oauth["accessToken"])
        else { return nil }
        let expiry = JSONValue.number(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Credentials(accessToken: token, expiresAt: expiry)
    }
}
