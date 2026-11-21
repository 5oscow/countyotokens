import AppKit
import SwiftUI
import TokenCore

// MARK: - Window

enum SettingsPane: Hashable {
    case general, menuBar, menu, notifications, provider(ProviderID), advanced, about

    static let top: [SettingsPane] = [.general, .menuBar, .menu, .notifications]
    static let bottom: [SettingsPane] = [.advanced, .about]

    /// `general`, `menu-bar`, `claude`, … as in the snapshot file names.
    static func named(_ name: String) -> SettingsPane? {
        if let id = ProviderID(rawValue: name) { return .provider(id) }
        return (self.top + self.bottom).first { $0.title.lowercased().replacingOccurrences(of: " ", with: "-") == name }
    }

    var title: String {
        switch self {
        case .general: "General"
        case .menuBar: "Menu Bar"
        case .menu: "Menu"
        case .notifications: "Notifications"
        case let .provider(id): id.displayName
        case .advanced: "Advanced"
        case .about: "About"
        }
    }

    /// Providers wear their own logo instead.
    var symbol: String? {
        switch self {
        case .general: "gearshape.fill"
        case .menuBar: "menubar.rectangle"
        case .menu: "list.bullet.rectangle.fill"
        case .notifications: "bell.badge.fill"
        case .provider: nil
        case .advanced: "wrench.and.screwdriver.fill"
        case .about: "info.circle.fill"
        }
    }

    /// How much of the tile a symbol's longer side spans, so wide and tall symbols look one size.
    var symbolScale: CGFloat {
        switch self {
        case .menuBar, .menu: 0.66
        case .about: 0.62
        default: 0.58
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .menuBar: .blue
        case .menu: .indigo
        case .notifications: .red
        case let .provider(id): id.tint
        case .advanced: .gray
        case .about: Theme.accent
        }
    }
}

/// A System Settings–style window: a sidebar of panes, each a grouped form.
enum SettingsWindow {
    @MainActor
    static func make(store: UsageStore) -> NSWindow {
        let controller = NSHostingController(rootView: SettingsView().environment(store))
        controller.sizingOptions = []
        // No toolbar: its strip ran 2 pt past the sidebar's edge, put the title 21 pt left of the
        // content, and hides anything drawn beneath it. The pane draws its own title in the title bar.
        controller.sceneBridgingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 720, height: 500)
        window.setContentSize(NSSize(width: 800, height: 580))
        return window
    }

    /// The title bar's height, which the pane title shares with the window buttons.
    static let titleBarHeight: CGFloat = 28

    /// Dead centre of the usable part of the screen the pointer is on (NSWindow.center() sits it
    /// a third of the way down instead).
    @MainActor
    static func centre(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { return }
        let area = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded()))
    }
}

struct SettingsView: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        @Bindable var store = self.store
        NavigationSplitView {
            SettingsSidebar(selection: $store.settingsPane)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            SettingsDetail(pane: self.store.settingsPane)
                .id(self.store.settingsPane)
                .padding(.top, 12)
                .overlay(alignment: .topLeading) {
                    // Level with the window buttons, and on the same left edge as the section titles.
                    // Its frame reaches below the title bar: views wholly inside that band aren't drawn.
                    Text(self.store.settingsPane.title)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(height: SettingsWindow.titleBarHeight)
                        .padding(.leading, 31)
                        .frame(height: SettingsWindow.titleBarHeight + 12, alignment: .top)
                        .offset(y: -SettingsWindow.titleBarHeight)
                        .allowsHitTesting(false)
                }
        }
        .toolbar(removing: .sidebarToggle)
        // Switches, links and selections in the app's own colour rather than the system blue.
        .tint(Theme.accent)
        .frame(minWidth: 720, minHeight: 500)
    }
}

private struct SettingsSidebar: View {
    @Environment(UsageStore.self) private var store
    @Binding var selection: SettingsPane

