import Foundation
import Observation
import TokenCore

/// Every switch in Settings, saved to UserDefaults as it changes.
@Observable
@MainActor
final class Preferences {
    // MARK: General

    var limitsInterval: RefreshInterval { didSet { self.save(self.limitsInterval.rawValue, Keys.limitsInterval) } }
    var refreshesOnOpen: Bool { didSet { self.save(self.refreshesOnOpen, Keys.refreshesOnOpen) } }
    /// 0 follows each plan's weekly reset; 1…7 pins every provider to that weekday (1 = Sunday).
    var weekStart: Int { didSet { self.save(self.weekStart, Keys.weekStart) } }

    // MARK: Menu bar

    var menuBarDisplay: MenuBarDisplay { didSet { self.save(self.menuBarDisplay.rawValue, Keys.menuBar) } }
    /// nil follows the provider selected in the menu.
    var menuBarProvider: ProviderID? { didSet { self.save(self.menuBarProvider?.rawValue ?? "", Keys.menuBarProvider) } }
    var iconStyle: IconStyle { didSet { self.save(self.iconStyle.rawValue, Keys.iconStyle) } }
    var warnsInMenuBar: Bool { didSet { self.save(self.warnsInMenuBar, Keys.warnsInMenuBar) } }

    // MARK: Menu

    var showsLimits: Bool { didSet { self.save(self.showsLimits, Keys.showsLimits) } }
    var showsPace: Bool { didSet { self.save(self.showsPace, Keys.showsPace) } }
    var showsToday: Bool { didSet { self.save(self.showsToday, Keys.showsToday) } }
    var showsHistory: Bool { didSet { self.save(self.showsHistory, Keys.showsHistory) } }
    var showsWindows: Bool { didSet { self.save(self.showsWindows, Keys.showsWindows) } }
    var showsTopModel: Bool { didSet { self.save(self.showsTopModel, Keys.showsTopModel) } }
    var limitFigure: LimitFigure { didSet { self.save(self.limitFigure.rawValue, Keys.limitFigure) } }
    var resetStyle: ResetStyle { didSet { self.save(self.resetStyle.rawValue, Keys.resetStyle) } }
    var hidesEmail: Bool { didSet { self.save(self.hidesEmail, Keys.hidesEmail) } }

    // MARK: Notifications

    var notifiesLow: Bool { didSet { self.save(self.notifiesLow, Keys.notifiesLow) } }
    var lowThreshold: Int { didSet { self.save(self.lowThreshold, Keys.lowThreshold) } }
    var notifiesReset: Bool { didSet { self.save(self.notifiesReset, Keys.notifiesReset) } }
    var notifiesSpend: Bool { didSet { self.save(self.notifiesSpend, Keys.notifiesSpend) } }
    var spendThreshold: Int { didSet { self.save(self.spendThreshold, Keys.spendThreshold) } }

    // MARK: Providers

    /// Switcher order; every provider appears exactly once.
    var order: [ProviderID] { didSet { self.save(self.order.map(\.rawValue), Keys.order) } }

    private enum Keys {
        static let limitsInterval = "limitsInterval"
        static let refreshesOnOpen = "refreshesOnOpen"
        static let weekStart = "weekStart"
        static let menuBar = "menuBarDisplay"
        static let menuBarProvider = "menuBarProvider"
        static let iconStyle = "iconStyle"
        static let warnsInMenuBar = "warnsInMenuBar"
        static let showsLimits = "showsLimits"
        static let showsPace = "showsPace"
        static let showsToday = "showsToday"
        static let showsHistory = "showsHistory"
        static let showsWindows = "showsWindows"
        static let showsTopModel = "showsTopModel"
        static let limitFigure = "limitFigure"
        static let resetStyle = "resetStyle"
        static let hidesEmail = "hidesEmail"
        static let notifiesLow = "notifiesLow"
        static let lowThreshold = "lowThreshold"
        static let notifiesReset = "notifiesReset"
        static let notifiesSpend = "notifiesSpend"
        static let spendThreshold = "spendThreshold"
        static let order = "providerOrder"

        static let all = [limitsInterval, refreshesOnOpen, weekStart, menuBar, menuBarProvider, iconStyle, warnsInMenuBar,
                          showsLimits, showsPace, showsToday, showsHistory, showsWindows, showsTopModel, limitFigure,
                          resetStyle, hidesEmail, notifiesLow, lowThreshold, notifiesReset, notifiesSpend,
                          spendThreshold, order]
    }

