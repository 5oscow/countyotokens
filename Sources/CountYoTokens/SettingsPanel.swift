import SwiftUI

/// Settings window: two switches, System Settings style. Weekly windows follow the reset time
/// Anthropic reports for the plan, so there is nothing to set up.
struct SettingsPanel: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        @Bindable var store = self.store
        Form {
            Section {
                Toggle("Show today's spend in the menu bar", isOn: $store.showsSpendInMenuBar)
                Toggle("Open at login", isOn: Binding(
                    get: { _ = store.loginItemToken; return store.opensAtLogin },
                    set: { store.opensAtLogin = $0 }))
            } footer: {
                Text("Plan limits and weekly windows come from your Claude Code sign-in. Costs are estimated from local logs at API prices.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
