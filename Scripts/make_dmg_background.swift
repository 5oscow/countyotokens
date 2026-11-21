// Draws the disk image window's background: a slate board, scuffed and chalk-dusted, with an
// orange chalk arrow from the app to Applications. Seeded, so every run draws the same picture.
//
//   swift Scripts/make_dmg_background.swift <out.png> [scale]
//
// The window is 600 × 340 points; the app sits at (150, 160) and Applications at (450, 160).
// The slate is a middle grey on purpose: Finder writes the icon names in black in light mode and
// white in dark mode, and both read on it.

import AppKit
import CoreGraphics

struct Seeded {
    var state: UInt64
    mutating func next() -> UInt64 {
        self.state &+= 0x9E37_79B9_7F4A_7C15
        var z = self.state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> CGFloat { CGFloat(self.next() >> 11) / CGFloat(1 << 53) }
    mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * self.unit() }
    mutating func chance(_ p: CGFloat) -> Bool { self.unit() < p }
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write("usage: make_dmg_background.swift <out.png> [scale]\n".data(using: .utf8)!)
    exit(1)
}
let scale = arguments.count >= 3 ? CGFloat(Double(arguments[2]) ?? 1) : 1
let size = CGSize(width: 600, height: 340)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                          bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { exit(1) }
// Top-left origin, in points.
ctx.translateBy(x: 0, y: size.height * scale)
ctx.scaleBy(x: scale, y: -scale)
ctx.setShouldAntialias(true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

var rng = Seeded(state: 0xD15C_0B0A)
let bounds = CGRect(origin: .zero, size: size)
let app = CGPoint(x: 150, y: 160), applications = CGPoint(x: 450, y: 160)

// MARK: Slate

// Lifted where the icons sit, falling off a little toward the edges.
let slate = CGGradient(colorsSpace: space,
                       colors: [color(0.475, 0.47, 0.455), color(0.43, 0.425, 0.415), color(0.36, 0.355, 0.35)] as CFArray,
                       locations: [0, 0.6, 1])!
ctx.drawRadialGradient(slate, startCenter: CGPoint(x: 300, y: 155), startRadius: 0,
                       endCenter: CGPoint(x: 300, y: 190), endRadius: 420, options: [.drawsAfterEndLocation])

// Old chalk wiped off: wide, faint clouds.
for _ in 0 ..< 9 {
    let center = CGPoint(x: rng.range(-40, 640), y: rng.range(-20, 400))
    let radius = rng.range(60, 190)
    let dust = CGGradient(colorsSpace: space, colors: [color(1, 0.98, 0.94, rng.range(0.025, 0.06)), color(1, 0.98, 0.94, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.saveGState()
    // Wiped sideways, so the clouds are wider than tall.
    ctx.translateBy(x: center.x, y: center.y)
    ctx.scaleBy(x: 1.8, y: 0.7)
    ctx.drawRadialGradient(dust, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius, options: [])
    ctx.restoreGState()
}

// Grain: specks lighter and darker than the slate.
for _ in 0 ..< 9000 {
    let light = rng.chance(0.5)
    ctx.setFillColor(light ? color(1, 0.97, 0.92, rng.range(0.02, 0.07)) : color(0, 0, 0, rng.range(0.03, 0.09)))
    let d = rng.range(0.4, 1.1)
    ctx.fillEllipse(in: CGRect(x: rng.range(0, 600), y: rng.range(0, 340), width: d, height: d))
}
// Pits and chalk crumbs, fewer and bigger.
for _ in 0 ..< 140 {
    let light = rng.chance(0.55)
    ctx.setFillColor(light ? color(1, 0.97, 0.92, rng.range(0.06, 0.2)) : color(0, 0, 0, rng.range(0.08, 0.2)))
    let d = rng.range(0.9, 2.6)
    ctx.fillEllipse(in: CGRect(x: rng.range(0, 600), y: rng.range(0, 340), width: d, height: d * rng.range(0.7, 1)))
}

func scratch(light: Bool, alpha: ClosedRange<CGFloat>, length: ClosedRange<CGFloat>) {
    var point = CGPoint(x: rng.range(-20, 620), y: rng.range(-20, 400))
    var heading = rng.range(-0.5, 0.5) + (rng.chance(0.5) ? .pi * 0.8 : .pi * 0.15)
    let total = rng.range(length.lowerBound, length.upperBound)
    let bend = rng.range(-0.1, 0.1)
    let peak = rng.range(alpha.lowerBound, alpha.upperBound)
    let width = rng.range(0.4, 1.1)
    let steps = 12
    for step in 0 ..< steps {
        let t = CGFloat(step) / CGFloat(steps)
        heading += bend / CGFloat(steps) * 3
        let next = CGPoint(x: point.x + cos(heading) * total / CGFloat(steps),
                           y: point.y + sin(heading) * total / CGFloat(steps))
        let fade = sin(t * .pi) * (rng.chance(0.12) ? 0.2 : 1)
        ctx.setStrokeColor(light ? color(1, 0.97, 0.92, peak * fade) : color(0, 0, 0, peak * fade))
        ctx.setLineWidth(width * (0.6 + 0.4 * sin(t * .pi)))
        ctx.setLineCap(.round)
        ctx.move(to: point)
        ctx.addLine(to: next)
        ctx.strokePath()
        point = next
    }
}

for _ in 0 ..< 55 { scratch(light: true, alpha: 0.03 ... 0.1, length: 20 ... 160) }
for _ in 0 ..< 40 { scratch(light: false, alpha: 0.05 ... 0.14, length: 15 ... 110) }

// MARK: Chalk

/// A chalk line: many fine, broken passes along the path, so the slate shows through.
func chalk(_ points: [CGPoint], width: CGFloat, color tint: (CGFloat, CGFloat, CGFloat), strength: CGFloat) {
    for _ in 0 ..< 26 {
        let wobble = CGPoint(x: rng.range(-width / 2, width / 2), y: rng.range(-width / 2, width / 2))
        var previous = points[0]
        for next in points.dropFirst() {
            // Break each segment into short dabs that skip where the chalk lifted off the slate.
            let pieces = max(2, Int(hypot(next.x - previous.x, next.y - previous.y) / 3))
            for i in 0 ..< pieces where !rng.chance(0.22) {
                let a = CGFloat(i) / CGFloat(pieces), b = CGFloat(i + 1) / CGFloat(pieces)
                ctx.setStrokeColor(color(tint.0, tint.1, tint.2, strength * rng.range(0.25, 0.7)))
                ctx.setLineWidth(rng.range(0.5, 1.4))
                ctx.setLineCap(.round)
                ctx.move(to: CGPoint(x: previous.x + (next.x - previous.x) * a + wobble.x,
                                     y: previous.y + (next.y - previous.y) * a + wobble.y))
                ctx.addLine(to: CGPoint(x: previous.x + (next.x - previous.x) * b + wobble.x,
                                        y: previous.y + (next.y - previous.y) * b + wobble.y))
                ctx.strokePath()
            }
            previous = next
        }
    }
}

/// Points along a gentle arc from `a` to `b`, drawn by hand: never quite straight.
func arc(from a: CGPoint, to b: CGPoint, lift: CGFloat) -> [CGPoint] {
    (0 ... 40).map { step in
        let t = CGFloat(step) / 40
        return CGPoint(x: a.x + (b.x - a.x) * t + rng.range(-0.4, 0.4),
                       y: a.y + (b.y - a.y) * t - sin(t * .pi) * lift + rng.range(-0.4, 0.4))
    }
}

let orange = (CGFloat(0.93), CGFloat(0.5), CGFloat(0.3))
let start = CGPoint(x: app.x + 88, y: app.y - 4), tip = CGPoint(x: applications.x - 86, y: applications.y - 6)
let lift: CGFloat = 26
chalk(arc(from: start, to: tip, lift: lift), width: 6, color: orange, strength: 1)
// The head: two strokes back from the tip, either side of the way the arc arrives.
let back = atan2(-.pi * lift, -(tip.x - start.x))
for side in [-0.6, 0.55] as [CGFloat] {
    let angle = back + side, length: CGFloat = side < 0 ? 19 : 17
    chalk([tip, CGPoint(x: tip.x + cos(angle) * length, y: tip.y + sin(angle) * length)], width: 6, color: orange, strength: 1)
}

// MARK: Edge

// A soft shadow inside the frame, as if the slate sat under the window's edge.
let vignette = CGGradient(colorsSpace: space, colors: [color(0, 0, 0, 0), color(0, 0, 0, 0.22)] as CFArray,
                          locations: [0.55, 1])!
ctx.drawRadialGradient(vignette, startCenter: CGPoint(x: 300, y: 180), startRadius: 0,
                       endCenter: CGPoint(x: 300, y: 180), endRadius: 400, options: [.drawsAfterEndLocation])

guard let image = ctx.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL,
                                                        "public.png" as CFString, 1, nil)
else { exit(1) }
// 72 dpi per point, so Finder lays the @2x picture over the same 600 × 340.
CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: 72 * scale,
                                                 kCGImagePropertyDPIHeight: 72 * scale] as CFDictionary)
CGImageDestinationFinalize(destination)
