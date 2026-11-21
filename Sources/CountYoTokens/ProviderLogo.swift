import AppKit
import SwiftUI
import TokenCore

/// Each provider's own mark, loaded once from its SVG. Templates, so views tint them.
@MainActor
enum ProviderLogos {
    private static let images: [ProviderID: NSImage] = {
        var images: [ProviderID: NSImage] = [:]
        for id in ProviderID.allCases {
            let source = NSImage(data: Data(id.logoSVG.utf8)) ?? NSImage(size: NSSize(width: 100, height: 100))
            let image = ProviderLogos.centred(source)
            image.isTemplate = true
            images[id] = image
        }
        return images
    }()

    /// The mark, filling its square edge to edge.
    static func image(_ id: ProviderID) -> NSImage { self.images[id]! }

    /// The mark sized for the menu bar.
    static func statusImage(_ id: ProviderID) -> NSImage {
        let logo = self.image(id)
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            logo.draw(in: rect.insetBy(dx: 1.5, dy: 1.5))
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Centres the mark on its ink rather than on the SVG's canvas, so every logo sits and sizes
    /// alike. Still drawn from the vector, at whatever scale is asked.
    private static func centred(_ source: NSImage) -> NSImage {
        guard let ink = self.inkBounds(source) else { return source }
        return NSImage(size: NSSize(width: 100, height: 100), flipped: false) { rect in
            // Scale the whole canvas so the ink fits the rect, then put the ink's middle in the middle.
            let scale = min(rect.width / ink.width, rect.height / ink.height)
            source.draw(in: NSRect(x: rect.midX - ink.midX * scale, y: rect.midY - ink.midY * scale,
                                   width: scale, height: scale))
            return true
        }
    }

    /// Where the drawn pixels are, as fractions of the canvas (origin bottom-left).
    private static func inkBounds(_ source: NSImage) -> NSRect? {
        let side = 256
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap),
              let data = bitmap.bitmapData
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        source.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        var minX = side, minY = side, maxX = -1, maxY = -1
        for row in 0 ..< side {
            for column in 0 ..< side where data[row * bitmap.bytesPerRow + column * 4 + 3] > 8 {
                minX = min(minX, column); maxX = max(maxX, column)
                minY = min(minY, row); maxY = max(maxY, row)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let unit = 1 / CGFloat(side)
        // Bitmap rows run top-down.
        return NSRect(x: CGFloat(minX) * unit, y: CGFloat(side - 1 - maxY) * unit,
                      width: CGFloat(maxX - minX + 1) * unit, height: CGFloat(maxY - minY + 1) * unit)
    }
}

extension ProviderID {
    fileprivate var logoSVG: String {
        switch self {
        case .claude: LogoData.claude
        case .codex: LogoData.codex
        case .opencodeGo, .zen: LogoData.opencode
        case .devin: LogoData.devin
        case .droid: LogoData.factory
        }
    }

    /// Go and Zen both wear OpenCode's mark, so wherever the mark stands alone they add a word.
    var sharesMark: Bool { self == .opencodeGo || self == .zen }

    /// The mark's own colour where the brand has one; the rest are black-and-white marks.
    var markColor: Color? {
        self == .claude ? Color(red: 0.851, green: 0.467, blue: 0.341) : nil
    }

    /// The tile behind the white mark in Settings, in each brand's colours.
    var tint: Color {
        switch self {
        case .claude: Color(red: 0.851, green: 0.467, blue: 0.341)
        case .codex: Color(white: 0.09)
        case .opencodeGo, .zen: Color(red: 0.129, green: 0.118, blue: 0.118)
        case .devin: Color(red: 0.11, green: 0.15, blue: 0.24)
        case .droid: Color(white: 0.06)
        }
    }
}

/// A provider's mark at any size, in the surrounding foreground style.
struct ProviderLogo: View {
    let id: ProviderID
    let size: CGFloat

    var body: some View {
        Image(nsImage: ProviderLogos.image(self.id))
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: self.size, height: self.size)
            .accessibilityLabel(self.id.displayName)
    }
}
