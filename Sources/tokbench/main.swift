import Foundation
import TokenCore

// Times the refresh path: a cold scan, then warm rescans. With an interval, warm scans are spaced
// out so they pick up whatever Claude appended meanwhile (the common case while you work).
// Usage: tokbench [warm-iterations] [interval-seconds]   |   tokbench limits
if CommandLine.arguments.dropFirst().first == "limits" {
    let started = ContinuousClock.now
    do {
        let limits = try await LimitsClient.fetch()
        print("fetched in \(started.duration(to: .now))")
        for limit in limits.all {
            print("\(limit.title.padding(toLength: 14, withPad: " ", startingAt: 0)) \(Int(limit.leftPercent.rounded()))% left · resets \(limit.resetsAt.map { "\($0)" } ?? "—")")
        }
    } catch {
        print("limits failed: \(error)")
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
