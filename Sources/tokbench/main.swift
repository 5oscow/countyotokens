import Foundation
import TokenCore

// Times the refresh path: a cold scan, then warm rescans. With an interval, warm scans are spaced
// out so they pick up whatever Claude appended meanwhile (the common case while you work).
// Usage: tokbench [warm-iterations] [interval-seconds]   |   tokbench limits   |   tokbench renew-claude   |   tokbench droid-signin
let command = CommandLine.arguments.dropFirst().first
if command == "claude-desktop" {
    // What the Claude desktop app's sign-in would give, never opening the Keychain.
    // With a blob file and a password: decrypts that instead (a self-check of the decryption).
    let arguments = Array(CommandLine.arguments.dropFirst(2))
    if arguments.count == 2, let blob = try? Data(contentsOf: URL(fileURLWithPath: arguments[0])) {
        for line in ClaudeDesktop.describe(cache: blob, password: Data(arguments[1].utf8)) { print(line) }
    } else {
        print("available=\(ClaudeDesktop.isAvailable)", ClaudeDesktop.describe(.cachedOnly))
    }
    exit(0)
}
if command == "droid-signin" {
    // Which browser sign-in Droid would use: its expiry only, never the token.
    let started = ContinuousClock.now
    let token = DroidLimits.browserAccessToken()
    let expiry = DroidLimits.expiry(of: token)
    print(token == nil ? "no fresh app.factory.ai sign-in found" : "found, expires \(expiry.map { "\($0)" } ?? "?")", "in \(started.duration(to: .now))")
    exit(0)
}
if command == "renew-claude" {
    // Runs Claude Code's sign-in renewal once. With a valid sign-in it can't change anything: it
    // times out after ~10 s and prints false.
    let started = ContinuousClock.now
    let renewed = await ClaudeLimits.renewSignIn()
    print("renewed=\(renewed) in \(started.duration(to: .now))")
    exit(0)
}
if command == "limits" || command == "spend" {
    let ids = CommandLine.arguments.dropFirst(2).compactMap(ProviderID.init(rawValue:))
    for id in ids.isEmpty ? [ProviderID.claude] : ids {
        let started = ContinuousClock.now
        if command == "spend" {
            let source: SpendSource? = switch id {
            case .claude: LogScanner()
            case .codex: CodexScanner()
            case .opencodeGo: OpenCodeSpend.go
            case .zen: OpenCodeSpend.zen
            default: nil
            }
            guard let source else { print("\(id.rawValue): no local spend"); continue }
            let snapshot = source.spend(now: Date(), settings: WindowSettings(anchor: Date()), calendar: .current)
            print("\(id.rawValue) spend in \(started.duration(to: .now)): 30d $\(String(format: "%.2f", snapshot.historyCost)) · \(snapshot.historyTokens) tokens · today \(snapshot.today?.tokens ?? 0) · top \(snapshot.topModel?.model ?? "-")")
            continue
        }
        let credentials = ProviderCredentials(devinToken: nil, devinOrganization: nil, droidAPIKey: DroidLimits.environmentKey() ?? DroidLimits.browserAccessToken())
        do {
            let limits = try await ProviderLimits.fetch(id, credentials: credentials)
            print("\(id.rawValue) limits in \(started.duration(to: .now)) plan=\(limits.plan ?? "-")")
            for limit in limits.items {
                print("  \(limit.title.padding(toLength: 14, withPad: " ", startingAt: 0)) \(Int(limit.leftPercent.rounded()))% left · resets \(limit.resetsAt.map { "\($0)" } ?? "—")")
            }
        } catch {
            print("\(id.rawValue) limits: \(error)")
        }
    }
    exit(0)
}
let arguments = CommandLine.arguments.dropFirst().compactMap(Double.init)
let iterations = Int(arguments.first ?? 5)
let interval = arguments.dropFirst().first ?? 0
let settings = WindowSettings(anchor: ISO8601DateFormatter().date(from: "2026-11-21T02:59:59Z")!)
let scanner = LogScanner()

let (cold, coldStats) = scanner.scan(settings: settings)
print("cold  \(coldStats)")
for index in 1 ... iterations {
    if interval > 0 { try? await Task.sleep(for: .seconds(interval)) }
    let (_, stats) = scanner.scan(settings: settings)
    print("warm\(index) \(stats)")
}

let money: (Double) -> String = { String(format: "$%.2f", $0) }
print("today        \(money(cold.today?.cost ?? 0)) · \(cold.today?.tokens ?? 0) tokens")
print("30 days      \(money(cold.historyCost)) · \(cold.historyTokens) tokens")
for window in cold.windows {
    print("window \(window.start) \(money(window.cost)) · \(window.tokens)")
}
if let top = cold.topModel { print("top model    \(top.model) \(Int(top.share * 100))%") }
print("unpriced     \(cold.unpricedResponses)")
for day in cold.days { print("  \(day.start) \(money(day.cost)) \(day.tokens)") }
