import Foundation

/// Devin's daily and weekly quota from app.devin.ai. The token is the Devin CLI's own sign-in
/// (`~/.local/share/devin/credentials.toml`) unless one is pasted into Settings; the organization
/// comes from Settings or the CLI's config. No browser or Keychain access needed.
public enum DevinLimits {
    public static func fetch(token rawToken: String?, organization rawOrganization: String?) async throws(LimitsError) -> PlanLimits {
        let environment = ProcessInfo.processInfo.environment
        // An explicit token first, then the CLI's: a stale pasted token falls through to a live sign-in.
        var tokens: [String] = []
        for raw in [environment["DEVIN_BEARER_TOKEN"] ?? environment["DEVIN_AUTHORIZATION"], rawToken, self.cliToken()] {
            if let token = self.normalizeToken(raw), !tokens.contains(token) { tokens.append(token) }
        }
        guard !tokens.isEmpty,
              let organization = self.normalizeOrganization(environment["DEVIN_ORGANIZATION"] ?? rawOrganization ?? self.cliOrganization())
        else { throw .needsKey }

        var lastError = LimitsError.failed
        for token in tokens {
            do throws(LimitsError) {
                return try await self.fetch(token: token, organization: organization)
            } catch {
                lastError = error
                guard error == .expired else { throw error }
            }
        }
        throw lastError
    }

    private static func fetch(token: String, organization: Organization) async throws(LimitsError) -> PlanLimits {
        var headers = [
            "Authorization": "Bearer \(token)",
            "Accept-Language": "en-US,en;q=0.9",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
        ]
        if let orgID = organization.internalID { headers["x-cog-org-id"] = orgID }

        var lastError = LimitsError.failed
        for path in organization.paths {
            guard let url = URL(string: "https://app.devin.ai/api/\(path)/billing/quota/usage") else { continue }
            do throws(LimitsError) {
                let json = try await HTTP.json(url, headers: headers)
                guard let limits = self.parse(json, now: Date()) else { throw LimitsError.failed }
                return limits
            } catch {
                // A rejected token is final; a wrong path (404) moves on to the next form.
                switch error {
                case .expired, .rateLimited: throw error
                default: break
                }
                lastError = error
            }
        }
        throw lastError
    }

    static func parse(_ json: [String: Any], now: Date) -> PlanLimits? {
        func percent(_ value: Any?) -> Double? {
            guard let raw = JSONValue.number(value) else { return nil }
            return min(100, max(0, raw < 1 ? raw * 100 : raw))
        }
        let hideDaily = (json["hide_daily_quota"] as? Bool) == true
        var items: [PlanLimits.Limit] = []
        if !hideDaily, let used = percent(json["daily_percentage"]) {
            items.append(.init(id: "daily", title: "Daily", usedPercent: used,
                               resetsAt: JSONValue.date(json["daily_reset_at"]), duration: PlanLimits.Window.day))
        }
        if let used = percent(json["weekly_percentage"]) {
            items.append(.init(id: "weekly", title: "Weekly", usedPercent: used,
                               resetsAt: JSONValue.date(json["weekly_reset_at"]), duration: PlanLimits.Window.week))
        }
        guard !items.isEmpty else { return nil }
        let planKeys = ["plan_name", "planName", "plan", "tier", "subscription_tier", "subscriptionTier"]
        let plan = planKeys.lazy.compactMap { JSONValue.string(json[$0]) }.first.map { name in
            name.split(whereSeparator: { $0 == "_" || $0 == "-" }).map(\.capitalized).joined(separator: " ")
        }
        return PlanLimits(items: items, plan: plan, fetchedAt: now)
    }

    /// Accepts `abc`, `Bearer abc` or a whole `Authorization: Bearer abc` header line.
    static func normalizeToken(_ raw: String?) -> String? {
        guard var token = JSONValue.string(raw) else { return nil }
        if token.lowercased().hasPrefix("authorization:") { token = String(token.dropFirst("authorization:".count)).trimmingCharacters(in: .whitespaces) }
        if token.lowercased().hasPrefix("bearer ") { token = String(token.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces) }
        return token.isEmpty ? nil : token
    }

    struct Organization {
        var internalID: String?
        var paths: [String]
    }

    /// An internal `org_…`/`org-…` ID, a slug, or a devin.ai URL holding either.
    static func normalizeOrganization(_ raw: String?) -> Organization? {
        guard var value = JSONValue.string(raw) else { return nil }
        if let url = URL(string: value), url.host?.hasSuffix("devin.ai") == true {
            let parts = url.path.split(separator: "/").map(String.init)
            if let index = parts.firstIndex(where: { $0 == "org" || $0 == "organizations" }), index + 1 < parts.count {
                value = parts[index + 1]
            }
        }
        if value.hasPrefix("org_") || value.hasPrefix("org-") {
            return Organization(internalID: value, paths: [value, "organizations/\(value)"])
        }
        return Organization(internalID: nil, paths: ["org/\(value)", value])
    }

    /// The session token the Devin CLI signed in with (`devin auth login`).
    public static func cliToken() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/devin/credentials.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "windsurf_api_key" else { continue }
            return JSONValue.string(parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")))
        }
        return nil
    }

    /// The organization the Devin CLI was set up with (`~/.config/devin/config.json`).
    public static func cliOrganization() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/devin/config.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devin = json["devin"] as? [String: Any]
        else { return nil }
        return JSONValue.string(devin["org_id"])
    }
}
