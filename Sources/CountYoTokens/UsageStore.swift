import AppKit
import Observation
import ServiceManagement
import SwiftUI
import TokenCore

/// One provider's figures: local spend (scanned on its own queue) and remote limits.
@Observable
@MainActor
final class ProviderModel: Identifiable {
    let id: ProviderID

    /// Last scan result. Seeded from disk so the card is filled before the first scan finishes.
    private(set) var snapshot: UsageSnapshot?
    private(set) var updatedAt: Date?
    /// True only when a scan runs long enough to be worth showing (cold start).
    private(set) var isVisiblyRefreshing = false
    /// Limits from the provider, seeded from disk. Last values stay up while a fetch runs or fails.
    private(set) var limits: PlanLimits?
    /// Why limits can't be fetched right now, when it's something the user can act on.
    private(set) var limitsIssue: LimitsError?
    private(set) var account: Account?

    /// Weekly spend windows. Pinned to the provider's reported weekly reset when it has one,
    /// otherwise Monday 00:00 local time.
    private(set) var windowSettings: WindowSettings

    @ObservationIgnored private let source: SpendSource?
    @ObservationIgnored private let scanQueue: DispatchQueue
    @ObservationIgnored private var isScanning = false
    @ObservationIgnored private var needsAnotherScan = false
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var limitsTask: Task<Void, Never>?
    @ObservationIgnored private var limitsCheckedAt = Date.distantPast
    @ObservationIgnored let credentials: () -> ProviderCredentials
    /// Set when Settings pins weekly windows to a weekday instead of the plan's reset.
    @ObservationIgnored private var fixedWeekday: Int?
    /// Showing `Demo` figures: nothing is read, fetched or saved.
    @ObservationIgnored private var isDemo = false

