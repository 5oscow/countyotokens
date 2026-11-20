import Foundation

/// Where the weekly windows sit. Claude's weekly limit resets at a fixed instant every 7 days;
/// any one known reset pins every past and future window.
public struct WindowSettings: Codable, Sendable, Equatable {
    public var anchor: Date
    public static let length: TimeInterval = 7 * 86_400

    public init(anchor: Date) {
        self.anchor = anchor
    }

    /// End of the window containing `date`.
    public func windowEnd(containing date: Date) -> Date {
        let steps = (date.timeIntervalSince(self.anchor) / Self.length).rounded(.down) + 1
        return self.anchor.addingTimeInterval(steps * Self.length)
    }
}

public struct UsageSnapshot: Codable, Sendable, Equatable {
    public struct Day: Codable, Sendable, Equatable, Identifiable {
        public var start: Date
        public var cost: Double
        public var tokens: Int
        public var id: Date { self.start }
    }

    public struct Window: Codable, Sendable, Equatable, Identifiable {
        public var start: Date
        public var end: Date
        public var cost: Double
        public var tokens: Int
        public var isCurrent: Bool
        public var id: Date { self.start }
    }

    public struct ModelShare: Codable, Sendable, Equatable {
        public var model: String
        public var cost: Double
        public var share: Double
    }

    public static let historyDays = 30
    public static let windowCount = 4

    public var generatedAt: Date
    /// Oldest first; the last entry is today.
    public var days: [Day]
    /// Newest first; the first entry is the current window.
    public var windows: [Window]
    public var topModel: ModelShare?
    /// Responses whose model has no known price; their tokens count, their cost does not.
    public var unpricedResponses: Int

    public var today: Day? { self.days.last }
    public var currentWindow: Window? { self.windows.first }
    public var historyCost: Double { self.days.reduce(0) { $0 + $1.cost } }
    public var historyTokens: Int { self.days.reduce(0) { $0 + $1.tokens } }

    /// Earliest instant any figure on the card needs.
    static func horizon(now: Date, settings: WindowSettings, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        let firstDay = calendar.date(byAdding: .day, value: -(Self.historyDays - 1), to: today) ?? today
        let firstWindow = settings.windowEnd(containing: now)
            .addingTimeInterval(-Double(Self.windowCount) * WindowSettings.length)
        return min(firstDay, firstWindow)
    }

    /// Changes when the day or the current window rolls over, or the settings change.
    static func bucketKey(now: Date, settings: WindowSettings, calendar: Calendar) -> String {
        "\(calendar.startOfDay(for: now).timeIntervalSince1970)|\(settings.windowEnd(containing: now).timeIntervalSince1970)|\(calendar.timeZone.identifier)"
    }

    static func build(
        now: Date, settings: WindowSettings, calendar: Calendar,
        rows forEachRow: ((UsageRow) -> Void) -> Void) -> UsageSnapshot
    {
        let today = calendar.startOfDay(for: now)
        let dayStarts: [Date] = (0 ..< Self.historyDays).reversed().map {
            calendar.date(byAdding: .day, value: -$0, to: today) ?? today
        }
        let dayBounds = dayStarts.map { Int64($0.timeIntervalSince1970 * 1000) }
            + [Int64((calendar.date(byAdding: .day, value: 1, to: today) ?? now).timeIntervalSince1970 * 1000)]
        var days = dayStarts.map { Day(start: $0, cost: 0, tokens: 0) }

        let currentEnd = settings.windowEnd(containing: now)
        let currentEndMs = Int64(currentEnd.timeIntervalSince1970 * 1000)
        let windowMs = Int64(WindowSettings.length * 1000)
        var windows = (0 ..< Self.windowCount).map { index in
            let end = currentEnd.addingTimeInterval(-Double(index) * WindowSettings.length)
            return Window(start: end.addingTimeInterval(-WindowSettings.length), end: end,
                          cost: 0, tokens: 0, isCurrent: index == 0)
        }

        var modelCost: [String: Double] = [:]
        var unpriced = 0
        forEachRow { row in
            let ts = row.timestampMs
            if ts >= dayBounds[0], ts < dayBounds[dayBounds.count - 1] {
                // Binary search the day bucket (DST-safe: bounds come from the calendar).
                var low = 0
                var high = Self.historyDays - 1
                while low < high {
                    let mid = (low + high + 1) / 2
                    if dayBounds[mid] <= ts { low = mid } else { high = mid - 1 }
                }
                days[low].tokens += row.tokens
                days[low].cost += row.cost ?? 0
                modelCost[row.model, default: 0] += row.cost ?? 0
                if row.cost == nil { unpriced += 1 }
            }
            if ts < currentEndMs {
                let index = Int((currentEndMs - 1 - ts) / windowMs)
                if index < Self.windowCount {
                    windows[index].tokens += row.tokens
                    windows[index].cost += row.cost ?? 0
                }
            }
        }

        let total = modelCost.values.reduce(0, +)
        let top = modelCost.max { $0.value < $1.value }
        return UsageSnapshot(
            generatedAt: now,
            days: days,
            windows: windows,
            topModel: top.flatMap { total > 0 ? ModelShare(model: $0.key, cost: $0.value, share: $0.value / total) : nil },
            unpricedResponses: unpriced)
    }
}

extension UsageSnapshot {
    /// An all-zero snapshot with the real day and window layout.
    public static func placeholder(now: Date = Date(), settings: WindowSettings, calendar: Calendar = .current) -> UsageSnapshot {
        self.build(now: now, settings: settings, calendar: calendar) { _ in }
    }
}

// MARK: - Persistence

extension UsageSnapshot {
    static var cacheURL: URL { AppPaths.support.appendingPathComponent("snapshot.json") }

    /// Last computed snapshot, shown instantly at launch before the first scan finishes.
    public static func loadCached() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: self.cacheURL) else { return nil }
        return try? JSONDecoder().decode(UsageSnapshot.self, from: data)
    }

    public func saveCache() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
        try? data.write(to: Self.cacheURL, options: .atomic)
    }
}
