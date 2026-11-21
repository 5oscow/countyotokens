import AppKit
import Observation
import SwiftUI
import TokenCore

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
        if let folder = UserDefaults.standard.string(forKey: "menuProbe") {
            self.runMenuProbe(folder: folder)
        }
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
    /// Every custom-view item, kept at its content's height.
    private var viewItems: [NSMenuItem] = []

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
        // Whenever the content's height changes: after this layout pass, never inside it.
        let host = NSHostingView(rootView: MenuItemContent(content: content.environment(self.store)) { _ in
            MainLoop.soon { Main.delegate.fitItems() }
        })
        host.sizingOptions = [.intrinsicContentSize]
        host.frame.size = NSSize(width: Theme.menuWidth, height: host.fittingSize.height)
        let item = NSMenuItem()
        item.view = host
        self.viewItems.append(item)
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
            var changed = false
            for (items, shows) in groups {
                for item in items where item.isHidden == shows {
                    item.isHidden = !shows
                    changed = true
                }
            }
            if changed { self.refitSoon() }
        } onChange: {
            MainLoop.soon { Main.delegate.observeLayout() }
        }
    }

    /// Views off screen don't lay out, so a change made while the menu was closed (another provider,
    /// a setting) hasn't resized anything yet: size every section before the menu measures them.
    func menuNeedsUpdate(_ menu: NSMenu) { self.fitItems() }

    /// Sizes every section to the height its content wants, and tells the menu about each one that
    /// changed so it moves the items below. The menu sizes items by their frames and never asks the
    /// views, so this is what keeps a section from being clipped or leaving a gap.
    func fitItems() {
        for item in self.viewItems {
            guard let view = item.view else { continue }
            let height = view.fittingSize.height
            guard height > 0, abs(view.frame.height - height) > 0.25 else { continue }
            view.setFrameSize(NSSize(width: Theme.menuWidth, height: height))
            // An open menu resizes the item's container but doesn't always move the items below it
            // (`itemChanged` alone leaves them where they were). Showing or hiding an item is what
            // makes it lay every item out again, so cycle this one, within the turn, before any draw.
            if view.window != nil, !item.isHidden {
                item.isHidden = true
                item.isHidden = false
            } else {
                item.menu?.itemChanged(item)
            }
        }
    }

    /// Sections shown or hidden alongside a content change: fit now, and again once SwiftUI has laid
    /// out the content that came with it (a section coming back from hidden reports no change).
    private func refitSoon() {
        self.fitItems()
        for delay in [0.05, 0.35] {
            let timer = Timer(timeInterval: delay, repeats: false) { _ in
                MainActor.assumeIsolated { Main.delegate.fitItems() }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func menuWillOpen(_ menu: NSMenu) { self.store.menuWillOpen() }

    // MARK: Menu probe

    /// `-menuProbe <folder>`: opens the real menu for each enabled provider, first with it already
    /// selected and then switching to it while the menu is open, and checks every view item: its
    /// frame against the height its content wants, and that no item overlaps another or leaves the
    /// menu. Writes `menu-probe.txt` and quits. The system menu can only be checked by opening it.
    private func runMenuProbe(folder: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            let original = self.store.selected
            let enabled = self.store.enabled
            var report = ""
            for (index, id) in enabled.enumerated() {
                self.store.selected = id
                try? await Task.sleep(for: .seconds(1))
                report += await self.probeOpenMenu(name: "\(id.rawValue), opened on it", switchTo: nil)
                let other = enabled[(index + 1) % enabled.count]
                guard other != id else { continue }
                self.store.selected = other
                try? await Task.sleep(for: .seconds(1))
                report += await self.probeOpenMenu(name: "\(id.rawValue), switched from \(other.rawValue) while open", switchTo: id)
            }
            self.store.selected = original
            try? report.write(toFile: "\(folder)/menu-probe.txt", atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    private var probeReport = ""
    private var probeMainActorRan = false

    /// Opens the menu from the run loop, the way a click does. Opened from inside a main-queue job
    /// instead, the menu would hold that job for as long as it's open, and nothing else queued on
    /// the main actor (fetched limits, rescans) could land: the probe would test a menu nobody sees.
    private func probeOpenMenu(name: String, switchTo target: ProviderID?) async -> String {
        await withCheckedContinuation { continuation in
            MainLoop.soon {
                let report = Main.delegate.trackProbeMenu(name: name, switchTo: target)
                continuation.resume(returning: report)
            }
        }
    }

    private func trackProbeMenu(name: String, switchTo target: ProviderID?) -> String {
        self.probeReport = ""
        self.probeMainActorRan = false
        let check = Timer(timeInterval: 0.3, repeats: false) { _ in
            Task { @MainActor in Main.delegate.probeMainActorRan = true }
        }
        RunLoop.main.add(check, forMode: .common)
        if let target {
            let click = Timer(timeInterval: 0.8, repeats: false) { _ in
                MainActor.assumeIsolated {
                    withAnimation(.smooth(duration: 0.3)) { Main.delegate.store.selected = target }
                }
            }
            RunLoop.main.add(click, forMode: .common)
        }
        // Measured late, so limits fetched on open have landed and resized whatever they resize.
        let timer = Timer(timeInterval: 2.5, repeats: false) { _ in
            MainActor.assumeIsolated {
                let delegate = Main.delegate
                guard let menu = delegate.statusItem.menu else { return }
                delegate.probeReport = delegate.measure(menu, name: name)
                menu.cancelTracking()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.statusItem.button?.performClick(nil)
        return self.probeReport
    }

    private func measure(_ menu: NSMenu, name: String) -> String {
        var lines = ["== \(name)"]
        var problems = 0
        var placed: [(index: Int, low: CGFloat, high: CGFloat)] = []
        for (index, item) in menu.items.enumerated() where !item.isHidden {
            guard let view = item.view else { continue }
            let wants = view.fittingSize.height
            var flags: [String] = []
            if abs(view.frame.height - wants) > 0.5 { flags.append("WRONG HEIGHT") }
            if let window = view.window, let content = window.contentView {
                let rect = view.convert(view.bounds, to: content)
                placed.append((index, rect.minY, rect.maxY))
                if rect.minY < -0.5 || rect.maxY > content.bounds.height + 0.5 { flags.append("OUTSIDE MENU") }
            }
            problems += flags.count
            let span = placed.last.map { String(format: "y %6.1f–%6.1f", $0.low, $0.high) } ?? ""
            lines.append(String(format: "item %2d  frame %6.1f  wants %6.1f  %@  %@", index, view.frame.height, wants,
                                span, flags.joined(separator: ", ")))
        }
        for (one, next) in zip(placed, placed.dropFirst()) where min(one.high, next.high) - max(one.low, next.low) > 0.5 {
            problems += 1
            lines.append("items \(one.index) and \(next.index) OVERLAP")
        }
        if let window = placed.isEmpty ? nil : menu.items.first(where: { !$0.isHidden && $0.view != nil })?.view?.window {
            lines.append(String(format: "menu %.0f tall, screen %.0f usable", window.frame.height,
                                window.screen?.visibleFrame.height ?? 0))
        }
        if !self.probeMainActorRan {
            problems += 1
            lines.append("main actor STALLED while the menu was open")
        }
        lines.append(problems == 0 ? "OK" : "\(problems) PROBLEM(S)")
        return lines.joined(separator: "\n") + "\n"
    }

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
            MainLoop.soon { Main.delegate.observeSettingsTitle() }
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
            MainLoop.soon { Main.delegate.observeStatusTitle() }
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

/// Work for the main thread's next run-loop turn, in every common mode, event tracking included, so
/// it lands while the menu is open whatever else the main queue is doing.
enum MainLoop {
    static func soon(_ work: @escaping @MainActor () -> Void) {
        nonisolated(unsafe) let work = work
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated { work() }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}

/// A menu item's SwiftUI content, laid out at its own height, saying when that height changes so
/// the item can be refitted (see `fitItems`).
private struct MenuItemContent<Content: View>: View {
    let content: Content
    let heightChanged: @MainActor (CGFloat) -> Void

    var body: some View {
        self.content
            .frame(width: Theme.menuWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { self.heightChanged($0) }
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
