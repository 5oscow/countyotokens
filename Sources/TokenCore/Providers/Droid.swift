import Foundation

/// Factory (Droid) limits with an API key: token-rate-limit plans report 5-hour, weekly and monthly
/// windows; older plans report Standard and Premium token allowances for the billing period.
public enum DroidLimits {
    static let api = URL(string: "https://api.factory.ai")!
    static let app = URL(string: "https://app.factory.ai")!

    public static func fetch(apiKey: String?) async throws(LimitsError) -> PlanLimits {
        guard let key = JSONValue.string(apiKey) else { throw .needsKey }
        let headers = [
            "Authorization": "Bearer \(key)",
            "Content-Type": "application/json",
            "Origin": "https://app.factory.ai",
            "Referer": "https://app.factory.ai/",
            "x-factory-client": "web-app",
        ]
        let now = Date()
        let me = try await HTTP.json(self.api.appendingPathComponent("api/app/auth/me"), headers: headers)
        let plan = self.planName(me)

        if let billing = try? await HTTP.json(self.api.appendingPathComponent("api/billing/limits"), headers: headers),
           billing["usesTokenRateLimitsBilling"] as? Bool == true,
           let limits = self.parseTokenLimits(billing, now: now)
        {
            return PlanLimits(items: limits, plan: plan, fetchedAt: now)
        }

        var components = URLComponents(url: self.api.appendingPathComponent("api/organization/subscription/usage"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "useCache", value: "true")]
        if let user = JSONValue.string((me["userProfile"] as? [String: Any])?["id"]) {
            components.queryItems?.append(URLQueryItem(name: "userId", value: user))
        }
        let usage = try await HTTP.json(components.url!, headers: headers)
        guard let items = self.parseAllowances(usage) else { throw .failed }
        return PlanLimits(items: items, plan: plan, fetchedAt: now)
    }

    static func planName(_ me: [String: Any]) -> String? {
        let subscription = (me["organization"] as? [String: Any])?["subscription"] as? [String: Any]
        let plan = ((subscription?["orbSubscription"] as? [String: Any])?["plan"] as? [String: Any])?["name"]
        return JSONValue.string(plan) ?? JSONValue.string(subscription?["factoryTier"]).map(\.capitalized)
    }

    static func parseTokenLimits(_ billing: [String: Any], now: Date) -> [PlanLimits.Limit]? {
        guard let limits = billing["limits"] as? [String: Any], let standard = limits["standard"] as? [String: Any] else { return nil }
        func window(_ pool: [String: Any], _ key: String, id: String, title: String, duration: TimeInterval) -> PlanLimits.Limit? {
            guard let entry = pool[key] as? [String: Any], let used = JSONValue.number(entry["usedPercent"]) else { return nil }
            var reset: Date?
            if let seconds = JSONValue.number(entry["secondsRemaining"]), seconds > 0 {
                reset = now.addingTimeInterval(seconds)
            } else if let end = JSONValue.date(entry["windowEnd"]), end > now {
                reset = end
            }
            // A short window past its end with no countdown has reset, whatever the stale figure says.
            let stale = reset == nil && entry["windowEnd"] != nil && entry["secondsRemaining"] == nil
            return .init(id: id, title: title, usedPercent: stale ? 0 : min(100, max(0, used)), resetsAt: reset, duration: duration)
        }
        var items = [
            window(standard, "fiveHour", id: "session", title: "5-hour", duration: PlanLimits.Window.session),
            window(standard, "weekly", id: "weekly", title: "Weekly", duration: PlanLimits.Window.week),
            window(standard, "monthly", id: "monthly", title: "Monthly", duration: PlanLimits.Window.month),
        ].compactMap(\.self)
        if let core = limits["core"] as? [String: Any] {
            let coreItems = [
                window(core, "fiveHour", id: "core-session", title: "Core 5-hour", duration: PlanLimits.Window.session),
                window(core, "weekly", id: "core-weekly", title: "Core weekly", duration: PlanLimits.Window.week),
                window(core, "monthly", id: "core-monthly", title: "Core monthly", duration: PlanLimits.Window.month),
            ].compactMap(\.self)
            if coreItems.contains(where: { $0.usedPercent > 0 || $0.resetsAt != nil }) { items += coreItems }
        }
        return items.isEmpty ? nil : items
    }

    static func parseAllowances(_ json: [String: Any]) -> [PlanLimits.Limit]? {
        guard let usage = json["usage"] as? [String: Any] else { return nil }
        let end = JSONValue.number(usage["endDate"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        let start = JSONValue.number(usage["startDate"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        let duration = start.flatMap { start in end.map { $0.timeIntervalSince(start) } }
        func pool(_ key: String, title: String) -> PlanLimits.Limit? {
            guard let entry = usage[key] as? [String: Any] else { return nil }
            var percent: Double?
            if let ratio = JSONValue.number(entry["usedRatio"]), ratio >= -0.001, ratio <= 1.001 {
                percent = ratio * 100
            } else if let used = JSONValue.number(entry["orgTotalTokensUsed"]) ?? JSONValue.number(entry["userTokens"]),
                      let allowance = JSONValue.number(entry["totalAllowance"]), allowance > 0
            {
                percent = used / allowance * 100
            }
            guard let percent else { return nil }
            return .init(id: key, title: title, usedPercent: min(100, max(0, percent)), resetsAt: end, duration: duration)
        }
        let items = [pool("standard", title: "Standard"), pool("premium", title: "Premium")].compactMap(\.self)
        return items.isEmpty ? nil : items
    }

    /// `FACTORY_API_KEY`, or the one in `~/.factory/.env`.
    public static func environmentKey() -> String? {
        if let key = JSONValue.string(ProcessInfo.processInfo.environment["FACTORY_API_KEY"]) { return key }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".factory/.env")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            var entry = line.trimmingCharacters(in: .whitespaces)
            if entry.hasPrefix("export ") { entry.removeFirst("export ".count) }
            guard entry.hasPrefix("FACTORY_API_KEY=") else { continue }
            let value = entry.dropFirst("FACTORY_API_KEY=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if !value.isEmpty { return value }
        }
        return nil
    }
}
