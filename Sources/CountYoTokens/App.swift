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
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
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
        self.observeLayout()
        self.observeStatusTitle()
    }

    // MARK: Menu

    /// Items that only some providers have, shown or hidden as the selection changes.
    private var switcherItems: [NSMenuItem] = []
    private var limitItems: [NSMenuItem] = []
    private var spendItems: [NSMenuItem] = []

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
        add(.separator(), to: &self.spendItems)
        add(self.viewItem(HeroSection()), to: &self.spendItems)
        add(.separator(), to: &self.spendItems)
        add(self.viewItem(HistorySection()), to: &self.spendItems)
        add(.separator(), to: &self.spendItems)
        add(self.viewItem(WindowsSection()), to: &self.spendItems)
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
            let showsSwitcher = self.store.enabled.count > 1
            for item in self.switcherItems where item.isHidden == showsSwitcher { item.isHidden = !showsSwitcher }
            for item in self.limitItems where item.isHidden == provider.hasLimits { item.isHidden = !provider.hasLimits }
            for item in self.spendItems where item.isHidden == provider.hasSpend { item.isHidden = !provider.hasSpend }
        } onChange: {
            DispatchQueue.main.async { Main.delegate.observeLayout() }
        }
    }

    func menuWillOpen(_ menu: NSMenu) { self.store.menuWillOpen() }

    @objc private func refresh() { self.store.refreshNow() }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openSettings() {
        if self.settingsWindow == nil { self.settingsWindow = SettingsWindow.make(store: self.store) }
        NSApp.activate()
        self.settingsWindow?.makeKeyAndOrderFront(nil)
        // Nothing pre-selected: no focus ring on the first control when the window opens.
        self.settingsWindow?.makeFirstResponder(nil)
    }

    // MARK: Status title

    private func observeStatusTitle() {
        withObservationTracking {
            self.updateStatusTitle()
        } onChange: {
            DispatchQueue.main.async { Main.delegate.observeStatusTitle() }
        }
    }

    private func updateStatusTitle() {
        guard let button = self.statusItem.button else { return }
        let model = self.store.current
        let title: String = switch self.store.menuBarDisplay {
        case .icon: ""
        case .spend: model.snapshot?.today.map { " " + Format.wholeMoney($0.cost) } ?? ""
        case .limit: model.lowestLeft.map { " \(Int($0.rounded()))%" } ?? ""
        }
        guard button.attributedTitle.string != title else { return }
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        ])
    }
}

/// Tally marks — four strokes and a slash. Template image, so it tints like every system extra.
enum StatusIcon {
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
}
