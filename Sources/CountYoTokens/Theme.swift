import AppKit
import SwiftUI

enum Theme {
    /// Warm terracotta, tuned separately for light and dark so it reads at the same weight in both.
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.91, green: 0.56, blue: 0.43, alpha: 1)
            : NSColor(srgbRed: 0.80, green: 0.40, blue: 0.27, alpha: 1)
    })

    /// Pace colours: Apple's accessible green and orange in light mode, the system ones in dark.
    static let reserve = adaptive(light: NSColor(srgbRed: 0.14, green: 0.54, blue: 0.24, alpha: 1), dark: .systemGreen)
    static let deficit = adaptive(light: NSColor(srgbRed: 0.79, green: 0.20, blue: 0.0, alpha: 1), dark: .systemOrange)

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