    var body: some View {
        // No List selection: macOS paints that in the accent blue. Rows are buttons, and the chosen
        // one gets the same soft fill the menu uses.
        List {
            Section {
                ForEach(SettingsPane.top, id: \.self) { self.row($0) }
            }
            Section {
                ForEach(self.store.prefs.order) { self.row(.provider($0)) }
                    .onMove { self.store.prefs.move(from: $0, to: $1) }
            } header: {
                Text("Providers")
            }
            Section {
                ForEach(SettingsPane.bottom, id: \.self) { self.row($0) }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ pane: SettingsPane) -> some View {
        Button {
            self.selection = pane
        } label: {
            SidebarRow(pane: pane)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(pane == self.selection ? 0.1 : 0))
                .padding(.horizontal, 10))
        .accessibilityAddTraits(pane == self.selection ? .isSelected : [])
    }
}

private struct SidebarRow: View {
    @Environment(UsageStore.self) private var store
    let pane: SettingsPane

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(self.pane.title)
                    .foregroundStyle(self.isOff ? .secondary : .primary)
                Spacer(minLength: 0)
                if case let .provider(id) = self.pane, !self.isOff {
                    // Only trouble gets a dot; a dimmed name already says a provider is off.
                    let status = ProviderStatus(model: self.store.providers[id]!, enabled: true)
                    if status.level == .attention { StatusDot(status: status) }
                }
            }
        } icon: {
            PaneIcon(pane: self.pane, size: 20)
        }
    }

    private var isOff: Bool {
        if case let .provider(id) = self.pane { !self.store.isEnabled(id) } else { false }
    }
}

/// White symbol on a coloured rounded square, the way System Settings marks its panes. Providers
/// get their own logo on their brand colour.
struct PaneIcon: View {
    let pane: SettingsPane
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: self.size * 0.26, style: .continuous)
            .fill(self.pane.tint.gradient)
            .frame(width: self.size, height: self.size)
            .overlay {
                if case let .provider(id) = self.pane {
                    ProviderLogo(id: id, size: self.size * 0.6 * id.opticalScale)
                } else if let symbol = self.pane.symbol {
                    Image(systemName: symbol)
                        .resizable()
                        .fontWeight(.semibold)
                        .scaledToFit()
                        .frame(width: self.size * self.pane.symbolScale, height: self.size * self.pane.symbolScale)
                }
            }
            .foregroundStyle(.white)
            .overlay {
                // Keeps the near-black tiles from melting into a dark sidebar.
                RoundedRectangle(cornerRadius: self.size * 0.26, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            }
    }
}

private struct SettingsDetail: View {
    let pane: SettingsPane

