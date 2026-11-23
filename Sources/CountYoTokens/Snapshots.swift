import AppKit
import CoreImage
import SwiftUI
import TokenCore

/// `-snapshot <folder>`: draws the menu for every enabled provider and each Settings pane, in light
/// and dark, into PNGs, then quits. Checks the real views without touching the screen.
@MainActor
enum Snapshots {
    /// `-snapshotHeight <points>` draws the Settings panes taller, to see what a pane holds below the fold.
    private static var settingsHeight: CGFloat {
        let height = UserDefaults.standard.double(forKey: "snapshotHeight")
        return height > 0 ? height : 580
    }

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
                                size: NSSize(width: 800, height: self.settingsHeight), to: "\(folder)/settings-\(name)-\(suffix).png")
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
            ActionRow(action: .refresh) {}
            ActionRow(action: .settings) {}
            Separator()
            ActionRow(action: .quit) {}
        }
        .padding(.bottom, 5)
        .frame(width: Theme.menuWidth + 12)
        .background { self.glass }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(self.scheme == .dark ? 0.2 : 0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(self.scheme == .dark ? 0.5 : 0.22), radius: 22, y: 12)
    }

    /// The menu material, as macOS draws it: the wallpaper behind, blurred and saturated, under a
    /// light or dark wash. The card always sits where the hero puts it, 14 points in from the
    /// screen's right edge under the menu bar, so the blur lines up with the wallpaper around it.
    private var glass: some View {
        let dark = self.scheme == .dark
        // The card's size comes from its content; the wallpaper hangs off its top right corner.
        return Color.clear
            .overlay(alignment: .topTrailing) {
                if let image = Wallpaper.frosted(dark: dark) {
                    let side = Wallpaper.side
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: side, height: side)
                        .offset(x: HeroShot.cardInset, y: -(side - Wallpaper.screen.height) / 2 - HeroShot.cardTop)
                }
            }
            .overlay(dark ? Color(white: 0.11).opacity(0.6) : Color.white.opacity(0.55))
            .clipped()
    }
}

/// macOS Sonoma's default wallpaper, which holds a light and a dark picture, read from the system at
/// render time and never bundled. Drawn as a 1512 × 945 screen shows it.
@MainActor
enum Wallpaper {
    nonisolated static let screen = CGSize(width: 1512, height: 945)
    nonisolated static let side: CGFloat = 1512

    static func sharp(dark: Bool) -> NSImage? { dark ? self.cache.darkSharp : self.cache.lightSharp }
    static func frosted(dark: Bool) -> NSImage? { dark ? self.cache.darkFrosted : self.cache.lightFrosted }

    private struct Cache {
        var lightSharp, darkSharp, lightFrosted, darkFrosted: NSImage?
    }

    private static let cache: Cache = {
        let url = URL(fileURLWithPath: "/System/Library/Desktop Pictures/Sonoma.heic")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 1
        else { return Cache() }
        func load(_ index: Int) -> CGImage? {
            CGImageSourceCreateThumbnailAtIndex(source, index, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 3200,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary)
        }
        // About 30 points of blur at the size it's drawn, with colour pushed up the way vibrancy does.
        func frost(_ image: CGImage) -> NSImage? {
            let input = CIImage(cgImage: image)
            let radius = 30 * CGFloat(image.width) / Wallpaper.side
            let blurred = input.clampedToExtent()
                .applyingGaussianBlur(sigma: radius)
                .cropped(to: input.extent)
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35])
            guard let output = CIContext().createCGImage(blurred, from: input.extent) else { return nil }
            return NSImage(cgImage: output, size: NSSize(width: output.width, height: output.height))
        }
        let light = load(0), dark = load(1)
        return Cache(lightSharp: light.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) },
                     darkSharp: dark.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) },
                     lightFrosted: light.flatMap(frost), darkFrosted: dark.flatMap(frost))
    }()
}

/// A slice of desktop, cut from the right of a 1512-point-wide screen: the Sonoma wallpaper in the
/// matching appearance, the menu bar with the tally lit, the menu hanging under it, and the app's
/// name beside it.
private struct HeroShot: View {
    @Environment(UsageStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    static let size = CGSize(width: 760, height: 840)
    /// Where the menu hangs: in from the screen's right edge, and down from its top.
    static let cardInset: CGFloat = 14
    static let cardTop: CGFloat = 35

    var body: some View {
        let spend = self.store.current.snapshot?.today?.cost ?? 0
        ZStack(alignment: .topLeading) {
            self.wallpaper
            VStack(spacing: 0) {
                self.menuBar(spend: spend)
                HStack(alignment: .top, spacing: 0) {
                    // Centred in the desktop left of the menu, both ways.
                    self.title
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    MenuCard()
                        .padding(.top, Self.cardTop - 30)
                        .padding(.trailing, Self.cardInset)
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(2)
    }

    private var title: some View {
        VStack(spacing: 10) {
            AppIconView(size: 150)
            Text("count yo tokens")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .padding(.top, -6)
            Text("What your AI tools cost,\nand how much of each plan is left.")
                .font(.system(size: 14.5, weight: .medium))
                .multilineTextAlignment(.center)
                .opacity(0.88)
                .fixedSize()
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 10, y: 2)
    }

    private func menuBar(spend: Double) -> some View {
        HStack(spacing: 17) {
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
            Image(systemName: "magnifyingglass")
            Image(systemName: "switch.2")
            Text("Sat 21 Nov  10:41")
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 16)
        .frame(height: 30)
        .background(self.scheme == .dark ? Color.black.opacity(0.3) : Color.white.opacity(0.4))
    }

    /// The wallpaper as the whole screen would show it, pinned to its top right.
    private var wallpaper: some View {
        Group {
            if let image = Wallpaper.sharp(dark: self.scheme == .dark) {
                let side = Wallpaper.side
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: side, height: side)
                    .offset(x: Self.size.width - side, y: -(side - Wallpaper.screen.height) / 2)
            } else {
                LinearGradient(colors: self.scheme == .dark
                    ? [Color(red: 0.12, green: 0.09, blue: 0.17), Color(red: 0.05, green: 0.08, blue: 0.14)]
                    : [Color(red: 0.93, green: 0.79, blue: 0.86), Color(red: 0.79, green: 0.84, blue: 0.95)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .clipped()
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
