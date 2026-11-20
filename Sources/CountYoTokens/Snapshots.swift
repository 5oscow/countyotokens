import AppKit
import SwiftUI
import TokenCore

/// `-snapshot <folder>`: draws the menu for every enabled provider and each Settings pane, in light
/// and dark, into PNGs, then quits. Checks the real views without touching the screen.
@MainActor
enum Snapshots {
    static var folder: String? { UserDefaults.standard.string(forKey: "snapshot") }

    static func run(store: UsageStore) {
        guard let folder = self.folder else { return }
        Task { @MainActor in
            // Let cold scans and limit fetches land first.
            try? await Task.sleep(for: .seconds(5))
            let original = store.selected
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let suffix = appearance == .aqua ? "light" : "dark"
                for id in store.enabled {
                    store.selected = id
                    try? await Task.sleep(for: .milliseconds(200))
                    self.render(MenuPreview(), store: store, appearance: appearance, to: "\(folder)/menu-\(id.rawValue)-\(suffix).png")
                }
                self.render(GeneralPane(), store: store, appearance: appearance, to: "\(folder)/settings-general-\(suffix).png")
                for id in [ProviderID.claude, .opencodeGo, .devin] {
                    self.render(ProvidersPane(selection: id), store: store, appearance: appearance,
                                to: "\(folder)/settings-providers-\(id.rawValue)-\(suffix).png")
                }
                self.render(AboutPane(), store: store, appearance: appearance, to: "\(folder)/settings-about-\(suffix).png")
            }
            store.selected = original
            NSApp.terminate(nil)
        }
    }

    private static func render(_ view: some View, store: UsageStore, appearance: NSAppearance.Name, to path: String) {
        let host = NSHostingView(rootView: view
            .environment(store)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: appearance)
        host.frame.size = host.fittingSize
        // Lists only draw inside a window; this one is never shown.
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard host.bounds.width > 0, host.bounds.height > 0,
              let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

/// The menu's custom sections stacked as the menu shows them for the selected provider.
private struct MenuPreview: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        let id = self.store.selected
        VStack(alignment: .leading, spacing: 0) {
            if self.store.enabled.count > 1 { SwitcherSection(); Separator() }
            HeaderSection()
            if id.hasLimits { Separator(); LimitsSection() }
            if id.hasSpend {
                Separator(); HeroSection()
                Separator(); HistorySection()
                Separator(); WindowsSection()
            }
            Separator()
            FooterSection()
        }
        .padding(.vertical, 5)
        .frame(width: Theme.menuWidth)
    }
}

private struct Separator: View {
    var body: some View {
        Divider().padding(.horizontal, 10).padding(.vertical, 5)
    }
}
