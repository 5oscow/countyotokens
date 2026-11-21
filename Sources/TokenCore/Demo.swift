import Foundation

/// Made-up figures for screenshots: `-demo` on the command line fills every provider with these
/// instead of reading anything, so pictures of the app show believable shapes and nobody's real
/// usage, email or organization. Resets are placed relative to now, so they always look current.
public enum Demo {
    public static var isOn: Bool { UserDefaults.standard.bool(forKey: "demo") }

    public static let email = "you@example.com"
    public static let devinOrganization = "org_demo"

    public static func account(_ id: ProviderID) -> Account? {
        id == .claude ? Account(email: self.email, plan: "Max 5x") : nil
    }

    // MARK: Spend

    private struct Profile {
        /// Typical dollars a day, or tokens a day when the provider records no price.
        var perDay: Double
        var tokensPerDollar: Double
        var tokensOnly: Bool
        var idleDays: Double
        var model: String
        var share: Double
    }

    private static func profile(_ id: ProviderID) -> Profile? {
        switch id {
        case .claude: Profile(perDay: 96, tokensPerDollar: 2_400_000, tokensOnly: false, idleDays: 0.04,
                              model: "claude-opus-5-5", share: 0.72)
        case .codex: Profile(perDay: 21, tokensPerDollar: 1_150_000, tokensOnly: false, idleDays: 0.2,
                             model: "gpt-5.5-codex", share: 0.81)
        case .opencodeGo: Profile(perDay: 1_900_000, tokensPerDollar: 1, tokensOnly: true, idleDays: 0.25,
                                  model: "deepseek-v4.1-flash", share: 0.64)
        case .zen: Profile(perDay: 650_000, tokensPerDollar: 1, tokensOnly: true, idleDays: 0.45,
                           model: "kimi-k3", share: 0.57)
        case .devin, .droid: nil
        }
    }

    public static func snapshot(_ id: ProviderID, now: Date = Date(), settings: WindowSettings,
                                calendar: Calendar = .current) -> UsageSnapshot?
    {
        guard let profile = self.profile(id) else { return nil }
        var random = Random(seed: UInt64(id.rawValue.unicodeScalars.reduce(7) { $0 &* 31 &+ UInt64($1.value) }))
        let today = calendar.startOfDay(for: now)
        var days: [UsageSnapshot.Day] = []
        for back in stride(from: UsageSnapshot.historyDays - 1, through: 0, by: -1) {
            guard let start = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            let weekday = calendar.component(.weekday, from: start)
            let weekend = weekday == 1 || weekday == 7
            // Busier mid-month, quieter at weekends, the odd day off and the odd big one.
            var amount = profile.perDay * random.range(0.6, 1.25) * (weekend ? 0.5 : 1)
                * (1 + 0.3 * sin(Double(back) / 4.5))
            if random.unit() < profile.idleDays { amount = 0 }
            if random.unit() < 0.07 { amount *= 1.6 }
            if back == 0 { amount = profile.perDay * 0.62 } // Today, part-way through.
            let tokens = Int(profile.tokensOnly ? amount : amount * profile.tokensPerDollar * random.range(0.85, 1.15))
            days.append(UsageSnapshot.Day(start: start, cost: profile.tokensOnly ? 0 : (amount * 100).rounded() / 100,
                                          tokens: tokens))
        }

        var windows: [UsageSnapshot.Window] = []
        let currentEnd = settings.windowEnd(containing: now)
        for index in 0 ..< UsageSnapshot.windowCount {
            let end = currentEnd.addingTimeInterval(-Double(index) * WindowSettings.length)
            let start = end.addingTimeInterval(-WindowSettings.length)
            let inside = days.filter { $0.start >= start && $0.start < end }
            // Older windows reach past the 30 days kept: fill them at the usual rate.
            let missing = max(0, 7 - inside.count)
            let cost = inside.reduce(0) { $0 + $1.cost } + (profile.tokensOnly ? 0 : Double(missing) * profile.perDay * 0.8)
            let tokens = inside.reduce(0) { $0 + $1.tokens }
                + Int(Double(missing) * (profile.tokensOnly ? profile.perDay : profile.perDay * profile.tokensPerDollar) * 0.8)
            windows.append(UsageSnapshot.Window(start: start, end: end, cost: cost, tokens: tokens, isCurrent: index == 0))
        }

        let top = UsageSnapshot.ModelShare(model: profile.model, cost: 0, share: profile.share,
                                           byTokens: profile.tokensOnly ? true : nil)
        return UsageSnapshot(generatedAt: now, days: days, windows: windows, topModel: top, unpricedResponses: 0)
    }

    // MARK: Limits

    public static func limits(_ id: ProviderID, now: Date = Date(), settings: WindowSettings) -> PlanLimits? {
        typealias Window = PlanLimits.Window
        func limit(_ key: String, _ title: String, used: Double, resetsIn: TimeInterval, _ duration: TimeInterval)
            -> PlanLimits.Limit
        {
            PlanLimits.Limit(id: key, title: title, usedPercent: used, resetsAt: now.addingTimeInterval(resetsIn),
                             duration: duration)
        }
        let weekReset = settings.windowEnd(containing: now).timeIntervalSince(now)
        let hour: TimeInterval = 3600, day: TimeInterval = 86_400
        switch id {
        case .claude:
            return PlanLimits(items: [
                limit("session", "Session", used: 41, resetsIn: 2 * hour + 12 * 60, Window.session),
                limit("weekly", "Weekly", used: 37, resetsIn: weekReset, Window.week),
                limit("weekly-opus", "Opus weekly", used: 24, resetsIn: weekReset, Window.week),
            ], plan: "Max 5x", fetchedAt: now)
        case .codex:
            return PlanLimits(items: [
                limit("session", "5-hour", used: 66, resetsIn: hour + 40 * 60, Window.session),
                limit("weekly", "Weekly", used: 48, resetsIn: weekReset, Window.week),
            ], plan: "Pro", fetchedAt: now)
        case .opencodeGo:
            return PlanLimits(items: [
                limit("session", "5-hour", used: 12, resetsIn: 4 * hour + 10 * 60, Window.session),
                limit("weekly", "Weekly", used: 34, resetsIn: weekReset, Window.week),
                limit("monthly", "Monthly", used: 58, resetsIn: 9 * day + 5 * hour, Window.month),
            ], plan: nil, fetchedAt: now)
        case .devin:
            return PlanLimits(items: [
                limit("daily", "Daily", used: 44, resetsIn: 9 * hour, Window.day),
                limit("weekly", "Weekly", used: 82, resetsIn: 2 * day, Window.week),
            ], plan: "Team", fetchedAt: now)
        case .droid:
            return PlanLimits(items: [
                limit("standard", "Standard", used: 46, resetsIn: 14 * day, Window.month),
                limit("premium", "Premium", used: 18, resetsIn: 14 * day, Window.month),
            ], plan: "Pro", fetchedAt: now)
        case .zen:
            return nil
        }
    }

    /// Small, seeded, so the demo looks the same every time.
    private struct Random {
        var state: UInt64
        init(seed: UInt64) { self.state = seed }
        mutating func unit() -> Double {
            self.state &+= 0x9E37_79B9_7F4A_7C15
            var z = self.state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
        mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * self.unit() }
    }
}