    /// Persisted, so relaunching doesn't hammer an endpoint that asked us to back off.
    @ObservationIgnored private var limitsBlockedUntil: Date {
        get { UserDefaults.standard.object(forKey: "limitsBlockedUntil.\(self.id.rawValue)") as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: "limitsBlockedUntil.\(self.id.rawValue)") }
    }

    private var anchorKey: String { "windowAnchor.\(self.id.rawValue)" }

    init(_ id: ProviderID, source: SpendSource?, credentials: @escaping () -> ProviderCredentials) {
        self.id = id
        self.source = source
        self.credentials = credentials
        self.scanQueue = DispatchQueue(label: "countyotokens.scan.\(id.rawValue)", qos: .userInitiated)
        let weekday = UserDefaults.standard.integer(forKey: "weekStart")
        self.fixedWeekday = (1 ... 7).contains(weekday) ? weekday : nil
        self.windowSettings = WindowSettings(anchor: self.fixedWeekday.map(Self.weekStart) ?? Self.planAnchor(for: id))
        self.snapshot = UsageSnapshot.loadCached(id)
        self.updatedAt = self.snapshot?.generatedAt
        self.limits = PlanLimits.loadCached(id)
        self.limitsCheckedAt = self.limits?.fetchedAt ?? .distantPast
        if id == .claude { self.account = Account.load() }
    }

    /// The last weekly reset the plan reported. Before any, Claude's reset when this fork was made;
    /// everyone else starts on Monday until told otherwise.
    private static func planAnchor(for id: ProviderID) -> Date {
        if let stored = UserDefaults.standard.object(forKey: "windowAnchor.\(id.rawValue)") as? Double {
            return Date(timeIntervalSince1970: stored)
        }
        if id == .claude { return Date(timeIntervalSince1970: 1_795_229_999) } // Fri 21 Nov 2026 02:59:59 UTC
        return self.weekStart(2)
    }

    /// Midnight at the start of this week, for a week starting on `weekday` (1 = Sunday).
    static func weekStart(_ weekday: Int) -> Date {
        var calendar = Calendar.current
        calendar.firstWeekday = weekday
        return calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
    }

    /// Settings changed the week start: 1…7 pins a weekday, nil goes back to the plan's reset.
    func setWeekStart(_ weekday: Int?) {
        self.fixedWeekday = weekday
        let anchor = weekday.map(Self.weekStart) ?? self.limits?.weeklyReset ?? Self.planAnchor(for: self.id)
        guard anchor != self.windowSettings.anchor else { return }
        self.windowSettings = WindowSettings(anchor: anchor)
        self.refresh()
    }

    // MARK: Lifecycle

    /// Swaps in made-up figures for screenshots (`-demo`) and stops every refresh.
    func loadDemo(now: Date = Date()) {
        self.isDemo = true
        self.stop()
        // The demo's own week, not this Mac's: it resets 3 days 5 hours from now.
        self.windowSettings = WindowSettings(anchor: now.addingTimeInterval(3 * 86_400 + 5 * 3600))
        self.snapshot = Demo.snapshot(self.id, now: now, settings: self.windowSettings)
        self.updatedAt = self.snapshot == nil ? nil : now
        self.limits = Demo.limits(self.id, now: now, settings: self.windowSettings)
        self.limitsIssue = nil
        self.account = Demo.account(self.id)
    }

    func start() {
        guard !self.isDemo, self.watcher == nil, let source = self.source else { return }
        self.watcher = FileWatcher(paths: source.watchedPaths) { [weak self] in self?.refresh() }
        self.refresh()
    }

    func stop() {
        self.watcher = nil
        self.limitsTask?.cancel()
        self.limitsTask = nil
    }

    // MARK: Spend

    /// Coalesces bursts: at most one scan runs, and at most one more is queued behind it.
    func refresh() {
        guard !self.isDemo, let source = self.source else { return }
        guard !self.isScanning else {
            self.needsAnotherScan = true
            return
        }
        self.isScanning = true
        let settings = self.windowSettings
        let started = Date()
        // Only surface the spinner if a scan is slow (the cold scan at launch); quick scans stay invisible.
        let spinnerDelay = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            if self.isScanning { withAnimation(.easeInOut(duration: 0.2)) { self.isVisiblyRefreshing = true } }
        }
        self.scanQueue.async {
            let snapshot = source.spend(now: started, settings: settings, calendar: .current)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    spinnerDelay.cancel()
                    self.apply(snapshot)
                }
            }
        }
    }

    private func apply(_ new: UsageSnapshot) {
        var comparable = new
        comparable.generatedAt = self.snapshot?.generatedAt ?? new.generatedAt
        // Identical figures: touch nothing, so no view re-renders.
        if comparable != self.snapshot {
            withAnimation(.smooth(duration: 0.55)) { self.snapshot = new }
            new.saveCache(self.id)
        }
        self.updatedAt = new.generatedAt
        if self.isVisiblyRefreshing {
            withAnimation(.easeInOut(duration: 0.25)) { self.isVisiblyRefreshing = false }
        }
        self.isScanning = false
        if self.needsAnotherScan {
            self.needsAnotherScan = false
            self.refresh()
        }
    }

    // MARK: Limits

    /// Fetches limits unless a fetch is running, the last one is younger than `minimumAge`, or the
    /// server asked us to back off. Usage endpoints rate-limit eagerly: every 3 minutes in the
    /// background, at most once a minute when the menu opens.
    ///
    /// `userInitiated` lets a provider recover from an expired sign-in on the way (see ProviderLimits).
    func refreshLimits(minimumAge: TimeInterval = 170, userInitiated: Bool = false) {
        guard self.id.hasLimits, !self.isDemo else { return }
        let now = Date()
        // An expired sign-in shouldn't wait out the usual spacing once the user is looking.
        let minimumAge = userInitiated && self.limitsIssue == .expired ? 0 : minimumAge
        guard self.limitsTask == nil, now >= self.limitsBlockedUntil,
              now.timeIntervalSince(self.limitsCheckedAt) >= minimumAge else { return }
        self.limitsCheckedAt = now
        let id = self.id
        let credentials = self.credentials()
        self.limitsTask = Task {
            let result: Result<PlanLimits, LimitsError>
            do throws(LimitsError) {
                result = .success(try await ProviderLimits.fetch(id, credentials: credentials, userInitiated: userInitiated))
            } catch {
                result = .failure(error)
            }
            self.apply(result)
            self.limitsTask = nil
        }
    }

    /// After a key changes in Settings: forget the backoff and fetch now.
    func credentialsChanged() {
        self.limitsBlockedUntil = .distantPast
        self.limitsCheckedAt = .distantPast
        self.limitsTask?.cancel()
        self.limitsTask = nil
        self.refreshLimits()
    }

    private func apply(_ result: Result<PlanLimits, LimitsError>) {
        switch result {
        case let .success(new):
            var comparable = new
            comparable.fetchedAt = self.limits?.fetchedAt ?? new.fetchedAt
            if comparable != self.limits {
                withAnimation(.smooth(duration: 0.55)) { self.limits = new }
            } else {
                self.limits = new
            }
            new.saveCache(self.id)
            if self.limitsIssue != nil { withAnimation(.smooth) { self.limitsIssue = nil } }
            if let reset = new.weeklyReset { self.adoptWeeklyReset(reset) }
        case let .failure(.rateLimited(retryAfter)):
            self.limitsBlockedUntil = Date().addingTimeInterval(retryAfter)
        case .failure(.failed):
            break // Offline or a hiccup: keep the last values, try again later.
        case let .failure(issue):
            if issue != self.limitsIssue { withAnimation(.smooth) { self.limitsIssue = issue } }
        }
    }

    /// Windows are counted from the reported weekly reset; only move them if it really changed.
    private func adoptWeeklyReset(_ reset: Date) {
        UserDefaults.standard.set(reset.timeIntervalSince1970, forKey: self.anchorKey)
        guard self.fixedWeekday == nil else { return }
        let week = WindowSettings.length
        let offset = (reset.timeIntervalSince(self.windowSettings.anchor).truncatingRemainder(dividingBy: week) + week)
            .truncatingRemainder(dividingBy: week)
        guard min(offset, week - offset) > 60 else { return }
        self.windowSettings = WindowSettings(anchor: reset)
        self.refresh()
    }

    func pricesChanged(_ prices: [String: ModelPrice], refresh: Bool) {
        self.source?.updatePrices(prices)
        if refresh { self.refresh() }
    }

    func reloadAccount() {
        guard self.id == .claude, !self.isDemo else { return }
        let account = Account.load()
        if account != self.account { self.account = account }
    }

    /// Plan name for the header.
    var plan: String? { self.account?.plan ?? self.limits?.plan }

    /// Lowest % left across the provider's limits, for the menu bar.
    var lowestLeft: Double? {
        let now = Date()
        return self.limits?.items.map { limit in
            limit.resetsAt.map { $0 <= now } == true ? 100 : limit.leftPercent
        }.min()
    }
}

