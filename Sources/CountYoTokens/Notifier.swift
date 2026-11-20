import AppKit
import TokenCore
import UserNotifications

/// Low-limit, reset and daily-spend alerts. Checked once a minute; each alert fires once per window
/// (or once per day for spend), remembered across relaunches.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    enum Permission { case unknown, allowed, denied }

    /// Low limits waiting for their reset, keyed `provider.limit`, valued with the reset time.
    private var lowUntil: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: "notifier.low") as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "notifier.low") }
    }

    /// Day (yyyy-MM-dd) each provider's spend alert last fired.
    private var spendDay: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "notifier.spend") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "notifier.spend") }
    }

    /// No bundle when run from `swift run`: notifications need a real app.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func start() {
        self.center?.delegate = self
    }

    func permission() async -> Permission {
        guard let center = self.center else { return .denied }
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .denied: return .denied
        default: return .unknown
        }
    }

    /// Asks once; afterwards macOS remembers the answer and System Settings owns it.
    @discardableResult
    func requestPermission() async -> Permission {
        guard let center = self.center else { return .denied }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        return await self.permission()
    }

    func check(_ store: UsageStore) {
        let prefs = store.prefs
        guard prefs.notifiesLow || prefs.notifiesReset || prefs.notifiesSpend else { return }
        let now = Date()
        var low = self.lowUntil

        // Resets first, so a limit that reset and ran low again in one go is announced in order.
        for (key, until) in low where until <= now.timeIntervalSince1970 {
            low[key] = nil
            guard prefs.notifiesReset, let (model, limit) = self.find(key, in: store) else { continue }
            self.post(id: "reset.\(key)", title: "\(model.id.displayName) \(limit.title.lowercased()) limit reset",
                      body: "It's back to 100%.")
        }

        for id in store.enabled {
            guard let model = store.providers[id], let limits = model.limits else { continue }
            for limit in limits.items {
                guard let reset = limit.resetsAt, reset > now else { continue }
                let key = "\(id.rawValue).\(limit.id)"
                let left = limit.leftPercent
                if left <= Double(prefs.lowThreshold), low[key] == nil {
                    low[key] = reset.timeIntervalSince1970
                    if prefs.notifiesLow {
                        self.post(id: "low.\(key)", title: "\(id.displayName) \(limit.title.lowercased()) limit at \(Int(left.rounded()))%",
                                  body: "Resets in \(Format.countdown(to: reset, from: now)).")
                    }
                } else if low[key] != nil {
                    // The reset moved (rolling windows): follow it.
                    low[key] = reset.timeIntervalSince1970
                }
            }
        }
        // Forget limits that no longer exist, so the list can't grow without end.
        low = low.filter { now.timeIntervalSince1970 - $0.value < 40 * 86_400 }
        if low != self.lowUntil { self.lowUntil = low }

        if prefs.notifiesSpend {
            let today = now.formatted(.iso8601.year().month().day())
            var fired = self.spendDay
            for id in store.enabled where id.hasSpend {
                guard let snapshot = store.providers[id]?.snapshot, !snapshot.measuresTokens,
                      let cost = snapshot.today?.cost, cost >= Double(prefs.spendThreshold),
                      fired[id.rawValue] != today
                else { continue }
                fired[id.rawValue] = today
                self.post(id: "spend.\(id.rawValue)", title: "\(id.displayName): \(Format.money(cost)) today",
                          body: "Past the \(Format.wholeMoney(Double(prefs.spendThreshold))) a day you set.")
            }
            if fired != self.spendDay { self.spendDay = fired }
        }
    }

    func sendTest() {
        self.post(id: "test", title: "count yo tokens", body: "Notifications are working.")
    }

    private func find(_ key: String, in store: UsageStore) -> (ProviderModel, PlanLimits.Limit)? {
        let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = ProviderID(rawValue: parts[0]), store.isEnabled(id),
              let model = store.providers[id], let limit = model.limits?.items.first(where: { $0.id == parts[1] })
        else { return nil }
        return (model, limit)
    }

    private func post(id: String, title: String, body: String) {
        guard let center = self.center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // Show banners even while Settings is in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions
    {
        [.banner, .sound]
    }
}
