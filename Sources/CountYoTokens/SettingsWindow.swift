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

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .menuBar: "menubar.rectangle"
        case .menu: "list.bullet.rectangle.fill"
        case .notifications: "bell.badge.fill"
        case let .provider(id): id.symbol
        case .advanced: "wrench.and.screwdriver.fill"
        case .about: "info"
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
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbar = NSToolbar(identifier: "Settings")
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 720, height: 500)
        window.setContentSize(NSSize(width: 800, height: 580))
        window.center()
        window.setFrameAutosaveName("Settings")
        return window
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
                .navigationTitle(self.store.settingsPane.title)
        }
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: 720, minHeight: 500)
    }
}

private struct SettingsSidebar: View {
    @Environment(UsageStore.self) private var store
    @Binding var selection: SettingsPane

    var body: some View {
        List(selection: self.$selection) {
            Section {
                ForEach(SettingsPane.top, id: \.self) { pane in
                    SidebarRow(pane: pane).tag(pane)
                }
            }
            Section {
                ForEach(self.store.prefs.order) { id in
                    ProviderSidebarRow(id: id).tag(SettingsPane.provider(id))
                }
                .onMove { self.store.prefs.move(from: $0, to: $1) }
            } header: {
                Text("Providers")
            }
            Section {
                ForEach(SettingsPane.bottom, id: \.self) { pane in
                    SidebarRow(pane: pane).tag(pane)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct SidebarRow: View {
    let pane: SettingsPane

    var body: some View {
        Label {
            Text(self.pane.title)
        } icon: {
            PaneIcon(pane: self.pane, size: 20)
        }
    }
}

private struct ProviderSidebarRow: View {
    @Environment(UsageStore.self) private var store
    let id: ProviderID

    var body: some View {
        let enabled = self.store.isEnabled(self.id)
        Label {
            HStack {
                Text(self.id.displayName)
                    .foregroundStyle(enabled ? .primary : .secondary)
                Spacer(minLength: 4)
                StatusDot(status: ProviderStatus(model: self.store.providers[self.id]!, enabled: enabled))
            }
        } icon: {
            PaneIcon(pane: .provider(self.id), size: 20)
                .saturation(enabled ? 1 : 0)
                .opacity(enabled ? 1 : 0.6)
        }
    }
}

/// White symbol on a coloured rounded square, the way System Settings marks its panes.
struct PaneIcon: View {
    let pane: SettingsPane
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: self.size * 0.26, style: .continuous)
            .fill(self.pane.tint.gradient)
            .frame(width: self.size, height: self.size)
            .overlay {
                Image(systemName: self.pane.symbol)
                    .font(.system(size: self.size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
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
                Toggle(isOn: $store.opensAtLogin) {
                    Text("Open at login")
                    Text("Starts quietly in the menu bar when you log in.")
                }
            }
            Section {
                Picker(selection: $prefs.limitsInterval) {
                    ForEach(RefreshInterval.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Check plan limits")
                    Text("Providers turn away requests that come too often, so a few minutes apart is plenty.")
                }
                Toggle(isOn: $prefs.refreshesOnOpen) {
                    Text("Check when the menu opens")
                    Text("At most once a minute, for the provider you're looking at.")
                }
                LabeledContent {
                    Button("Refresh All") { self.store.refreshAll() }
                } label: {
                    Text("Spend")
                    Text("Read from local logs within a second of them changing.")
                }
            } header: {
                Text("Updates")
            }
            Section {
                Picker(selection: Binding(get: { prefs.weekStart }, set: { self.store.setWeekStart($0) })) {
                    Text("Each plan's weekly reset").tag(0)
                    Divider()
                    ForEach(Self.weekdays, id: \.self) { day in
                        Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                    }
                } label: {
                    Text("Weeks start")
                    Text("Weekly windows in the menu line up with this. Providers without a weekly limit start on Monday.")
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
                            Image(nsImage: style == .tally ? StatusIcon.image : StatusIcon.meter([72, 40]))
                        }
                        .tag(style)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelStyle(.titleAndIcon)
            } header: {
                Text("Icon")
            } footer: {
                Footnote("The meter fills like a battery with the first two limits left: the session on top, the week below. Providers without limits keep the tally.")
            }
            Section {
                Picker("Show next to the icon", selection: $prefs.menuBarDisplay) {
                    ForEach(MenuBarDisplay.allCases) { Text($0.title).tag($0) }
                }
                Picker("For", selection: $prefs.menuBarProvider) {
                    Text("The provider shown in the menu").tag(ProviderID?.none)
                    Divider()
                    ForEach(self.store.enabled) { Text($0.displayName).tag(ProviderID?.some($0)) }
                }
                Toggle(isOn: $prefs.warnsInMenuBar) {
                    Text("Turn red when a limit is nearly used up")
                    Text("Under 10% left, with “Lowest limit left” shown.")
                }
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
        let now = Date()
        let lefts = (model.limits?.items.prefix(2) ?? []).map { $0.resetsAt.map { $0 <= now } == true ? 100 : $0.leftPercent }
        let meter = prefs.iconStyle == .meter && !lefts.isEmpty
        HStack(spacing: 14) {
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            HStack(spacing: 3) {
                Image(nsImage: meter ? StatusIcon.meter(lefts) : StatusIcon.image)
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
                Toggle(isOn: $prefs.showsLimits) {
                    Text("Plan limits")
                    Text("Session, weekly and other windows, with how long until each resets.")
                }
                Toggle(isOn: $prefs.showsPace) {
                    Text("Pace")
                    Text("Whether you're ahead of or behind an even pace, and when you'd run out.")
                }
                .disabled(!prefs.showsLimits)
                .padding(.leading, 18)
                Toggle(isOn: $prefs.showsToday) {
                    Text("Today and this window")
                    Text("The two big figures.")
                }
                Toggle(isOn: $prefs.showsHistory) {
                    Text("Last 30 days")
                    Text("A bar for each day. Hover one for its figure.")
                }
                Toggle(isOn: $prefs.showsWindows) {
                    Text("Weekly windows")
                    Text("Spend in this week's window and the three before it.")
                }
                Toggle(isOn: $prefs.showsTopModel) {
                    Text("Top model")
                    Text("The model behind most of the spend.")
                }
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
                Toggle(isOn: $prefs.hidesEmail) {
                    Text("Hide email address")
                    Text("Shows \(ProviderModel.masked("you@example.com")) instead, for screen sharing.")
                }
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
                Toggle(isOn: self.asking($prefs.notifiesLow)) {
                    Text("When a limit runs low")
                    Text("Once per window, for every provider in the menu.")
                }
                Picker("Below", selection: $prefs.lowThreshold) {
                    ForEach([50, 25, 20, 10, 5], id: \.self) { Text("\($0)% left").tag($0) }
                }
                .disabled(!prefs.notifiesLow)
                .padding(.leading, 18)
                Toggle(isOn: self.asking($prefs.notifiesReset)) {
                    Text("When a low limit resets")
                    Text("So you know you can get back to it.")
                }
            } header: {
                Text("Limits")
            }
            Section {
                Toggle(isOn: self.asking($prefs.notifiesSpend)) {
                    Text("When a day's spend passes an amount")
                    Text("Once a day per provider, at API prices.")
                }
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
                LabeledContent {
                    Button("Send Test") {
                        Task {
                            self.permission = await Notifier.shared.requestPermission()
                            Notifier.shared.sendTest()
                        }
                    }
                } label: {
                    Text("Test notification")
                    Text(self.permission == .allowed ? "Notifications are allowed." : "macOS asks for permission the first time.")
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
                ? (model.id == .devin ? "Needs a session token" : "Needs an API key")
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
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(left < 10 ? AnyShapeStyle(Color.red) : AnyShapeStyle(Theme.accent))
                        .frame(width: max(4, proxy.size.width * shown / 100))
                }
            }
            .frame(height: 4)
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
            SecretField(title: "Token", key: .devinToken, prompt: "Bearer token")
            TextField("Organization", text: $store.devinOrganization, prompt: Text(DevinLimits.cliOrganization() ?? "org_…"))
        } header: {
            Text("Devin sign-in")
        } footer: {
            Footnote("In app.devin.ai, open Usage & Limits with the browser's developer tools on the Network tab. Copy the Authorization header from the billing/quota/usage request. The organization defaults to the one the Devin CLI uses. The token is kept in your Keychain and only ever sent to app.devin.ai.")
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
            Footnote("Create one at app.factory.ai under Settings → API keys. A key in FACTORY_API_KEY or ~/.factory/.env is used when none is saved here. Kept in your Keychain and only ever sent to api.factory.ai.")
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
                LabeledContent {
                    HStack(spacing: 8) {
                        if self.updatingPrices { ProgressView().controlSize(.small) }
                        Button("Update Now") { self.updatePrices() }
                            .disabled(self.updatingPrices)
                    }
                } label: {
                    Text("Model prices")
                    Text(self.pricesNote ?? self.pricesStatus)
                }
            } header: {
                Text("Prices")
            } footer: {
                Footnote("Claude and Codex spend is priced from models.dev's public catalog, checked once a day, with a built-in table as the fallback.")
            }
    }

    private var data: some View {
            Section {
                LabeledContent {
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.support])
                    }
                } label: {
                    Text("Data folder")
                    Text(AppPaths.support.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .textSelection(.enabled)
                }
            } header: {
                Text("Data")
            } footer: {
                Footnote("Only caches of the figures you see. Your logs are read where they are and never copied.")
            }
    }

    private var reset: some View {
            Section {
                LabeledContent {
                    Button("Remove…") { self.confirmsKeys = true }
                        .disabled(!self.store.hasSecret(.devinToken) && !self.store.hasSecret(.droidAPIKey))
                } label: {
                    Text("Saved keys")
                    Text("The Devin token and Factory API key in your Keychain.")
                }
                LabeledContent {
                    Button("Reset…") { self.confirmsReset = true }
                } label: {
                    Text("All settings")
                    Text("Back to how a fresh install starts. Keys and providers stay.")
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

private struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(self.text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension ProviderID {
    var symbol: String {
        switch self {
        case .claude: "asterisk"
        case .codex: "terminal.fill"
        case .opencodeGo: "bolt.fill"
        case .zen: "leaf.fill"
        case .devin: "wand.and.stars"
        case .droid: "gearshape.2.fill"
        }
    }

    var tint: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: Color(white: 0.3)
        case .opencodeGo: .blue
        case .zen: .green
        case .devin: .teal
        case .droid: .orange
        }
    }

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
