import Foundation

/// A provider's rate limits as its service reports them: rolling windows (5-hour session, weekly,
/// monthly, daily) and model-scoped ones. Percentages are "used", 0–100.
public struct PlanLimits: Codable, Equatable, Sendable {
    public struct Limit: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var usedPercent: Double
        public var resetsAt: Date?
        /// Window length, when known; pace needs it.
        public var duration: TimeInterval?

        public init(id: String, title: String, usedPercent: Double, resetsAt: Date?, duration: TimeInterval?) {
            self.id = id
            self.title = title
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
            self.duration = duration
        }

        public var leftPercent: Double { min(100, max(0, 100 - self.usedPercent)) }

        /// How usage compares with an even spread across the window (CodexBar's pace rules).
        public func pace(now: Date) -> Pace? {
            guard let reset = self.resetsAt, let duration = self.duration, duration > 0 else { return nil }
            let untilReset = reset.timeIntervalSince(now)
            guard untilReset > 0, untilReset <= duration else { return nil }
            let elapsed = duration - untilReset
            let expected = min(100, max(0, elapsed / duration * 100))
            let actual = min(100, max(0, self.usedPercent))
            if elapsed == 0, actual > 0 { return nil }
            // Too early in a short window to say anything useful, or nothing left to pace.
            if duration <= 6 * 3600, expected < 3 || actual >= 100 { return nil }
            let delta = actual - expected
            var runsOutIn: TimeInterval?
            if actual >= 100 {
                runsOutIn = 0
            } else if elapsed > 0, actual > 0 {
                let candidate = (100 - actual) / (actual / elapsed)
                if candidate < untilReset { runsOutIn = candidate }
            }
            return Pace(expectedUsedPercent: expected, deltaPercent: delta, runsOutIn: runsOutIn)
        }
    }

    public struct Pace: Equatable, Sendable {
        /// Where usage would be by now if spread evenly.
        public var expectedUsedPercent: Double
        /// Used minus expected: negative is reserve, positive is deficit.
        public var deltaPercent: Double
        /// At the current rate, when the limit runs out; nil when it lasts until reset.
        public var runsOutIn: TimeInterval?

        public var isOnPace: Bool { abs(self.deltaPercent) <= 2 || Int(abs(self.deltaPercent).rounded()) == 0 }
    }

    public var items: [Limit]
    /// Plan name when the service reports one ("Plus", "Pro").
    public var plan: String?
    public var fetchedAt: Date

    public init(items: [Limit], plan: String? = nil, fetchedAt: Date = Date()) {
        self.items = items
        self.plan = plan
        self.fetchedAt = fetchedAt
    }

    /// The weekly window's reset, which pins that provider's weekly spend windows.
    public var weeklyReset: Date? {
        self.items.first { $0.duration == Window.week }?.resetsAt
    }

    public enum Window {
        public static let session: TimeInterval = 5 * 3600
        public static let day: TimeInterval = 86_400
        public static let week: TimeInterval = 7 * 86_400
        public static let month: TimeInterval = 30 * 86_400
    }

    public static func placeholder() -> PlanLimits {
        PlanLimits(items: [
            Limit(id: "session", title: "Session", usedPercent: 0, resetsAt: nil, duration: Window.session),
            Limit(id: "weekly", title: "Weekly", usedPercent: 0, resetsAt: nil, duration: Window.week),
        ], fetchedAt: .distantPast)
    }

    static func cacheURL(_ provider: ProviderID) -> URL {
        AppPaths.support.appendingPathComponent("limits-\(provider.rawValue).json")
    }

    public static func loadCached(_ provider: ProviderID) -> PlanLimits? {
        guard let data = try? Data(contentsOf: self.cacheURL(provider)) else { return nil }
        return try? JSONDecoder().decode(PlanLimits.self, from: data)
    }

    public func saveCache(_ provider: ProviderID) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
        try? data.write(to: PlanLimits.cacheURL(provider), options: .atomic)
    }
}

public enum LimitsError: Error, Equatable, Sendable {
    /// The provider's own app or CLI isn't signed in on this Mac.
    case signedOut
    /// A token or key has to be pasted into Settings first.
    case needsKey
    /// The credential was rejected.
    case expired
    case rateLimited(retryAfter: TimeInterval)
    case failed
}

/// Shared plumbing for the limit fetchers: one ephemeral session, uniform status handling, and
/// lenient JSON readers.
enum HTTP {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    static func json(_ url: URL, headers: [String: String]) async throws(LimitsError) -> [String: Any] {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.session.data(for: request)
        } catch {
            throw .failed
        }
        guard let http = response as? HTTPURLResponse else { throw .failed }
        switch http.statusCode {
        case 200 ..< 300: break
        case 401, 403: throw .expired
        case 429:
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 300
            throw .rateLimited(retryAfter: max(60, retry))
        default: throw .failed
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw .failed }
        return object
    }
}

enum JSONValue {
    static func number(_ value: Any?) -> Double? {
        if let string = value as? String { return Double(string) }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    /// ISO 8601 strings (with or without fractional seconds), or Unix seconds / milliseconds.
    static func date(_ value: Any?) -> Date? {
        if let seconds = self.number(value), !(value is String) {
            return Date(timeIntervalSince1970: seconds > 1e12 ? seconds / 1000 : seconds)
        }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    static func string(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else { return nil }
        return string
    }
}
