import AppKit
import SwiftUI
import TokenCore

// MARK: - Window

/// A standard Mac settings window: toolbar tabs, the window resizing smoothly to each pane.
enum SettingsWindow {
    @MainActor
    static func make(store: UsageStore) -> NSWindow {
        let tabs = SettingsTabs()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.crossfade, .allowUserInteraction]
        tabs.addTabViewItem(self.tab("General", symbol: "gearshape", GeneralPane(), store: store))
        tabs.addTabViewItem(self.tab("Providers", symbol: "square.stack.3d.up", ProvidersPane(), store: store))
        tabs.addTabViewItem(self.tab("About", symbol: "info.circle", AboutPane(), store: store))
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        tabs.fitWindow(animated: false)
        window.center()
        return window
    }

    @MainActor
    private static func tab(_ title: String, symbol: String, _ view: some View, store: UsageStore) -> NSTabViewItem {
        let controller = NSHostingController(rootView: view.environment(store))
        controller.sizingOptions = [.preferredContentSize]
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }
}

/// Resizes the window to the selected pane, keeping its top edge in place.
final class SettingsTabs: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        self.fitWindow(animated: true)
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        if viewController == self.tabViewItems[self.selectedTabViewItemIndex].viewController {
            self.fitWindow(animated: true)
        }
    }

    func fitWindow(animated: Bool) {
        guard let window = self.view.window,
              let child = self.tabViewItems[self.selectedTabViewItemIndex].viewController
        else { return }
        let size = child.preferredContentSize
        guard size.width > 0, size.height > 0 else { return }
        window.title = self.tabViewItems[self.selectedTabViewItemIndex].label
        let content = window.contentRect(forFrameRect: window.frame)
        var frame = window.frameRect(forContentRect: NSRect(origin: content.origin, size: size))
        frame.origin.y = window.frame.maxY - frame.height
        window.setFrame(frame, display: true, animate: animated && window.isVisible)
    }
}

// MARK: - General

struct GeneralPane: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        @Bindable var store = self.store
        Form {
            Section {
                Picker("Show next to the icon", selection: $store.menuBarDisplay) {
                    ForEach(MenuBarDisplay.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Menu bar")
            } footer: {
                Footnote("Follows the provider selected in the menu.")
            }
            Section {
                Toggle("Open at login", isOn: $store.opensAtLogin)
            } footer: {
                Footnote("Spend refreshes within a second of a log changing. Limits refresh every 3 minutes, and when you open the menu.")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Providers

struct ProvidersPane: View {
    @Environment(UsageStore.self) private var store
    @State private var selection: ProviderID

    init(selection: ProviderID = .claude) {
        self._selection = State(initialValue: selection)
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: self.$selection) {
                ForEach(ProviderID.allCases) { id in
                    ProviderRow(id: id).tag(id)
                }
            }
            .listStyle(.sidebar)
            .scrollDisabled(true)
            .frame(width: 190)
            Divider()
            ProviderDetail(id: self.selection)
                .id(self.selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 640, height: 440)
    }
}

private struct ProviderRow: View {
    @Environment(UsageStore.self) private var store
    let id: ProviderID

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { self.store.isEnabled(self.id) }, set: { self.store.setEnabled(self.id, $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(self.store.enabled == [self.id])
            Text(self.id.displayName)
            Spacer(minLength: 4)
            StatusDot(status: ProviderStatus(model: self.store.providers[self.id]!, enabled: self.store.isEnabled(self.id)))
        }
        .padding(.vertical, 2)
    }
}

/// One line of state per provider, shared by the list dot and the detail header.
struct ProviderStatus {
    enum Level { case ok, attention, off }
    var level: Level
    var text: String

    @MainActor
    init(model: ProviderModel, enabled: Bool) {
        guard enabled else {
            self = .init(level: .off, text: "Off")
            return
        }
        if let issue = model.limitsIssue {
            let text = issue == .needsKey
                ? (model.id == .devin ? "Paste a session token below." : "Paste an API key below.")
                : model.message(for: issue)
            self = .init(level: .attention, text: text)
        } else if let limits = model.limits, limits.fetchedAt > .distantPast {
            self = .init(level: .ok, text: "Limits updated \(Format.updated(limits.fetchedAt, now: Date()).replacingOccurrences(of: "Updated ", with: ""))")
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

private struct ProviderDetail: View {
    @Environment(UsageStore.self) private var store
    let id: ProviderID

    var body: some View {
        let model = self.store.providers[self.id]!
        let enabled = self.store.isEnabled(self.id)
        let status = ProviderStatus(model: model, enabled: enabled)
        Form {
            Section {
                Toggle(isOn: Binding(get: { enabled }, set: { self.store.setEnabled(self.id, $0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show \(self.id.displayName)")
                        Text(status.text)
                            .font(.system(size: 11))
                            .foregroundStyle(status.level == .attention ? AnyShapeStyle(Theme.deficit) : AnyShapeStyle(.secondary))
                    }
                }
                .disabled(self.store.enabled == [self.id])
            }
            Section("Sources") {
                if self.id.hasSpend {
                    LabeledContent("Spend", value: self.spendSource)
                }
                LabeledContent("Limits", value: self.limitsSource)
                if let plan = model.plan {
                    LabeledContent("Plan", value: plan)
                }
            }
            if self.id == .devin {
                DevinCredentials()
            } else if self.id == .droid {
                DroidCredentials()
            }
            if enabled {
                Section {
                    HStack {
                        Spacer()
                        Button("Refresh now") {
                            model.refresh()
                            model.credentialsChanged()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var spendSource: String {
        switch self.id {
        case .claude: "Claude Code and pi logs, priced at API rates"
        case .codex: "Codex sessions, priced at API rates"
        case .opencodeGo, .zen: "OpenCode's own history, as recorded"
        case .devin, .droid: "—"
        }
    }

    private var limitsSource: String {
        switch self.id {
        case .claude: "Claude Code's sign-in"
        case .codex: "Codex's sign-in"
        case .opencodeGo: "The Go key OpenCode holds"
        case .zen: "None: pay as you go"
        case .devin: "Session token below"
        case .droid: "Factory API key below"
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
            Footnote("In app.devin.ai, open Usage & Limits with the browser's developer tools on the Network tab. Copy the Authorization header from the billing/quota/usage request. The organization defaults to the one the Devin CLI uses.")
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
            Footnote("Create one at app.factory.ai under Settings → API keys. A key in FACTORY_API_KEY or ~/.factory/.env is used when none is saved here.")
        }
    }
}

// MARK: - About

struct AboutPane: View {
    var body: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.accent.gradient)
                .frame(width: 72, height: 72)
                .overlay {
                    Image(nsImage: StatusIcon.image)
                        .renderingMode(.template)
                        .resizable()
                        .frame(width: 44, height: 44)
                        .foregroundStyle(.white)
                }
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            Text("count yo tokens")
                .font(.system(size: 17, weight: .semibold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("What your AI tools cost, and how much of each plan is left.\nA hard fork of CodexBar by Peter Steinberger. MIT License.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 460)
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