/// Every provider, which ones are on, which one the menu shows, and the app's switches.
@Observable
@MainActor
final class UsageStore {
    let providers: [ProviderID: ProviderModel]

    let prefs = Preferences()

    /// Providers that are switched on.
    private var enabledSet: Set<ProviderID>

    /// Providers shown in the switcher, in the order set in Settings.
    var enabled: [ProviderID] { self.prefs.order.filter(self.enabledSet.contains) }

    var selected: ProviderID {
        didSet { UserDefaults.standard.set(self.selected.rawValue, forKey: Keys.selected) }
    }

    var devinOrganization: String {
        didSet {
            UserDefaults.standard.set(self.devinOrganization, forKey: Keys.devinOrganization)
            self.providers[.devin]?.credentialsChanged()
        }
    }

    /// Bumped when a pasted key changes, so Settings re-reads the Keychain state.
    private(set) var secretsRevision = 0

    var opensAtLogin: Bool {
        get { _ = self.loginItemRevision; return SMAppService.mainApp.status == .enabled }
        set {
            try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            self.loginItemRevision += 1
        }
    }

    /// The Settings pane to show; set before opening the window to land on a provider.
    var settingsPane: SettingsPane = .general

    private var loginItemRevision = 0
    @ObservationIgnored private var timer: Timer?

