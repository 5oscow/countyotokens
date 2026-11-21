import AppKit
import SwiftUI
import TokenCore

/// `-snapshot <folder>`: draws the menu for every enabled provider and each Settings pane, in light
/// and dark, into PNGs, then quits. Checks the real views without touching the screen.
@MainActor
enum Snapshots {
    static var folder: String? { UserDefaults.standard.string(forKey: "snapshot") ?? self.readmeFolder }
    /// `-readme <folder>` (with `-demo`): the README's pictures, framed, light and dark.
    private static var readmeFolder: String? { UserDefaults.standard.string(forKey: "readme") }

    static func run(store: UsageStore) {
        if let folder = self.readmeFolder {
            self.runReadme(store: store, folder: folder)
            return
        }
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
                let panes = SettingsPane.top + [.provider(.claude), .provider(.opencodeGo), .provider(.devin)] + SettingsPane.bottom
                for pane in panes {
                    store.settingsPane = pane
                    try? await Task.sleep(for: .milliseconds(150))
                    let name = pane.title.lowercased().replacingOccurrences(of: " ", with: "-")
                    self.render(SettingsView(), store: store, appearance: appearance,
                                size: NSSize(width: 800, height: 580), to: "\(folder)/settings-\(name)-\(suffix).png")
                }
            }
            store.selected = original
            NSApp.terminate(nil)
        }
    }

    private static func runReadme(store: UsageStore, folder: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            let original = store.selected
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let suffix = appearance == .aqua ? "light" : "dark"
                store.selected = .claude
                try? await Task.sleep(for: .milliseconds(200))
                self.render(HeroShot(), store: store, appearance: appearance, background: false,
                            to: "\(folder)/hero-\(suffix).png")
                for id in [ProviderID.codex, .opencodeGo, .devin] {
                    store.selected = id
                    try? await Task.sleep(for: .milliseconds(200))
                    self.render(MenuCard().padding(36), store: store, appearance: appearance, background: false,
                                to: "\(folder)/card-\(id.rawValue)-\(suffix).png")
                }
                store.selected = .claude
                for pane in [SettingsPane.general, .menuBar, .provider(.claude), .notifications] {
                    store.settingsPane = pane
                    try? await Task.sleep(for: .milliseconds(200))
                    let name = pane.title.lowercased().replacingOccurrences(of: " ", with: "-")
                    self.render(WindowFrame { SettingsView().frame(width: 800, height: 560) }, store: store,
                                appearance: appearance, background: false, to: "\(folder)/settings-\(name)-\(suffix).png")
                }
            }
            store.selected = original
            NSApp.terminate(nil)
        }
    }

    private static func render(_ view: some View, store: UsageStore, appearance: NSAppearance.Name,
                               size: NSSize? = nil, background: Bool = true, to path: String) {
        let host = NSHostingView(rootView: view
            .environment(store)
            .background(background ? Color(nsColor: .windowBackgroundColor) : .clear))
        host.appearance = NSAppearance(named: appearance)
        host.frame.size = size ?? host.fittingSize
        // Lists only draw inside a window; this one is never shown.
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        // Retina, so the PNGs show what a real screen does.
        guard host.bounds.width > 0, host.bounds.height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width * 2),
                                            pixelsHigh: Int(host.bounds.height * 2), bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        bitmap.size = host.bounds.size
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
            let prefs = self.store.prefs
            if id.hasLimits, prefs.showsLimits { Separator(); LimitsSection() }
            if id.hasSpend {
                if prefs.showsToday { Separator(); HeroSection() }
                if prefs.showsHistory { Separator(); HistorySection() }
                if prefs.showsWindows { Separator(); WindowsSection() }
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

// MARK: - README pictures

/// The menu as it opens: the sections, then the system rows, on the menu's own rounded panel.
private struct MenuCard: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuPreview()
            Separator()
            MenuRow(title: "Refresh", symbol: "arrow.clockwise", key: "⌘R")
            MenuRow(title: "Settings…", symbol: "gearshape", key: "⌘,")
            Separator()
            MenuRow(title: "Quit count yo tokens", symbol: "power", key: "⌘Q")
        }
        .padding(.bottom, 5)
        .frame(width: Theme.menuWidth + 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(self.scheme == .dark ? Color(white: 0.16) : Color(white: 0.97)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(self.scheme == .dark ? 0.2 : 0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(self.scheme == .dark ? 0.5 : 0.22), radius: 22, y: 12)
    }
}

private struct MenuRow: View {
    let title: String
    let symbol: String
    let key: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: self.symbol)
                .font(.system(size: 12.5))
                .frame(width: 16)
            Text(self.title)
            Spacer()
            Text(self.key).foregroundStyle(.secondary)
        }
        .font(.system(size: 13))
        .padding(.horizontal, Theme.inset)
        .frame(height: 22)
    }
}

/// A slice of desktop: wallpaper, the menu bar with the tally lit, and the menu hanging under it.
private struct HeroShot: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let spend = self.store.current.snapshot?.today?.cost ?? 0
        ZStack(alignment: .topLeading) {
            self.desktop(spend: spend)
            VStack(alignment: .leading, spacing: 8) {
                AppIconView(size: 132)
                    .padding(.leading, -12)
                Text("count yo tokens")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("What your AI tools cost,\nand how much of each plan is left.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .padding(.leading, 44)
            .padding(.top, 92)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(2)
    }

    private func desktop(spend: Double) -> some View {
        VStack(alignment: .trailing, spacing: 5) {
            HStack(spacing: 18) {
                Spacer()
                HStack(spacing: 4) {
                    Image(nsImage: StatusIcon.image).renderingMode(.template)
                    Text(Format.wholeMoney(spend)).monospacedDigit()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Text("Sat 21 Nov  10:41")
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 18)
            .frame(height: 30)
            .background(self.scheme == .dark ? Color.black.opacity(0.35) : Color.white.opacity(0.45))
            MenuCard()
                .padding(.trailing, 168)
                .padding(.bottom, 56)
        }
        .frame(width: 820)
        .background(
            LinearGradient(colors: self.scheme == .dark
                ? [Color(red: 0.2, green: 0.11, blue: 0.08), Color(red: 0.12, green: 0.09, blue: 0.17), Color(red: 0.05, green: 0.08, blue: 0.14)]
                : [Color(red: 0.98, green: 0.84, blue: 0.76), Color(red: 0.93, green: 0.79, blue: 0.86), Color(red: 0.79, green: 0.84, blue: 0.95)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

/// A window's rounded corners, hairline and shadow around a view.
private struct WindowFrame<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder let content: Content

    var body: some View {
        self.content
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(self.scheme == .dark ? 0.22 : 0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(self.scheme == .dark ? 0.5 : 0.2), radius: 24, y: 12)
            .padding(40)
    }
}
