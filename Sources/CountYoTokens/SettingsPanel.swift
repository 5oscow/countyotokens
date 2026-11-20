import SwiftUI
import TokenCore

/// Settings window: the weekly reset that pins the windows, and two switches. System Settings style.
struct SettingsPanel: View {
    @Environment(UsageStore.self) private var store

    private var calendar: Calendar { .current }

    var body: some View {
        @Bindable var store = self.store
        Form {
            Section {
                Picker("Resets on", selection: self.weekday) {
                    ForEach(1 ... 7, id: \.self) { day in
                        Text(self.calendar.weekdaySymbols[day - 1]).tag(day)
                    }
                }
                DatePicker("At", selection: self.time, displayedComponents: .hourAndMinute)
            } header: {
                Text("Weekly window")
            } footer: {
                Text("Use the weekly reset time Claude shows for your plan. Every past and future window is counted from it.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Toggle("Show today's spend in the menu bar", isOn: $store.showsSpendInMenuBar)
                Toggle("Open at login", isOn: Binding(
                    get: { _ = store.loginItemToken; return store.opensAtLogin },
                    set: { store.opensAtLogin = $0 }))
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Weekday of the reset, in local time.
    private var weekday: Binding<Int> {
        Binding(
            get: { self.calendar.component(.weekday, from: self.store.windowSettings.anchor) },
            set: { self.setAnchor(weekday: $0, time: self.store.windowSettings.anchor) })
    }

    private var time: Binding<Date> {
        Binding(
            get: { self.store.windowSettings.anchor },
            set: { self.setAnchor(weekday: self.calendar.component(.weekday, from: self.store.windowSettings.anchor), time: $0) })
    }

    /// Any one reset instant pins every window, so store the next matching one.
    private func setAnchor(weekday: Int, time: Date) {
        let parts = self.calendar.dateComponents([.hour, .minute], from: time)
        var match = DateComponents()
        match.weekday = weekday
        match.hour = parts.hour
        match.minute = parts.minute
        // Claude resets at hh:59:59; keep that second so the window edge lands on the reset itself.
        match.second = parts.minute == 59 ? 59 : 0
        guard let next = self.calendar.nextDate(after: Date(), matching: match, matchingPolicy: .nextTime) else { return }
        self.store.windowSettings = WindowSettings(anchor: next)
    }
}