    private enum Keys {
        static let enabled = "enabledProviders"
        static let selected = "selectedProvider"
        static let devinOrganization = "devinOrganization"
    }

    var current: ProviderModel { self.providers[self.selected] ?? self.providers[.claude]! }

    init() {
        Self.migrateLegacyCaches()
        let defaults = UserDefaults.standard
        var models: [ProviderID: ProviderModel] = [:]
        let credentials: () -> ProviderCredentials = {
            ProviderCredentials(
                devinToken: Secrets.get(.devinToken),
                devinOrganization: UserDefaults.standard.string(forKey: Keys.devinOrganization)
                    .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                    ?? DevinLimits.cliOrganization(),
                droidAPIKey: Secrets.get(.droidAPIKey) ?? DroidLimits.environmentKey())
        }
        for id in ProviderID.allCases {
            let source: SpendSource? = switch id {
            case .claude: LogScanner()
            case .codex: CodexScanner()
            case .opencodeGo: OpenCodeSpend.go
            case .zen: OpenCodeSpend.zen
            case .devin, .droid: nil
            }
            models[id] = ProviderModel(id, source: source, credentials: credentials)
        }
        self.providers = models

        let stored = (defaults.array(forKey: Keys.enabled) as? [String])?.compactMap(ProviderID.init(rawValue:))
        var enabledSet = Set(stored ?? ProviderDetection.detected())
        if enabledSet.isEmpty { enabledSet = [.claude] }
        if Demo.isOn {
            enabledSet = Set(ProviderID.allCases)
            for model in models.values { model.loadDemo() }
        }
        self.enabledSet = enabledSet
        let first = self.prefs.order.first(where: enabledSet.contains) ?? .claude
        let selected = defaults.string(forKey: Keys.selected).flatMap(ProviderID.init(rawValue:)) ?? first
        self.selected = enabledSet.contains(selected) ? selected : first
        self.devinOrganization = Demo.isOn ? "" : defaults.string(forKey: Keys.devinOrganization) ?? ""

        for id in self.enabled { self.providers[id]?.start() }
        // Day and window rollovers happen without any file changing.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Common modes keep it firing while the menu is open (event-tracking run loop mode).
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        self.tick()
        Task {
            if let prices = await PriceCatalog.refreshIfStale() {
                for (id, model) in self.providers { model.pricesChanged(prices, refresh: self.enabled.contains(id)) }
            }
        }
    }

    private func tick() {
        for id in self.enabled {
            self.providers[id]?.refresh()
            if let age = self.prefs.limitsInterval.minimumAge { self.providers[id]?.refreshLimits(minimumAge: age) }
        }
        Notifier.shared.check(self)
    }

    func menuWillOpen() {
        self.current.refresh()
        if self.prefs.refreshesOnOpen { self.current.refreshLimits(minimumAge: 60, userInitiated: true) }
        self.current.reloadAccount()
    }

    /// Every enabled provider, spend and limits, as soon as the endpoints allow.
    func refreshAll() {
        for id in self.enabled {
            self.providers[id]?.refresh()
            self.providers[id]?.refreshLimits(minimumAge: 30, userInitiated: true)
        }
    }

    func setWeekStart(_ weekday: Int) {
        self.prefs.weekStart = weekday
        for model in self.providers.values { model.setWeekStart((1 ... 7).contains(weekday) ? weekday : nil) }
    }

    /// Downloads the models.dev catalog now. Returns false when it couldn't be reached.
    func updatePrices() async -> Bool {
        guard let prices = await PriceCatalog.refreshIfStale(maxAge: 0) else { return false }
        for (id, model) in self.providers { model.pricesChanged(prices, refresh: self.enabled.contains(id)) }
        return true
    }

    /// The provider the menu-bar text and meter follow.
    var menuBarModel: ProviderModel {
        if let id = self.prefs.menuBarProvider, self.enabledSet.contains(id), let model = self.providers[id] { return model }
        return self.current
    }

    func refreshNow() {
        self.current.refresh()
        self.current.refreshLimits(minimumAge: 30, userInitiated: true)
    }