    var body: some View {
        switch self.pane {
        case .general: GeneralPane()
        case .menuBar: MenuBarPane()
        case .menu: MenuPane()
        case .notifications: NotificationsPane()
        case let .provider(id): ProviderPane(id: id)
        case .advanced: AdvancedPane()
        case .about: AboutPane()
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        @Bindable var store = self.store
        @Bindable var prefs = self.store.prefs
        Form {
            Section {
                SettingRow("Open at login", detail: "Starts quietly in the menu bar when you log in.", isOn: $store.opensAtLogin)
            }
            Section {
                SettingRow("Check plan limits", detail: "Providers turn away requests that come too often, so a few minutes apart is plenty.") {
                    Picker("Check plan limits", selection: $prefs.limitsInterval) {
                        ForEach(RefreshInterval.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingRow("Check when the menu opens", detail: "At most once a minute, for the provider you're looking at.", isOn: $prefs.refreshesOnOpen)
                SettingRow("Spend", detail: "Read from local logs within a second of them changing.") {
                    Button("Refresh All") { self.store.refreshAll() }
                }
            } header: {
                Text("Updates")
            }
            Section {
                SettingRow("Weeks start", detail: "Weekly windows in the menu line up with this. Providers without a weekly limit start on Monday.") {
                    Picker("Weeks start", selection: Binding(get: { prefs.weekStart }, set: { self.store.setWeekStart($0) })) {
                        Text("Each plan's weekly reset").tag(0)
                        Divider()
                        ForEach(Self.weekdays, id: \.self) { day in
                            Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            } header: {
                Text("Weekly windows")
            }
        }
        .formStyle(.grouped)
    }

    /// Monday first, the way most of the world counts.
    private static let weekdays = [2, 3, 4, 5, 6, 7, 1]
}

// MARK: - Menu bar

private struct MenuBarPane: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        @Bindable var prefs = self.store.prefs
        Form {
            Section {
                MenuBarPreview()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            Section {
                Picker("Icon", selection: $prefs.iconStyle) {
                    ForEach(IconStyle.allCases) { style in
                        Label {
                            Text(style.title)
                        } icon: {
                            switch style {
                            case .tally: Image(nsImage: StatusIcon.image)
                            case .meter: Image(nsImage: StatusIcon.meter([72, 40]))
                            case .logo: Image(nsImage: ProviderLogos.statusImage(self.store.menuBarModel.id))
                            }
                        }
                        .tag(style)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelStyle(.titleAndIcon)
            } header: {
                Text("Icon")
            } footer: {
                Footnote("The meter fills like a battery with the first two limits left: the session on top, the week below. Providers without limits keep the tally. The logo follows the provider the text is for.")
            }
            Section {
                Picker("Show next to the icon", selection: $prefs.menuBarDisplay) {
                    ForEach(MenuBarDisplay.allCases) { Text($0.title).tag($0) }
                }
                Picker("For", selection: $prefs.menuBarProvider) {
                    Text("The provider shown in the menu").tag(ProviderID?.none)
                    Divider()
                    ForEach(self.store.enabled) { id in
                        Label {
                            Text(id.displayName)
                        } icon: {
                            Image(nsImage: ProviderLogos.statusImage(id))
                        }
                        .tag(ProviderID?.some(id))
                    }
                }
                SettingRow("Turn red when a limit is nearly used up", detail: "Under 10% left, with “Lowest limit left” shown.", isOn: $prefs.warnsInMenuBar)
                .disabled(prefs.menuBarDisplay != .limit)
            } header: {
                Text("Text")
            } footer: {
                Footnote("OpenCode records tokens rather than prices, so Go and Zen show tokens here.")
            }
        }
        .formStyle(.grouped)
    }
}

/// A strip of menu bar with the icon and text exactly as they'll look.
private struct MenuBarPreview: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        let prefs = self.store.prefs
        let model = self.store.menuBarModel
        HStack(spacing: 14) {
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            HStack(spacing: 3) {
                Image(nsImage: StatusIcon.current(prefs.iconStyle, model: model).image())
                    .renderingMode(.template)
                if let text = self.text(model, prefs: prefs), !text.isEmpty {
                    Text(text)
                        .monospacedDigit()
                        .foregroundStyle(self.isRed(model, prefs: prefs) ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Image(systemName: "magnifyingglass")
            Text(Date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(.bar, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .animation(.smooth(duration: 0.25), value: prefs.menuBarDisplay)
        .animation(.smooth(duration: 0.25), value: prefs.iconStyle)
    }

    private func text(_ model: ProviderModel, prefs: Preferences) -> String? {
        let snapshot = model.snapshot
        func amount(_ cost: Double?, _ tokens: Int?) -> String? {
            guard model.id.hasSpend, let cost, let tokens else { return nil }
            return snapshot?.measuresTokens == true ? Format.tokens(tokens) : Format.wholeMoney(cost)
        }
        return switch prefs.menuBarDisplay {
        case .icon: nil
        case .spend: amount(snapshot?.today?.cost, snapshot?.today?.tokens)
        case .window: amount(snapshot?.currentWindow?.cost, snapshot?.currentWindow?.tokens)
        case .limit: model.lowestLeft.map { "\(Int($0.rounded()))%" }
        }
    }

    private func isRed(_ model: ProviderModel, prefs: Preferences) -> Bool {
        prefs.warnsInMenuBar && prefs.menuBarDisplay == .limit && (model.lowestLeft ?? 100) < 10
    }
}

// MARK: - Menu

private struct MenuPane: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        @Bindable var prefs = self.store.prefs
        Form {
            Section {
                SettingRow("Plan limits", detail: "Session, weekly and other windows, with how long until each resets.", isOn: $prefs.showsLimits)
                SettingRow("Pace", detail: "Whether you're ahead of or behind an even pace, and when you'd run out.", isOn: $prefs.showsPace)
                .disabled(!prefs.showsLimits)
                .padding(.leading, 18)
                SettingRow("Today and this window", detail: "The two big figures.", isOn: $prefs.showsToday)
                SettingRow("Last 30 days", detail: "A bar for each day. Hover one for its figure.", isOn: $prefs.showsHistory)
                SettingRow("Weekly windows", detail: "Spend in this week's window and the three before it.", isOn: $prefs.showsWindows)
                SettingRow("Top model", detail: "The model behind most of the spend.", isOn: $prefs.showsTopModel)
            } header: {
                Text("Sections")
            }
            Section {
                Picker("Limits show", selection: $prefs.limitFigure) {
                    ForEach(LimitFigure.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Reset times", selection: $prefs.resetStyle) {
                    ForEach(ResetStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Limits")
            } footer: {
                let sample = Date().addingTimeInterval(2 * 3600 + 5 * 60)
                Footnote("Looks like “\(Format.reset(sample, now: Date(), style: prefs.resetStyle))”.")
            }
            Section {
                SettingRow("Hide email address", detail: "Shows \(ProviderModel.masked("you@example.com")) instead, for screen sharing.", isOn: $prefs.hidesEmail)
            } header: {
                Text("Privacy")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Notifications

private struct NotificationsPane: View {
    @Environment(UsageStore.self) private var store
    @State private var permission: Notifier.Permission = .unknown

    var body: some View {
        @Bindable var prefs = self.store.prefs
        Form {
            if self.permission == .denied {
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "bell.slash.fill").foregroundStyle(Theme.deficit)
                        Text("Notifications for count yo tokens are turned off in System Settings.")
                        Spacer()
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.sirrayi.countyotokens")!)
                        }
                    }
                }
            }
            Section {
                SettingRow("When a limit runs low", detail: "Once per window, for every provider in the menu.", isOn: self.asking($prefs.notifiesLow))
                Picker("Below", selection: $prefs.lowThreshold) {
                    ForEach([50, 25, 20, 10, 5], id: \.self) { Text("\($0)% left").tag($0) }
                }
                .disabled(!prefs.notifiesLow)
                .padding(.leading, 18)
                SettingRow("When a low limit resets", detail: "So you know you can get back to it.", isOn: self.asking($prefs.notifiesReset))
            } header: {
                Text("Limits")
            }
            Section {
                SettingRow("When a day's spend passes an amount", detail: "Once a day per provider, at API prices.", isOn: self.asking($prefs.notifiesSpend))
                LabeledContent("Amount") {
                    HStack(spacing: 6) {
                        TextField("Amount", value: $prefs.spendThreshold, format: .currency(code: "USD").precision(.fractionLength(0)).locale(Locale(identifier: "en_US")))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Stepper("Amount", value: $prefs.spendThreshold, in: 1 ... 10_000, step: 10)
                            .labelsHidden()
                    }
                }
                .disabled(!prefs.notifiesSpend)
                .padding(.leading, 18)
            } header: {
                Text("Spend")
            }
            Section {
                SettingRow("Test notification",
                           detail: self.permission == .allowed ? "Notifications are allowed." : "macOS asks for permission the first time.") {
                    Button("Send Test") {
                        Task {
                            self.permission = await Notifier.shared.requestPermission()
                            Notifier.shared.sendTest()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { self.permission = await Notifier.shared.permission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { self.permission = await Notifier.shared.permission() }
        }
    }

    /// Turning an alert on asks macOS for permission first.
    private func asking(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding {
            binding.wrappedValue
        } set: { on in
            binding.wrappedValue = on
            guard on else { return }
            Task {
                self.permission = await Notifier.shared.requestPermission()
                Notifier.shared.check(self.store)
            }
        }
    }
}

// MARK: - Providers

/// One line of state per provider, shared by the sidebar dot and the pane header.
struct ProviderStatus {
    enum Level { case ok, attention, off }
    var level: Level
    var text: String

    @MainActor
    init(model: ProviderModel, enabled: Bool) {
        guard enabled else {
            self = .init(level: .off, text: "Not in the menu")
            return
        }
        if let issue = model.limitsIssue {
            let text = issue == .needsKey
                ? (model.id == .devin ? "Needs a Devin CLI sign-in" : "Needs an API key")
                : model.message(for: issue)
            self = .init(level: .attention, text: text)
        } else if let limits = model.limits, limits.fetchedAt > .distantPast {
            self = .init(level: .ok, text: "Limits " + Format.updated(limits.fetchedAt, now: Date()).lowercased())
        } else if !model.id.hasLimits, model.snapshot != nil {
            self = .init(level: .ok, text: "Reading OpenCode history")
        } else {
            self = .init(level: .attention, text: "Waiting for the first update")
        }
    }

    private init(level: Level, text: String) {
        self.level = level
        self.text = text
    }
}

private struct StatusDot: View {
    let status: ProviderStatus

    var body: some View {
        Circle()
            .fill(self.color)
            .frame(width: 7, height: 7)
            .help(self.status.text)
    }

    private var color: Color {
        switch self.status.level {
        case .ok: Theme.reserve
        case .attention: Theme.deficit
        case .off: Color.secondary.opacity(0.35)
        }
    }
}

private struct ProviderPane: View {
    @Environment(UsageStore.self) private var store
    let id: ProviderID

    var body: some View {
        let model = self.store.providers[self.id]!
        let enabled = self.store.isEnabled(self.id)
        let status = ProviderStatus(model: model, enabled: enabled)
        Form {
            Section {
                HStack(spacing: 12) {
                    PaneIcon(pane: .provider(self.id), size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(self.id.displayName)
                            .font(.system(size: 15, weight: .semibold))
                        HStack(spacing: 5) {
                            StatusDot(status: status)
                            Text(status.text)
                                .foregroundStyle(status.level == .attention ? AnyShapeStyle(Theme.deficit) : AnyShapeStyle(.secondary))
                        }
                        .font(.system(size: 11.5))
                    }
                    Spacer()
                    Toggle("Show in menu", isOn: Binding(get: { enabled }, set: { self.store.setEnabled(self.id, $0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(enabled && self.store.enabled.count == 1)
                        .help(enabled && self.store.enabled.count == 1 ? "At least one provider stays in the menu." : "Show in the menu")
                }
                .padding(.vertical, 2)
            }

            if enabled, self.id.hasLimits, let limits = model.limits, !limits.items.isEmpty {
                Section {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        VStack(spacing: 10) {
                            ForEach(limits.items) { limit in
                                LimitSummary(limit: limit, now: context.date)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                } header: {
                    Text("Limits now")
                }
            }

            if enabled, self.id.hasSpend, let snapshot = model.snapshot {
                Section {
                    let tokensOnly = snapshot.measuresTokens
                    LabeledContent("Today", value: Self.figure(snapshot.today?.cost ?? 0, snapshot.today?.tokens ?? 0, tokensOnly))
                    LabeledContent("This window", value: Self.figure(snapshot.currentWindow?.cost ?? 0,
                                                                     snapshot.currentWindow?.tokens ?? 0, tokensOnly))
                    LabeledContent("Last 30 days", value: Self.figure(snapshot.historyCost, snapshot.historyTokens, tokensOnly))
                    if let top = snapshot.topModel {
                        LabeledContent("Top model", value: "\(Format.model(top.model)) · \(Int((top.share * 100).rounded()))%")
                    }
                } header: {
                    Text("Spend")
                } footer: {
                    Footnote(self.id.spendNote + ".")
                }
            }

            Section {
                if let plan = model.plan {
                    LabeledContent("Plan", value: plan)
                }
                if self.id == .claude, let email = model.account?.email {
                    LabeledContent("Account", value: self.store.prefs.hidesEmail ? ProviderModel.masked(email) : email)
                }
                if self.id.hasSpend {
                    LabeledContent("Spend from", value: self.spendSource)
                }
                LabeledContent("Limits from", value: self.limitsSource)
            } header: {
                Text("Sources")
            }

            if self.id == .devin {
                DevinCredentials()
            } else if self.id == .droid {
                DroidCredentials()
            }

            Section {
                HStack {
                    Link(destination: self.id.usageURL) {
                        Label("Open \(self.id.usageSite)", systemImage: "arrow.up.right.square")
                    }
                    Spacer()
                    Button("Refresh Now") {
                        model.refresh()
                        model.credentialsChanged()
                    }
                    .disabled(!enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private static func figure(_ cost: Double, _ tokens: Int, _ tokensOnly: Bool) -> String {
        tokensOnly ? "\(Format.tokens(tokens)) tokens" : "\(Format.money(cost)) · \(Format.tokens(tokens)) tokens"
    }

    private var spendSource: String {
        switch self.id {
        case .claude: "Claude Code and pi logs"
        case .codex: "Codex sessions"
        case .opencodeGo, .zen: "OpenCode's own history"
        case .devin, .droid: "—"
        }
    }

    private var limitsSource: String {
        switch self.id {
        case .claude: "Claude Code's sign-in"
        case .codex: "Codex's sign-in"
        case .opencodeGo: "The Go key OpenCode holds"
        case .zen: "None: pay as you go"
        case .devin: "The session token below"
        case .droid: "The Factory API key below"
        }
    }
}

/// `Weekly ▬▬▬▬▬▭▭ 63% left · resets in 2d 4h`.
private struct LimitSummary: View {
    @Environment(UsageStore.self) private var store
    let limit: PlanLimits.Limit
    let now: Date

    var body: some View {
        let reset = self.limit.resetsAt
        let hasReset = reset.map { $0 <= self.now } ?? false
        let left = hasReset ? 100 : self.limit.leftPercent
        let prefs = self.store.prefs
        let shown = prefs.limitFigure == .left ? left : 100 - left
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(self.limit.title)
                Spacer()
                if let reset, !hasReset {
                    Text(Format.reset(reset, now: self.now, style: prefs.resetStyle))
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11.5))
                }
                Text("\(Int(shown.rounded()))% \(prefs.limitFigure == .left ? "left" : "used")")
                    .fontWeight(.medium)
                    .foregroundStyle(left < 10 ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
                    .frame(minWidth: 72, alignment: .trailing)
            }
            .monospacedDigit()
            // The same bar as the menu's, pace mark included.
            let pace = hasReset || !prefs.showsPace ? nil : self.limit.pace(now: self.now)
            Meter(fraction: shown / 100, height: Meter.limitHeight,
                  fill: left < 10 ? AnyShapeStyle(Color.red) : AnyShapeStyle(Theme.accent),
                  mark: pace.map { (prefs.limitFigure == .left ? 100 - $0.expectedUsedPercent : $0.expectedUsedPercent) / 100 })
        }
    }
}

/// A pasted secret: shows whether one is saved, never the value itself.
private struct SecretField: View {
    @Environment(UsageStore.self) private var store
    let title: String
    let key: Secrets.Key
    let prompt: String
    @State private var draft = ""
    @State private var failed = false

    var body: some View {
        let saved = self.store.hasSecret(self.key)
        LabeledContent(self.title) {
            HStack(spacing: 6) {
                SecureField(self.title, text: self.$draft, prompt: Text(saved ? "Saved in Keychain" : self.prompt))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(self.save)
                if !self.draft.isEmpty {
                    Button("Save", action: self.save)
                        .keyboardShortcut(.defaultAction)
                } else if saved {
                    Button("Remove") { _ = self.store.setSecret(self.key, "") }
                }
            }
        }
        if self.failed {
            Text("That doesn't look like a token. Paste it without quotes or spaces.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.deficit)
        }
    }

    private func save() {
        self.failed = !self.store.setSecret(self.key, self.draft)
        if !self.failed { self.draft = "" }
    }
}

private struct DevinCredentials: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        @Bindable var store = self.store
        Section {
            SecretField(title: "Token", key: .devinToken, prompt: DevinLimits.cliToken() == nil ? "Bearer token" : "Using the Devin CLI sign-in")
            TextField("Organization", text: $store.devinOrganization, prompt: Text((Demo.isOn ? Demo.devinOrganization : DevinLimits.cliOrganization()) ?? "org_…"))
        } header: {
            Text("Devin sign-in")
        } footer: {
            Footnote("Read from the Devin CLI's own sign-in, so nothing to paste once devin auth login has run. A token pasted here is tried first; the organization defaults to the CLI's. Kept in your Keychain and only ever sent to app.devin.ai.")
        }
    }
}

private struct DroidCredentials: View {
    var body: some View {
        Section {
            SecretField(title: "API key", key: .droidAPIKey, prompt: DroidLimits.environmentKey() == nil ? "fk-…" : "Using FACTORY_API_KEY")
        } header: {
            Text("Factory API key")
        } footer: {
            Footnote("Optional. Without a key, the sign-in app.factory.ai keeps in Chrome, Arc, Brave, Edge or ego lite is used while it's fresh. For limits that never lapse, create a key at app.factory.ai under Settings → API keys, or set FACTORY_API_KEY or ~/.factory/.env. Kept in your Keychain and only ever sent to api.factory.ai.")
        }
    }
}

// MARK: - Advanced

private struct AdvancedPane: View {
    @Environment(UsageStore.self) private var store
    @State private var updatingPrices = false
    @State private var pricesNote: String?
    @State private var confirmsReset = false
    @State private var confirmsKeys = false

    var body: some View {
        Form {
            self.prices
            self.data
            self.reset
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove the saved keys?", isPresented: self.$confirmsKeys) {
            Button("Remove Keys", role: .destructive) { self.store.removeSecrets() }
        } message: {
            Text("Devin and Droid limits stop until you paste new ones.")
        }
        .confirmationDialog("Reset all settings?", isPresented: self.$confirmsReset) {
            Button("Reset", role: .destructive) {
                self.store.prefs.reset()
                self.store.setWeekStart(self.store.prefs.weekStart)
            }
        } message: {
            Text("Every switch in Settings goes back to its default.")
        }
    }

    private var prices: some View {
            Section {
                SettingRow("Model prices", detail: self.pricesNote ?? self.pricesStatus) {
                    HStack(spacing: 8) {
                        if self.updatingPrices { ProgressView().controlSize(.small) }
                        Button("Update Now") { self.updatePrices() }
                            .disabled(self.updatingPrices)
                    }
                }
            } header: {
                Text("Prices")
            } footer: {
                Footnote("Claude and Codex spend is priced from models.dev's public catalog, checked once a day, with a built-in table as the fallback.")
            }
    }

    private var data: some View {
            Section {
                SettingRow("Data folder", detail: AppPaths.support.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.support])
                    }
                }
            } header: {
                Text("Data")
            } footer: {
                Footnote("Only caches of the figures you see. Your logs are read where they are and never copied.")
            }
    }

    private var reset: some View {
            Section {
                SettingRow("Saved keys", detail: "The Devin token and Factory API key in your Keychain.") {
                    Button("Remove…") { self.confirmsKeys = true }
                }
                .disabled(!self.store.hasSecret(.devinToken) && !self.store.hasSecret(.droidAPIKey))
                SettingRow("All settings", detail: "Back to how a fresh install starts. Keys and providers stay.") {
                    Button("Reset…") { self.confirmsReset = true }
                }
            } header: {
                Text("Reset")
            }
    }

    private var pricesStatus: String {
        let modified = (try? PriceCatalog.cacheURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let modified else { return "Using the built-in table." }
        return "From models.dev, \(modified.formatted(.relative(presentation: .named)))."
    }

    private func updatePrices() {
        self.updatingPrices = true
        self.pricesNote = nil
        Task {
            let ok = await self.store.updatePrices()
            self.updatingPrices = false
            self.pricesNote = ok ? "Updated just now." : "Couldn't reach models.dev. The last prices stay in use."
        }
    }
}

// MARK: - About

private struct AboutPane: View {
    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            AppIconView(size: 112)
            Text("count yo tokens")
                .font(.system(size: 22, weight: .semibold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("What your AI tools cost, and how much of each plan is left.")
                .font(.system(size: 13))
                .padding(.top, 6)
            Text("Claude · Codex · OpenCode Go · OpenCode Zen · Devin · Droid")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            VStack(spacing: 4) {
                Text("A hard fork of CodexBar by Peter Steinberger.")
                Link("github.com/steipete/CodexBar", destination: URL(string: "https://github.com/steipete/CodexBar")!)
                Text("MIT License")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .multilineTextAlignment(.center)
    }
}

// MARK: - Bits

/// A form row: a title and an optional line of detail on the left, its control centred on the
/// right. The stock row pins controls to the title's line, which looks off on two-line rows.
struct SettingRow<Control: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let detail: String?
    let control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(self.title)
                    .foregroundStyle(self.isEnabled ? .primary : .tertiary)
                if let detail = self.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(self.isEnabled ? .secondary : .tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            self.control
        }
    }
}

extension SettingRow {
    /// A switch row.
    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) where Control == AnyView {
        self.init(title, detail: detail) {
            AnyView(Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini))
        }
    }
}

private struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(self.text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
    }
}

extension ProviderID {
    var usageURL: URL {
        switch self {
        case .claude: URL(string: "https://claude.ai/settings/usage")!
        case .codex: URL(string: "https://chatgpt.com/codex/settings/usage")!
        case .opencodeGo, .zen: URL(string: "https://opencode.ai/auth")!
        case .devin: URL(string: "https://app.devin.ai/settings/usage")!
        case .droid: URL(string: "https://app.factory.ai/settings/billing")!
        }
    }

    var usageSite: String {
        switch self {
        case .claude: "claude.ai"
        case .codex: "chatgpt.com"
        case .opencodeGo, .zen: "opencode.ai"
        case .devin: "app.devin.ai"
        case .droid: "app.factory.ai"
        }
    }
}
