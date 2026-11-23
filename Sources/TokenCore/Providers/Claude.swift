import Foundation

/// Asks Anthropic for the plan's limits with a sign-in already on this Mac: Claude Code's own OAuth
/// token, or the Claude desktop app's when the user has allowed that. Tokens are only ever sent to
/// api.anthropic.com and never refreshed here (refreshing would rotate the owner's refresh token
/// from under it).
public enum ClaudeLimits {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let keychainService = "Claude Code-credentials"

    struct Credentials {
        var accessToken: String
        var expiresAt: Date?
        /// Claude Code treats a sign-in without scopes as signed out and won't renew it. That's what
        /// sessions started by the desktop app leave behind.
        var isRenewable = true

        var isLive: Bool { self.expiresAt.map { $0 > Date() } ?? true }
    }

    /// Tries, in order: Claude Code's sign-in while it's valid, the desktop app's (`desktop`), then
    /// having Claude Code renew its own (`mayRenew`, only for fetches the user asked for).
    ///
    /// Throws `.signedOut` when nothing on this Mac can be renewed, `.needsKey` when the desktop
    /// app's sign-in is waiting for the user's OK in the Keychain, `.expired` otherwise.
    public static func fetch(mayRenew: Bool = false, desktop: ClaudeDesktop.Access = .off) async throws(LimitsError) -> PlanLimits {
        let cli = self.readCredentials()
        if let cli, cli.isLive {
            do throws(LimitsError) {
                return try await self.fetch(token: cli.accessToken)
            } catch {
                guard error == .expired else { throw error }
            }
        }
        var needsApproval = false
        if desktop != .off {
            do throws(LimitsError) {
                return try await self.fetchWithDesktopApp(desktop)
            } catch {
                switch error {
                case .needsKey: needsApproval = true
                case .expired, .signedOut: break
                default: throw error
                }
            }
        }
        if mayRenew, cli?.isRenewable == true, await ClaudeRenewal.shared.renew(), let renewed = self.readCredentials() {
            return try await self.fetch(token: renewed.accessToken)
        }
        if needsApproval { throw .needsKey }
        throw cli?.isRenewable == true || desktop != .off ? .expired : .signedOut
    }

    /// Has Claude Code renew its sign-in now (tokbench). True when the Keychain holds a fresh one.
    public static func renewSignIn() async -> Bool {
        await ClaudeRenewal.shared.renew()
    }

    /// The token that last worked is kept (in our own Keychain item), so the desktop app's storage
    /// is only opened again when that one stops working.
    private static func fetchWithDesktopApp(_ access: ClaudeDesktop.Access) async throws(LimitsError) -> PlanLimits {
        if let cached = Secrets.get(.claudeDesktopToken) {
            do throws(LimitsError) {
                return try await self.fetch(token: cached)
            } catch {
                guard error == .expired else { throw error }
                Secrets.set(.claudeDesktopToken, nil)
            }
        }
        switch ClaudeDesktop.accessTokens(access) {
        case .unavailable: throw .signedOut
        case .needsApproval: throw .needsKey
        case let .tokens(tokens):
            for token in tokens.prefix(4) {
                do throws(LimitsError) {
                    let limits = try await self.fetch(token: token)
                    Secrets.set(.claudeDesktopToken, token)
                    return limits
                } catch {
                    guard error == .expired else { throw error }
                }
            }
            throw .expired
        }
    }

    private static func fetch(token: String) async throws(LimitsError) -> PlanLimits {
        let json = try await HTTP.json(self.endpoint, headers: [
            "Authorization": "Bearer \(token)",
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

    static func keychainItem() -> Data? {
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
        let scopes = oauth["scopes"] as? [Any] ?? []
        return Credentials(accessToken: token, expiresAt: expiry, isRenewable: !scopes.isEmpty)
    }
}