    func isEnabled(_ id: ProviderID) -> Bool { self.enabledSet.contains(id) }

    /// Forgets both pasted keys.
    func removeSecrets() {
        for key in [Secrets.Key.devinToken, .droidAPIKey] where Secrets.get(key) != nil { _ = self.setSecret(key, "") }
    }

    func setEnabled(_ id: ProviderID, _ on: Bool) {
        var set = self.enabledSet
        if on { set.insert(id) } else { set.remove(id) }
        guard !set.isEmpty, set != self.enabledSet else { return } // Keep at least one.
        self.enabledSet = set
        UserDefaults.standard.set(self.enabled.map(\.rawValue), forKey: Keys.enabled)
        if on {
            self.providers[id]?.start()
            self.providers[id]?.refreshLimits(minimumAge: 0)
        } else {
            self.providers[id]?.stop()
        }
        if !self.enabled.contains(self.selected) { self.selected = self.enabled[0] }
    }

    func setSecret(_ key: Secrets.Key, _ value: String) -> Bool {
        let saved = Secrets.set(key, value)
        self.secretsRevision += 1
        self.providers[key == .devinToken ? .devin : .droid]?.credentialsChanged()
        return saved
    }

    func hasSecret(_ key: Secrets.Key) -> Bool {
        _ = self.secretsRevision
        return Secrets.get(key) != nil
    }

    /// Caches from the single-provider version: keep Claude's snapshot, drop the old limits format.
    private static func migrateLegacyCaches() {
        let support = AppPaths.support
        let fm = FileManager.default
        let old = support.appendingPathComponent("snapshot.json")
        let new = support.appendingPathComponent("snapshot-claude.json")
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) { try? fm.moveItem(at: old, to: new) }
        try? fm.removeItem(at: old)
        try? fm.removeItem(at: support.appendingPathComponent("limits.json"))
        try? fm.removeItem(at: support.appendingPathComponent("prices.json"))
        let defaults = UserDefaults.standard
        if let anchor = defaults.object(forKey: "windowAnchor") {
            defaults.set(anchor, forKey: "windowAnchor.claude")
            defaults.removeObject(forKey: "windowAnchor")
        }
        defaults.removeObject(forKey: "limitsBlockedUntil")
    }
}

// MARK: - Wording

extension ProviderModel {
    /// Second header line: who is signed in, or where the figures come from.
    func subtitle(hidingEmail: Bool) -> String {
        switch self.id {
        case .claude: self.account?.email.map { hidingEmail ? Self.masked($0) : $0 } ?? "Local usage"
        case .codex: "Codex CLI"
        case .opencodeGo: "Subscription · OpenCode CLI"
        case .zen: "Pay as you go · OpenCode CLI"
        case .devin: "app.devin.ai"
        case .droid: "Factory"
        }
    }

    /// `j•••@example.com`.
    static func masked(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@"), at > email.startIndex else { return "Email hidden" }
        return "\(email[email.startIndex])•••\(email[at...])"
    }

    func message(for issue: LimitsError) -> String {
        switch (issue, self.id) {
        case (.signedOut, .claude): "Sign in to Claude Code to see your plan limits."
        case (.signedOut, .codex): "Sign in to Codex to see your plan limits."
        case (.signedOut, .opencodeGo): "Connect OpenCode Go in OpenCode to see your limits."
        case (.needsKey, .devin): "Sign in with the Devin CLI (devin auth login) to see your limits."
        case (.needsKey, .droid): "Add a Factory API key in Settings to see your limits."
        case (.expired, .claude): "Paused until Claude Code renews its sign-in."
        case (.expired, .codex): "Paused until Codex renews its sign-in."
        case (.expired, .devin): "Devin didn't accept the sign-in. Run devin auth login again."
        case (.expired, .droid): "Factory didn't accept the API key."
        case (.expired, _): "\(self.id.displayName) didn't accept the key."
        case (.signedOut, _), (.needsKey, _): "Sign in to \(self.id.displayName) to see your limits."
        case (.rateLimited, _), (.failed, _): "Couldn't reach \(self.id.displayName)."
        }
    }
}
