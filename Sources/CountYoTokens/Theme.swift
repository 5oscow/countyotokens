import AppKit
import SwiftUI

enum Theme {
    /// Warm terracotta, tuned separately for light and dark so it reads at the same weight in both.
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.91, green: 0.56, blue: 0.43, alpha: 1)
            : NSColor(srgbRed: 0.80, green: 0.40, blue: 0.27, alpha: 1)
    })

    /// Content width of every custom menu item.
    static let menuWidth: CGFloat = 300
    /// Lines content up with the menu's own item titles.
    static let inset: CGFloat = 14
}