    init() {
        let d = UserDefaults.standard
        func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }
        func int(_ key: String, _ fallback: Int) -> Int { d.object(forKey: key) as? Int ?? fallback }
        func value<T: RawRepresentable<String>>(_ key: String, _ fallback: T) -> T {
            d.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
        }
        self.limitsInterval = RefreshInterval(rawValue: int(Keys.limitsInterval, RefreshInterval.threeMinutes.rawValue)) ?? .threeMinutes
        self.refreshesOnOpen = bool(Keys.refreshesOnOpen, true)
        self.weekStart = min(7, max(0, int(Keys.weekStart, 0)))
        self.menuBarDisplay = value(Keys.menuBar, d.bool(forKey: "showsSpendInMenuBar") ? MenuBarDisplay.spend : .icon)
        self.menuBarProvider = d.string(forKey: Keys.menuBarProvider).flatMap(ProviderID.init(rawValue:))
        self.iconStyle = value(Keys.iconStyle, IconStyle.tally)
        self.warnsInMenuBar = bool(Keys.warnsInMenuBar, true)
        self.showsLimits = bool(Keys.showsLimits, true)
        self.showsPace = bool(Keys.showsPace, true)
        self.showsToday = bool(Keys.showsToday, true)
        self.showsHistory = bool(Keys.showsHistory, true)
        self.showsWindows = bool(Keys.showsWindows, true)
        self.showsTopModel = bool(Keys.showsTopModel, true)
        self.limitFigure = value(Keys.limitFigure, LimitFigure.left)
        self.resetStyle = value(Keys.resetStyle, ResetStyle.countdown)
        self.hidesEmail = bool(Keys.hidesEmail, false)
        self.notifiesLow = bool(Keys.notifiesLow, false)
        self.lowThreshold = int(Keys.lowThreshold, 20)
        self.notifiesReset = bool(Keys.notifiesReset, false)
        self.notifiesSpend = bool(Keys.notifiesSpend, false)
        self.spendThreshold = max(1, int(Keys.spendThreshold, 50))
        let stored = (d.array(forKey: Keys.order) as? [String] ?? []).compactMap(ProviderID.init(rawValue:))
        self.order = Self.complete(stored)
        d.removeObject(forKey: "showsSpendInMenuBar")
    }

    /// Keeps a saved order and appends providers added since, so none is ever missing.
    private static func complete(_ order: [ProviderID]) -> [ProviderID] {
        var seen = Set<ProviderID>()
        let kept = order.filter { seen.insert($0).inserted }
        return kept + ProviderID.allCases.filter { !seen.contains($0) }
    }

    func move(from source: IndexSet, to destination: Int) {
        self.order.move(fromOffsets: source, toOffset: destination)
    }

    /// Back to how a fresh install starts. Keys and the provider selection stay.
    func reset() {
        for key in Keys.all { UserDefaults.standard.removeObject(forKey: key) }
        let fresh = Preferences()
        self.limitsInterval = fresh.limitsInterval
        self.refreshesOnOpen = fresh.refreshesOnOpen
        self.weekStart = fresh.weekStart
        self.menuBarDisplay = fresh.menuBarDisplay
        self.menuBarProvider = fresh.menuBarProvider
        self.iconStyle = fresh.iconStyle
        self.warnsInMenuBar = fresh.warnsInMenuBar
        self.showsLimits = fresh.showsLimits
        self.showsPace = fresh.showsPace
        self.showsToday = fresh.showsToday
        self.showsHistory = fresh.showsHistory
        self.showsWindows = fresh.showsWindows
        self.showsTopModel = fresh.showsTopModel
        self.limitFigure = fresh.limitFigure
        self.resetStyle = fresh.resetStyle
        self.hidesEmail = fresh.hidesEmail
        self.notifiesLow = fresh.notifiesLow
        self.lowThreshold = fresh.lowThreshold
        self.notifiesReset = fresh.notifiesReset
        self.notifiesSpend = fresh.notifiesSpend
        self.spendThreshold = fresh.spendThreshold
        self.order = fresh.order
    }

    private func save(_ value: Any, _ key: String) { UserDefaults.standard.set(value, forKey: key) }
}

enum RefreshInterval: Int, CaseIterable, Identifiable {
    case twoMinutes = 120, threeMinutes = 180, fiveMinutes = 300, tenMinutes = 600, fifteenMinutes = 900
    case manual = 0
    var id: Int { self.rawValue }
    var title: String { self == .manual ? "Only when I ask" : "Every \(self.rawValue / 60) minutes" }
    /// A little under the interval, so a timer tick that lands a few seconds early still fetches.
    var minimumAge: TimeInterval? { self == .manual ? nil : TimeInterval(self.rawValue - 10) }
}

enum MenuBarDisplay: String, CaseIterable, Identifiable {
    case icon, spend, window, limit
    var id: String { self.rawValue }
    var title: String {
        switch self {
        case .icon: "Nothing"
        case .spend: "Today's spend"
        case .window: "This window's spend"
        case .limit: "Lowest limit left"
        }
    }
}

enum IconStyle: String, CaseIterable, Identifiable {
    case tally, meter, logo
    var id: String { self.rawValue }
    var title: String {
        switch self {
        case .tally: "Tally marks"
        case .meter: "Limit meter"
        case .logo: "Provider logo"
        }
    }
}

enum LimitFigure: String, CaseIterable, Identifiable {
    case left, used
    var id: String { self.rawValue }
    var title: String { self == .left ? "Percent left" : "Percent used" }
}

enum ResetStyle: String, CaseIterable, Identifiable {
    case countdown, clock
    var id: String { self.rawValue }
    var title: String { self == .countdown ? "Time remaining" : "Date and time" }
}
