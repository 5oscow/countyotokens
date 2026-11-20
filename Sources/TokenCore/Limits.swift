import Foundation

/// The plan's rate limits as Anthropic reports them: the 5-hour session, the weekly limit, and any
/// model-scoped weekly limits (Fable). Percentages are "used", 0–100.
public struct PlanLimits: Codable, Equatable, Sendable {
    public struct Limit: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var usedPercent: Double
        public var resetsAt: Date?

        public var leftPercent: Double { min(100, max(0, 100 - self.usedPercent)) }
    }

    public var session: Limit?
    public var weekly: Limit?
    public var scoped: [Limit]
    public var fetchedAt: Date

    public var all: [Limit] { [self.session, self.weekly].compactMap(\.self) + self.scoped }

    public static func placeholder() -> PlanLimits {
        PlanLimits(
            session: Limit(id: "session", title: "Session", usedPercent: 0, resetsAt: nil),
            weekly: Limit(id: "weekly", title: "Weekly", usedPercent: 0, resetsAt: nil),
            scoped: [],
            fetchedAt: .distantPast)
    }

    static var cacheURL: URL { AppPaths.support.appendingPathComponent("limits.json") }

    public static func loadCached() -> PlanLimits? {
        guard let data = try? Data(contentsOf: self.cacheURL) else { return nil }
        return try? JSONDecoder().decode(PlanLimits.self, from: data)
    }

    public func saveCache() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
        try? data.write(to: Self.cacheURL, options: .atomic)
    }
}

public enum LimitsError: Error, Equatable, Sendable {
    /// No Claude Code sign-in found on this Mac.
    case signedOut
    /// The token was rejected (expired); Claude Code renews it next time it runs.
    case expired
    case rateLimited(retryAfter: TimeInterval)
    case failed
}

/// Reads Claude Code's own OAuth token and asks Anthropic for the plan's limits. The token is only
/// ever sent to api.anthropic.com, never stored, logged or refreshed here (refreshing would rotate
/// Claude Code's refresh token from under it).
public enum LimitsClient {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let keychainService = "Claude Code-credentials"

    struct Credentials {
        var accessToken: String
        var expiresAt: Date?
    }

    public static func fetch() async throws(LimitsError) -> PlanLimits {
        guard let credentials = self.readCredentials() else { throw .signedOut }
        if let expiry = credentials.expiresAt, expiry < Date() { throw .expired }

        var request = URLRequest(url: self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-cli/2.1.0 (external, cli)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.session.data(for: request)
        } catch {
            throw .failed
        }
        guard let http = response as? HTTPURLResponse else { throw .failed }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw .expired
        case 429:
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 300
            throw .rateLimited(retryAfter: max(60, retry))
        default: throw .failed
        }
        guard let limits = self.parse(data, now: Date()) else { throw .failed }
        return limits
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    // MARK: Parsing

    static func parse(_ data: Data, now: Date) -> PlanLimits? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func window(_ key: String, id: String, title: String) -> PlanLimits.Limit? {
            guard let entry = json[key] as? [String: Any], let used = self.number(entry["utilization"]) else { return nil }
            return PlanLimits.Limit(id: id, title: title, usedPercent: used, resetsAt: self.date(entry["resets_at"]))
        }
        var scoped: [PlanLimits.Limit] = []
        for case let entry as [String: Any] in json["limits"] as? [Any] ?? [] {
            guard entry["group"] as? String == "weekly", entry["kind"] as? String == "weekly_scoped",
                  let used = self.number(entry["percent"]),
                  let model = (entry["scope"] as? [String: Any])?["model"] as? [String: Any],
                  let name = (model["display_name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty
            else { continue }
            let id = "weekly-" + ((model["id"] as? String) ?? name).lowercased()
            guard !scoped.contains(where: { $0.id == id }) else { continue }
            scoped.append(PlanLimits.Limit(id: id, title: "\(name) weekly", usedPercent: used, resetsAt: self.date(entry["resets_at"])))
        }
        let limits = PlanLimits(
            session: window("five_hour", id: "session", title: "Session"),
            weekly: window("seven_day", id: "weekly", title: "Weekly"),
            scoped: scoped,
            fetchedAt: now)
        return limits.all.isEmpty ? nil : limits
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    // MARK: Credentials

    /// Claude Code keeps its sign-in in the login Keychain, written with `/usr/bin/security`. Reading it
    /// through the same tool matches the item's access list, so macOS doesn't prompt.
    static func readCredentials() -> Credentials? {
        if let data = self.keychainItem(), let credentials = self.parseCredentials(data) { return credentials }
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
              let token = (oauth["accessToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { return nil }
        let expiry = self.number(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Credentials(accessToken: token, expiresAt: expiry)
    }
}
