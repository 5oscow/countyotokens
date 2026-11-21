import AppKit
import Observation
import SwiftUI

@main
enum Main {
    @MainActor static let delegate = AppDelegate()

    @MainActor static func main() {
        let app = NSApplication.shared
        app.delegate = self.delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// A real status item with a real NSMenu: the system draws the material, the rounded corners and the
/// open/close fade, exactly like Apple's own menu extras. Each card section is a custom-view item
/// (custom views are never drawn highlighted), separated by native separators.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let store = UsageStore()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Snapshots.folder != nil {
            Snapshots.run(store: self.store)
            return
        }
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem.autosaveName = "countyotokens"
        self.statusItem.isVisible = true
        self.statusItem.button?.image = StatusIcon.image
        self.statusItem.button?.imagePosition = .imageLeading
        self.statusItem.button?.toolTip = "count yo tokens"
        self.statusItem.menu = self.makeMenu()
        NSApp.mainMenu = self.makeMainMenu()
        NSApp.applicationIconImage = AppIcon.image
        Notifier.shared.start()
        self.observeLayout()
        self.observeStatusTitle()
        // `-openSettings <pane>` opens Settings at launch (for checking the window without the menu).
        if let pane = UserDefaults.standard.string(forKey: "openSettings") {
            self.store.settingsPane = SettingsPane.named(pane) ?? .general
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showSettings() }
        }
    }

    /// Only seen while Settings is open: the app menu, and Edit so ⌘V pastes keys into the fields.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: "About count yo tokens", action: #selector(self.openAbout), keyEquivalent: "").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(self.openSettings), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Hide count yo tokens", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit count yo tokens", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        for (title, submenu) in [("count yo tokens", app), ("Edit", edit), ("Window", window)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            main.addItem(item)
        }
        NSApp.windowsMenu = window
        return main
    }

    // MARK: Menu

    /// Items that only some providers have, shown or hidden as the selection changes.
    private var switcherItems: [NSMenuItem] = []
    private var limitItems: [NSMenuItem] = []
    private var todayItems: [NSMenuItem] = []
    private var historyItems: [NSMenuItem] = []
    private var windowItems: [NSMenuItem] = []

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        // `-appearance light|dark` on the command line forces one look (for screenshots).
        if let forced = UserDefaults.standard.string(forKey: "appearance") {
            menu.appearance = NSAppearance(named: forced == "light" ? .aqua : .darkAqua)
        }
        menu.autoenablesItems = false
        func add(_ item: NSMenuItem, to group: inout [NSMenuItem]) {
            menu.addItem(item)
            group.append(item)
        }
        add(self.viewItem(SwitcherSection()), to: &self.switcherItems)
        add(.separator(), to: &self.switcherItems)
        menu.addItem(self.viewItem(HeaderSection()))
        add(.separator(), to: &self.limitItems)
        add(self.viewItem(LimitsSection()), to: &self.limitItems)
        add(.separator(), to: &self.todayItems)
        add(self.viewItem(HeroSection()), to: &self.todayItems)
        add(.separator(), to: &self.historyItems)
        add(self.viewItem(HistorySection()), to: &self.historyItems)
        add(.separator(), to: &self.windowItems)
        add(self.viewItem(WindowsSection()), to: &self.windowItems)
        menu.addItem(.separator())
        menu.addItem(self.viewItem(FooterSection()))
        menu.addItem(.separator())
        menu.addItem(self.actionItem("Refresh", symbol: "arrow.clockwise", key: "r", action: #selector(self.refresh)))
        menu.addItem(self.actionItem("Settings…", symbol: "gearshape", key: ",", action: #selector(self.openSettings)))
        menu.addItem(.separator())
        menu.addItem(self.actionItem("Quit count yo tokens", symbol: "power", key: "q", action: #selector(self.quit)))
        return menu
    }

    private func viewItem(_ content: some View) -> NSMenuItem {
        let host = NSHostingView(rootView: content
            .environment(self.store)
            .frame(width: Theme.menuWidth, alignment: .leading))
        host.sizingOptions = [.intrinsicContentSize]
        host.frame.size = host.fittingSize
        let item = NSMenuItem()
        item.view = host
        return item
    }

    private func actionItem(_ title: String, symbol: String, key: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.target = self
        return item
    }

    /// Re-run whenever the selection or the enabled set changes, including while the menu is open.
    private func observeLayout() {
        withObservationTracking {
            let provider = self.store.selected
            let prefs = self.store.prefs
            let groups: [([NSMenuItem], Bool)] = [
                (self.switcherItems, self.store.enabled.count > 1),
                (self.limitItems, provider.hasLimits && prefs.showsLimits),
                (self.todayItems, provider.hasSpend && prefs.showsToday),
                (self.historyItems, provider.hasSpend && prefs.showsHistory),
                (self.windowItems, provider.hasSpend && prefs.showsWindows),
            ]
            for (items, shows) in groups {
                for item in items where item.isHidden == shows { item.isHidden = !shows }
            }
        } onChange: {
            DispatchQueue.main.async { Main.delegate.observeLayout() }
        }
    }

    func menuWillOpen(_ menu: NSMenu) { self.store.menuWillOpen() }

    @objc private func refresh() { self.store.refreshNow() }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openSettings() {
        // Land on the provider that needs a key, when the menu was showing one.
        let current = self.store.current
        if current.limitsIssue == .needsKey || current.limitsIssue == .expired, current.id.needsPastedKey {
            self.store.settingsPane = .provider(current.id)
        }
        self.showSettings()
    }

    @objc private func openAbout() {
        self.store.settingsPane = .about
        self.showSettings()
    }

    /// A menu-bar app has no Dock icon, so macOS won't bring its windows forward on its own, and a
    /// window left on another Space (or behind a full-screen app) stays there. While Settings is open
    /// the app becomes a regular app, and the window follows the user to the active Space.
    private func showSettings() {
        let window = self.settingsWindow ?? SettingsWindow.make(store: self.store)
        if self.settingsWindow == nil {
            window.delegate = self
            self.settingsWindow = window
            self.observeSettingsTitle()
        }
        NSApp.setActivationPolicy(.regular)
        window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // The policy change lands on a later turn of the run loop; ask again once it has.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard !NSApp.isActive || !window.isKeyWindow else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// The window title follows the selected pane.
    private func observeSettingsTitle() {
        withObservationTracking {
            self.settingsWindow?.title = self.store.settingsPane.title
        } onChange: {
            DispatchQueue.main.async { Main.delegate.observeSettingsTitle() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) == self.settingsWindow else { return }
        // Back to a menu-bar-only app once Settings is gone.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: Status title

    private func observeStatusTitle() {
        withObservationTracking {
            self.updateStatusTitle()
        } onChange: {
            DispatchQueue.main.async { Main.delegate.observeStatusTitle() }
        }
    }

    private var iconKey = ""
    private var titleKey = ""

    private func updateStatusTitle() {
        guard let button = self.statusItem.button else { return }
        let prefs = self.store.prefs
        let model = self.store.menuBarModel
        let snapshot = model.snapshot
        func amount(_ cost: Double?, _ tokens: Int?) -> String {
            guard let cost, let tokens else { return "" }
            return " " + (snapshot?.measuresTokens == true ? Format.tokens(tokens) : Format.wholeMoney(cost))
        }
        let title: String = switch prefs.menuBarDisplay {
        case .icon: ""
        case .spend: model.id.hasSpend ? amount(snapshot?.today?.cost, snapshot?.today?.tokens) : ""
        case .window: model.id.hasSpend ? amount(snapshot?.currentWindow?.cost, snapshot?.currentWindow?.tokens) : ""
        case .limit: model.lowestLeft.map { " \(Int($0.rounded()))%" } ?? ""
        }
        let warns = prefs.warnsInMenuBar && (model.lowestLeft ?? 100) < 10
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        ]
        if warns, prefs.menuBarDisplay == .limit { attributes[.foregroundColor] = NSColor.systemRed }
        let titleKey = "\(title)|\(warns && prefs.menuBarDisplay == .limit)"
        if titleKey != self.titleKey {
            self.titleKey = titleKey
            button.attributedTitle = NSAttributedString(string: title, attributes: attributes)
        }

        let icon = StatusIcon.current(prefs.iconStyle, model: model)
        guard icon.key != self.iconKey else { return }
        self.iconKey = icon.key
        button.image = icon.image()
    }
}

/// The app's own icon, drawn in code: the tally on the accent tile. Shown in the Dock while Settings
/// is open, and in About.
enum AppIcon {
    @MainActor static let image: NSImage = {
        let renderer = ImageRenderer(content: AppIconView(size: 256))
        renderer.scale = 2
        return renderer.nsImage ?? NSImage()
    }()
}

struct AppIconView: View {
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: self.size * 0.225, style: .continuous)
            .fill(Theme.accent.gradient)
            .frame(width: self.size * 0.8, height: self.size * 0.8)
            .overlay {
                Image(nsImage: StatusIcon.image)
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: self.size * 0.5, height: self.size * 0.5)
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.18), radius: self.size * 0.02, y: self.size * 0.01)
            .frame(width: self.size, height: self.size)
            .environment(\.colorScheme, .light)
    }
}

/// Tally marks — four strokes and a slash. Template image, so it tints like every system extra.
enum StatusIcon {
    /// The icon for a style, with a key that changes only when the drawing would. The meter shows
    /// the first two limits left and falls back to the tally for providers without limits.
    @MainActor
    static func current(_ style: IconStyle, model: ProviderModel, now: Date = Date()) -> (key: String, image: () -> NSImage) {
        switch style {
        case .tally:
            return ("tally", { self.image })
        case .logo:
            return ("logo|\(model.id.rawValue)", { ProviderLogos.statusImage(model.id) })
        case .meter:
            let lefts = (model.limits?.items.prefix(2) ?? []).map { limit in
                limit.resetsAt.map { $0 <= now } == true ? 100 : limit.leftPercent
            }
            guard !lefts.isEmpty else { return ("tally", { self.image }) }
            return ("meter|" + lefts.map { String(Int($0.rounded())) }.joined(separator: ","), { self.meter(lefts) })
        }
    }

    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let strokes = NSBezierPath()
            strokes.lineWidth = 1.5
            strokes.lineCapStyle = .round
            for x in [4.75, 7.75, 10.75, 13.75] {
                strokes.move(to: NSPoint(x: x, y: 3.75))
                strokes.line(to: NSPoint(x: x, y: 14.25))
            }
            strokes.stroke()
            let slash = NSBezierPath()
            slash.lineWidth = 1.6
            slash.lineCapStyle = .round
            slash.move(to: NSPoint(x: 2.25, y: 5.25))
            slash.line(to: NSPoint(x: 16.25, y: 12.75))
            slash.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "count yo tokens"
        return image
    }()

    /// Two stacked bars, each filled to a limit's percent left (one bar when there's one limit).
    static func meter(_ lefts: [Double]) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            let heights: [CGFloat] = lefts.count > 1 ? [5, 3.5] : [6]
            let tops: [CGFloat] = lefts.count > 1 ? [13, 6.25] : [12]
            for (index, left) in lefts.prefix(2).enumerated() {
                let track = NSRect(x: 1.5, y: tops[index] - heights[index], width: 17, height: heights[index])
                NSColor.black.withAlphaComponent(0.3).setFill()
                NSBezierPath(roundedRect: track, xRadius: heights[index] / 2, yRadius: heights[index] / 2).fill()
                var fill = track
                fill.size.width = max(heights[index], track.width * min(1, max(0, left / 100)))
                NSColor.black.setFill()
                NSBezierPath(roundedRect: fill, xRadius: heights[index] / 2, yRadius: heights[index] / 2).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Limits left: " + lefts.map { "\(Int($0.rounded()))%" }.joined(separator: ", ")
        return image
    }
}
