import AppKit
import Observation
import ServiceManagement
import SwiftUI
import TokenCore

@Observable
@MainActor
final class UsageStore {
    /// Last scan result. Seeded from disk so the card is filled before the first scan finishes.
    private(set) var snapshot: UsageSnapshot?
    private(set) var account: Account?
    private(set) var updatedAt: Date?
    /// True only when a scan runs long enough to be worth showing (cold start).
    private(set) var isVisiblyRefreshing = false
    /// Plan limits from Anthropic, seeded from disk. Last values stay up while a fetch runs or fails.
    private(set) var limits: PlanLimits?
    /// Why limits can't be fetched right now, when it's something the user can act on.
    private(set) var limitsIssue: LimitsError?

    var windowSettings: WindowSettings {
        didSet {
            guard oldValue != self.windowSettings else { return }
            UserDefaults.standard.set(self.windowSettings.anchor.timeIntervalSince1970, forKey: Keys.anchor)
            self.refresh()
        }
    }

    var showsSpendInMenuBar: Bool {
        didSet { UserDefaults.standard.set(self.showsSpendInMenuBar, forKey: Keys.menuBarSpend) }
    }

    var opensAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            self.loginItemRevision += 1
        }
    }

    /// Bumped so views reading `opensAtLogin` re-evaluate after a toggle.
    private var loginItemRevision = 0

    @ObservationIgnored private let scanner = LogScanner()
    @ObservationIgnored private let scanQueue = DispatchQueue(label: "countyotokens.scan", qos: .userInitiated)
    @ObservationIgnored private var isScanning = false
    @ObservationIgnored private var needsAnotherScan = false
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var limitsTask: Task<Void, Never>?
    @ObservationIgnored private var limitsCheckedAt = Date.distantPast
    /// Persisted, so relaunching doesn't hammer an endpoint that asked us to back off.
    @ObservationIgnored private var limitsBlockedUntil: Date {
        get { UserDefaults.standard.object(forKey: Keys.limitsBlockedUntil) as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: Keys.limitsBlockedUntil) }
    }

    private enum Keys {
        static let anchor = "windowAnchor"
        static let menuBarSpend = "showsSpendInMenuBar"
        static let limitsBlockedUntil = "limitsBlockedUntil"
    }

    /// Fallback until Anthropic reports the real weekly reset (then that is stored instead).
    nonisolated static let defaultAnchor = Date(timeIntervalSince1970: 1_795_229_999) // Fri 21 Nov 2026 02:59:59 UTC

    init() {
        let defaults = UserDefaults.standard
        let anchor = defaults.object(forKey: Keys.anchor) as? Double
        self.windowSettings = WindowSettings(anchor: anchor.map(Date.init(timeIntervalSince1970:)) ?? Self.defaultAnchor)
        self.showsSpendInMenuBar = defaults.object(forKey: Keys.menuBarSpend) as? Bool ?? false
        self.snapshot = UsageSnapshot.loadCached()
        self.updatedAt = self.snapshot?.generatedAt
        self.account = Account.load()
        self.limits = PlanLimits.loadCached()
        self.limitsCheckedAt = self.limits?.fetchedAt ?? .distantPast

        self.watcher = FileWatcher(paths: self.scanner.watchedPaths) { [weak self] in
            self?.refresh()
        }
        // Day and window rollovers happen without any file changing.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.refreshLimits()
            }
        }
        // Common modes keep it firing while the menu is open (event-tracking run loop mode).
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        self.refresh()
        self.refreshLimits()
        Task { [scanner] in
            if let prices = await PriceCatalog.refreshIfStale() {
                scanner.updatePrices(prices)
                self.refresh()
            }
        }
    }

    /// Coalesces bursts: at most one scan runs, and at most one more is queued behind it.
    func refresh() {
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
        self.scanQueue.async { [scanner] in
            let (snapshot, _) = scanner.scan(now: started, settings: settings)
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
            withAnimation(.smooth(duration: 0.55)) {
                self.snapshot = new
            }
            new.saveCache()
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
        if self.account == nil { self.account = Account.load() }
    }

    // MARK: Limits

    /// Fetches limits unless a fetch is running, the last one is younger than `minimumAge`, or the
    /// server asked us to back off. The usage endpoint rate-limits eagerly: every 3 minutes in the
    /// background, at most once a minute when the menu opens.
    func refreshLimits(minimumAge: TimeInterval = 170) {
        let now = Date()
        guard self.limitsTask == nil, now >= self.limitsBlockedUntil,
              now.timeIntervalSince(self.limitsCheckedAt) >= minimumAge else { return }
        self.limitsCheckedAt = now
        self.limitsTask = Task {
            let result: Result<PlanLimits, LimitsError>
            do throws(LimitsError) { result = .success(try await LimitsClient.fetch()) } catch { result = .failure(error) }
            self.apply(result)
            self.limitsTask = nil
        }
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
            new.saveCache()
            self.limitsIssue = nil
            if let reset = new.weekly?.resetsAt { self.adoptWeeklyReset(reset) }
        case let .failure(.rateLimited(retryAfter)):
            self.limitsBlockedUntil = Date().addingTimeInterval(retryAfter)
        case .failure(.failed):
            break // Offline or a hiccup: keep the last values, try again next minute.
        case let .failure(issue):
            if issue != self.limitsIssue { withAnimation(.smooth) { self.limitsIssue = issue } }
        }
    }

    /// Windows are counted from the reset Anthropic reports; only move them if it really changed.
    private func adoptWeeklyReset(_ reset: Date) {
        let week = WindowSettings.length
        let offset = (reset.timeIntervalSince(self.windowSettings.anchor).truncatingRemainder(dividingBy: week) + week)
            .truncatingRemainder(dividingBy: week)
        guard min(offset, week - offset) > 60 else { return }
        self.windowSettings = WindowSettings(anchor: reset)
    }

    func reloadAccount() {
        let account = Account.load()
        if account != self.account { self.account = account }
    }

    var loginItemToken: Int { self.loginItemRevision }
}
