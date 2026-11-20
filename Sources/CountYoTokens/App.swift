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
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem.autosaveName = "countyotokens"
        self.statusItem.isVisible = true
        self.statusItem.button?.image = StatusIcon.image
        self.statusItem.button?.imagePosition = .imageLeading
        self.statusItem.button?.toolTip = "count yo tokens"
        self.statusItem.menu = self.makeMenu()
        self.observeStatusTitle()
    }

    // MARK: Menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        // `-appearance light|dark` on the command line forces one look (for screenshots).
        if let forced = UserDefaults.standard.string(forKey: "appearance") {
            menu.appearance = NSAppearance(named: forced == "light" ? .aqua : .darkAqua)
        }
        menu.autoenablesItems = false
        menu.addItem(self.viewItem(HeaderSection()))
        menu.addItem(.separator())
        menu.addItem(self.viewItem(HeroSection()))
        menu.addItem(.separator())
        menu.addItem(self.viewItem(HistorySection()))
        menu.addItem(.separator())
        menu.addItem(self.viewItem(WindowsSection()))
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

    func menuWillOpen(_ menu: NSMenu) {
        self.store.refresh()
        self.store.reloadAccount()
    }

    @objc private func refresh() { self.store.refresh() }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openSettings() {
        if self.settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsPanel().environment(self.store))
            controller.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: controller)
            window.title = "count yo tokens Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.settingsWindow = window
        }
        NSApp.activate()
        self.settingsWindow?.makeKeyAndOrderFront(nil)
        // Nothing pre-selected: the time field would otherwise open with its hour highlighted.
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
        let cost = self.store.showsSpendInMenuBar ? self.store.snapshot?.today?.cost : nil
        let title = cost.map { " " + Format.wholeMoney($0) } ?? ""
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
