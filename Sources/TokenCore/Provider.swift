import Foundation

/// Every service count yo tokens can show. Each provider has local spend, remote limits, or both.
public enum ProviderID: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude
    case codex
    case opencodeGo = "opencode-go"
    case zen
    case devin
    case droid

    public var id: String { self.rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .opencodeGo: "OpenCode Go"
        case .zen: "OpenCode Zen"
        case .devin: "Devin"
        case .droid: "Droid"
        }
    }

    /// Fits a switcher tab.
    public var shortName: String {
        switch self {
        case .opencodeGo: "Go"
        case .zen: "Zen"
        default: self.displayName
        }
    }

    /// Zen is pay-as-you-go: spend only.
    public var hasLimits: Bool { self != .zen }

    /// Devin and Droid keep no local usage logs worth pricing.
    public var hasSpend: Bool { self != .devin && self != .droid }

    /// How the dollar figures were arrived at.
    public var spendNote: String {
        switch self {
        case .opencodeGo, .zen: "Recorded by OpenCode"
        default: "Estimated at API prices"
        }
    }

    /// Settings needs a pasted credential for these.
    public var needsPastedKey: Bool { self == .devin || self == .droid }
}

/// A local spend history: something that turns logs into a snapshot.
public protocol SpendSource: AnyObject, Sendable {
    /// Directories or files whose changes should trigger a refresh.
    var watchedPaths: [String] { get }
    func spend(now: Date, settings: WindowSettings, calendar: Calendar) -> UsageSnapshot
    /// Newer list prices arrived; sources that price tokens themselves re-price.
    func updatePrices(_ prices: [String: ModelPrice])
}

public extension SpendSource {
    func updatePrices(_ prices: [String: ModelPrice]) {}
}

/// What a limit fetch needs that only the app knows: keys pasted into Settings.
public struct ProviderCredentials: Sendable {
    public var devinToken: String?
    public var devinOrganization: String?
    public var droidAPIKey: String?

    public init(devinToken: String?, devinOrganization: String?, droidAPIKey: String?) {
        self.devinToken = devinToken
        self.devinOrganization = devinOrganization
        self.droidAPIKey = droidAPIKey
    }
}

/// Which providers this Mac has used, for the first launch's default selection.
public enum ProviderDetection {
    public static func detected(environment: [String: String] = ProcessInfo.processInfo.environment) -> [ProviderID] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        func exists(_ path: String) -> Bool { fm.fileExists(atPath: home.appendingPathComponent(path).path) }
        var found: [ProviderID] = [.claude]
        if CodexScanner.hasSessions(environment: environment) { found.append(.codex) }
        if fm.fileExists(atPath: OpenCodeDB.url(environment: environment).path) { found += [.opencodeGo, .zen] }
        if exists(".config/devin") || fm.fileExists(atPath: "/Applications/Devin.app") { found.append(.devin) }
        if exists(".factory") || environment["FACTORY_API_KEY"] != nil { found.append(.droid) }
        return found
    }
}

/// Fetches any provider's limits.
public enum ProviderLimits {
    /// `userInitiated`: the user opened the menu or asked for a refresh, so a provider may do slower
    /// recovery work (Claude: get Claude Code to renew an expired sign-in).
    public static func fetch(_ id: ProviderID, credentials: ProviderCredentials, userInitiated: Bool = false) async throws(LimitsError) -> PlanLimits {
        switch id {
        case .claude: try await ClaudeLimits.fetch(mayRenew: userInitiated)
        case .codex: try await CodexLimits.fetch()
        case .opencodeGo: try await OpenCodeGoLimits.fetch()
        case .devin: try await DevinLimits.fetch(token: credentials.devinToken, organization: credentials.devinOrganization)
        case .droid: try await DroidLimits.fetch(apiKey: credentials.droidAPIKey)
        case .zen: throw .failed
        }
    }
}

extension LogScanner: SpendSource {
    public func spend(now: Date, settings: WindowSettings, calendar: Calendar) -> UsageSnapshot {
        self.scan(now: now, settings: settings, calendar: calendar).0
    }
}
