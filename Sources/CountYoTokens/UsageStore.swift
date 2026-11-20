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

    private enum Keys {
        static let anchor = "windowAnchor"
        static let menuBarSpend = "showsSpendInMenuBar"
    }

    /// The account's weekly reset when this fork was made; change it in settings if yours differs.
    nonisolated static let defaultAnchor = Date(timeIntervalSince1970: 1_795_229_999) // Fri 21 Nov 2026 02:59:59 UTC

    init() {
        let defaults = UserDefaults.standard
        let anchor = defaults.object(forKey: Keys.anchor) as? Double
        self.windowSettings = WindowSettings(anchor: anchor.map(Date.init(timeIntervalSince1970:)) ?? Self.defaultAnchor)
        self.showsSpendInMenuBar = defaults.object(forKey: Keys.menuBarSpend) as? Bool ?? false
        self.snapshot = UsageSnapshot.loadCached()
        self.updatedAt = self.snapshot?.generatedAt
        self.account = Account.load()

        self.watcher = FileWatcher(paths: self.scanner.watchedPaths) { [weak self] in
            self?.refresh()
        }
        // Day and window rollovers happen without any file changing.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Common modes keep it firing while the menu is open (event-tracking run loop mode).
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        self.refresh()
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

    func reloadAccount() {
        let account = Account.load()
        if account != self.account { self.account = account }
    }

    var loginItemToken: Int { self.loginItemRevision }
}
