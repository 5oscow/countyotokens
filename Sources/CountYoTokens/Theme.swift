import AppKit
import SwiftUI

enum Theme {
    /// Warm terracotta, tuned separately for light and dark so it reads at the same weight in both.
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.91, green: 0.56, blue: 0.43, alpha: 1)
            : NSColor(srgbRed: 0.80, green: 0.40, blue: 0.27, alpha: 1)
    })

    /// Pace colours: muted sage and amber, quiet enough to sit beside grey secondary text.
    static let reserve = adaptive(
        light: NSColor(srgbRed: 0.33, green: 0.52, blue: 0.38, alpha: 1),
        dark: NSColor(srgbRed: 0.58, green: 0.73, blue: 0.60, alpha: 1))
    static let deficit = adaptive(
        light: NSColor(srgbRed: 0.70, green: 0.40, blue: 0.16, alpha: 1),
        dark: NSColor(srgbRed: 0.90, green: 0.66, blue: 0.42, alpha: 1))

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    /// Content width of every custom menu item.
    static let menuWidth: CGFloat = 300
    /// Lines content up with the menu's own item titles.
    static let inset: CGFloat = 14
}
