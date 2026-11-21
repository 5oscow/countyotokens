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

    /// The sign-in app.factory.ai keeps in a Chromium-family browser's local storage, while it's
    /// still valid. Only the short-lived access token is read and it's never renewed from here:
    /// renewing spends the browser's one-time refresh token, which would sign the browser out.
    /// Local storage isn't encrypted, so no Keychain prompt.
    public static func browserAccessToken(now: Date = Date()) -> String? {
        let fm = FileManager.default
        let support = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let browsers = ["Google/Chrome", "Google/Chrome Beta", "Google/Chrome Canary", "Chromium", "Arc/User Data",
                        "BraveSoftware/Brave-Browser", "Microsoft Edge", "Dia/User Data", "net.imput.helium",
                        "Citro Labs/ego lite", "Vivaldi"]
        let marker = Data("workos:access-token".utf8)
        var best: (token: String, expiry: Double)?
        for browser in browsers {
            let root = support.appendingPathComponent(browser)
            guard let profiles = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            for profile in profiles where profile == "Default" || profile.hasPrefix("Profile ") {
                let folder = root.appendingPathComponent(profile).appendingPathComponent("Local Storage/leveldb")
                guard let files = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
                for file in files where file.hasSuffix(".log") || file.hasSuffix(".ldb") {
                    let url = folder.appendingPathComponent(file)
                    guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size < 32_000_000,
                          let raw = try? Data(contentsOf: url, options: .mappedIfSafe), raw.range(of: marker) != nil
                    else { continue }
                    // Values may be stored as UTF-16; dropping the zero bytes reads both forms.
                    let text = String(decoding: raw.filter { $0 != 0 }, as: UTF8.self)
                    for token in self.accessTokens(in: text) {
                        guard let claims = CodexLimits.claims(token), let expiry = JSONValue.number(claims["exp"]),
                              expiry > now.timeIntervalSince1970 + 30, expiry > (best?.expiry ?? 0)
                        else { continue }
                        best = (token, expiry)
                    }
                }
            }
        }
        return best?.token
    }

    public static func expiry(of token: String?) -> Date? {
        CodexLimits.claims(token).flatMap { JSONValue.number($0["exp"]) }.map { Date(timeIntervalSince1970: $0) }
    }

    /// JWTs stored under app.factory.ai's `workos:access-token` key.
    static func accessTokens(in text: String) -> [String] {
        var tokens: [String] = []
        var searchStart = text.startIndex
        while let key = text.range(of: "workos:access-token", range: searchStart ..< text.endIndex) {
            searchStart = key.upperBound
            let originStart = text.index(key.lowerBound, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
            let origin = text[originStart ..< key.lowerBound]
            guard origin.contains("factory.ai") else { continue }
            let tail = text[key.upperBound...].prefix(4096)
            guard let start = tail.range(of: "eyJ") else { continue }
            let allowed = Set("-_.")
            let token = tail[start.lowerBound...].prefix { (char: Character) -> Bool in
                char.isASCII && (char.isLetter || char.isNumber || allowed.contains(char))
            }
            if token.split(separator: ".").count == 3 { tokens.append(String(token)) }
        }
        return tokens
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
