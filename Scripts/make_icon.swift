// Draws the app icon: a black, scratched and speckled tile with four hand-cut tally sticks and a
// slash. Seeded, so every run draws the same icon.
//
//   swift Scripts/make_icon.swift <out.png> [size] [--bone-slash]
//
// Scripts/make_icon.sh renders it at every size macOS asks for into Assets/AppIcon.icns.

import AppKit
import CoreGraphics
import SwiftUI

// MARK: Seeded randomness

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

// MARK: Setup

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write("usage: make_icon.swift <out.png> [size] [--bone-slash]\n".data(using: .utf8)!)
    exit(1)
}
let output = arguments[1]
let pixels = arguments.count >= 3 ? Int(arguments[2]) ?? 1024 : 1024
// The slash is the app's terracotta unless asked otherwise.
let orangeSlash = !arguments.contains("--bone-slash")

// Everything is laid out on Apple's 1024 icon grid and scaled to the requested size.
let scale = CGFloat(pixels) / 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { exit(1) }
ctx.scaleBy(x: scale, y: scale)
ctx.interpolationQuality = .high
ctx.setShouldAntialias(true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

// The macOS tile: 824 square with continuous corners, centred, room left for the shadow.
let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let tile = RoundedRectangle(cornerRadius: 185, style: .continuous).path(in: tileRect).cgPath

// MARK: Tile

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 28 * scale, color: color(0, 0, 0, 0.45))
ctx.addPath(tile)
ctx.setFillColor(color(0.05, 0.05, 0.05))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tile)
ctx.clip()

// Not flat black: a soft lift up top, falling to near-black at the corners.
let base = CGGradient(colorsSpace: space,
                      colors: [color(0.135, 0.13, 0.125), color(0.065, 0.063, 0.06), color(0.025, 0.025, 0.025)] as CFArray,
                      locations: [0, 0.55, 1])!
ctx.drawRadialGradient(base, startCenter: CGPoint(x: 470, y: 660), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 512), endRadius: 640, options: [.drawsAfterEndLocation])

var rng = Seeded(state: 0x7A11_1E5)

// Fine grain: thousands of near-invisible specks, light and dark.
for _ in 0 ..< 9000 {
    let p = CGPoint(x: rng.range(100, 924), y: rng.range(100, 924))
    let r = rng.range(0.35, 1.1)
    let light = rng.chance(0.55)
    ctx.setFillColor(light ? color(1, 0.97, 0.92, rng.range(0.015, 0.05)) : color(0, 0, 0, rng.range(0.1, 0.25)))
    ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
}

/// A scratch: a thin, slightly curving line that fades in and out along its length.
func scratch(_ rng: inout Seeded, in rect: CGRect, light: Bool, alpha: ClosedRange<CGFloat>, length: ClosedRange<CGFloat>) {
    let start = CGPoint(x: rng.range(rect.minX, rect.maxX), y: rng.range(rect.minY, rect.maxY))
    let angle = rng.range(-0.5, 0.5) + (rng.chance(0.5) ? .pi * 0.75 : .pi * 0.2)
    let size = rng.range(length.lowerBound, length.upperBound)
    let bend = rng.range(-0.12, 0.12)
    let steps = 14
    let peak = rng.range(alpha.lowerBound, alpha.upperBound)
    let width = rng.range(0.6, 1.8)
    var point = start
    var heading = angle
    for step in 0 ..< steps {
        let t = CGFloat(step) / CGFloat(steps)
        heading += bend / CGFloat(steps) * 3
        let next = CGPoint(x: point.x + cos(heading) * size / CGFloat(steps),
                           y: point.y + sin(heading) * size / CGFloat(steps))
        // Fades at both ends, with the odd skip where the tool lifted.
        let fade = sin(t * .pi) * (rng.chance(0.12) ? 0.2 : 1)
        ctx.setStrokeColor(light ? color(1, 0.96, 0.9, peak * fade) : color(0, 0, 0, peak * fade))
        ctx.setLineWidth(width * (0.6 + 0.4 * sin(t * .pi)))
        ctx.setLineCap(.round)
        ctx.move(to: point)
        ctx.addLine(to: next)
        ctx.strokePath()
        point = next
    }
}

// Scratches and scuffs in the surface.
for _ in 0 ..< 120 {
    scratch(&rng, in: tileRect, light: true, alpha: 0.04 ... 0.16, length: 15 ... 210)
}
for _ in 0 ..< 45 {
    scratch(&rng, in: tileRect, light: false, alpha: 0.3 ... 0.55, length: 20 ... 150)
}

// Dots: dust and pits, a few big enough to catch light on one side.
for _ in 0 ..< 420 {
    let p = CGPoint(x: rng.range(110, 914), y: rng.range(110, 914))
    let r = rng.range(0.8, rng.chance(0.08) ? 5.5 : 2.6)
    if rng.chance(0.5) {
        ctx.setFillColor(color(1, 0.95, 0.88, rng.range(0.04, 0.14)))
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    } else {
        ctx.setFillColor(color(0, 0, 0, rng.range(0.35, 0.6)))
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        ctx.setFillColor(color(1, 0.95, 0.88, 0.06))
        ctx.fillEllipse(in: CGRect(x: p.x - r * 0.9, y: p.y - r * 0.2, width: r * 1.2, height: r * 1.2))
    }
}

// MARK: Sticks

/// One stick, cut by hand: bowed a little, tapering, rough along both edges, chipped in places,
/// with broken ends.
func stickPath(_ rng: inout Seeded, from a: CGPoint, to b: CGPoint, width: CGFloat) -> CGPath {
    let dx = b.x - a.x, dy = b.y - a.y
    let length = hypot(dx, dy)
    let along = CGPoint(x: dx / length, y: dy / length)
    let normal = CGPoint(x: -along.y, y: along.x)
    let samples = 48
    let bow = rng.range(-7, 7)
    let wobblePhase = rng.range(0, .pi * 2)
    let wobble = rng.range(1.2, 2.6)
    let taper = rng.range(0.08, 0.18)

    // Nicks: small bites out of either edge, the way a knife or a fall chips a twig.
    var chips: [(side: Int, at: Int, span: Int, depth: CGFloat)] = []
    for _ in 0 ..< Int(rng.range(6, 10.99)) {
        chips.append((rng.chance(0.5) ? 1 : -1, Int(rng.range(3, CGFloat(samples - 3))), Int(rng.range(1, 2.99)),
                      rng.range(2.5, width * 0.17)))
    }
    func bite(side: Int, at index: Int) -> CGFloat {
        var depth: CGFloat = 0
        for chip in chips where chip.side == side {
            let distance = abs(index - chip.at)
            if distance <= chip.span { depth = max(depth, chip.depth * (1 - CGFloat(distance) / CGFloat(chip.span + 1))) }
        }
        return depth
    }

    var left: [CGPoint] = [], right: [CGPoint] = []
    // Edges drift rather than jitter: a slow random walk on each side, plus a fine tremor.
    var driftL: CGFloat = 0, driftR: CGFloat = 0
    for i in 0 ... samples {
        let t = CGFloat(i) / CGFloat(samples)
        let offset = bow * sin(t * .pi) + wobble * sin(t * 4.1 + wobblePhase)
        let centre = CGPoint(x: a.x + dx * t + normal.x * offset, y: a.y + dy * t + normal.y * offset)
        let half = width / 2 * (1 - taper * t)
        driftL = max(-2.6, min(2.6, driftL + rng.range(-0.9, 0.9)))
        driftR = max(-2.6, min(2.6, driftR + rng.range(-0.9, 0.9)))
        let l = half + driftL + rng.range(-0.5, 0.5) - bite(side: 1, at: i)
        let r = half + driftR + rng.range(-0.5, 0.5) - bite(side: -1, at: i)
        left.append(CGPoint(x: centre.x + normal.x * l, y: centre.y + normal.y * l))
        right.append(CGPoint(x: centre.x - normal.x * r, y: centre.y - normal.y * r))
    }

    let path = CGMutablePath()
    path.move(to: left[0])
    for p in left.dropFirst() { path.addLine(to: p) }
    // Broken top: a jagged edge across the end, sometimes splintered past it.
    let topLeft = left[samples], topRight = right[samples]
    for k in 1 ... 4 {
        let f = CGFloat(k) / 5
        let reach = rng.range(-7, rng.chance(0.3) ? 12 : 5)
        path.addLine(to: CGPoint(x: topLeft.x + (topRight.x - topLeft.x) * f + along.x * reach,
                                 y: topLeft.y + (topRight.y - topLeft.y) * f + along.y * reach))
    }
    for p in right.reversed() { path.addLine(to: p) }
    let bottomRight = right[0], bottomLeft = left[0]
    for k in 1 ... 4 {
        let f = CGFloat(k) / 5
        let reach = rng.range(-5, rng.chance(0.3) ? 10 : 4)
        path.addLine(to: CGPoint(x: bottomRight.x + (bottomLeft.x - bottomRight.x) * f - along.x * reach,
                                 y: bottomRight.y + (bottomLeft.y - bottomRight.y) * f - along.y * reach))
    }
    path.closeSubpath()
    return path
}

/// Fills a stick: a shadow beneath it, a bone-to-ash gradient across it, grain along it, a knot or
/// two, and a highlight on the lit edge.
func drawStick(_ rng: inout Seeded, from a: CGPoint, to b: CGPoint, width: CGFloat, tint: [CGColor]) {
    let path = stickPath(&rng, from: a, to: b, width: width)
    let dx = b.x - a.x, dy = b.y - a.y
    let length = hypot(dx, dy)
    let normal = CGPoint(x: -dy / length, y: dx / length)
    let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 5 * scale, height: -9 * scale), blur: 16 * scale, color: color(0, 0, 0, 0.75))
    ctx.addPath(path)
    ctx.setFillColor(tint[1])
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let across = CGGradient(colorsSpace: space, colors: tint as CFArray, locations: [0, 0.45, 1])!
    ctx.drawLinearGradient(across,
                           start: CGPoint(x: mid.x + normal.x * width * 0.6, y: mid.y + normal.y * width * 0.6),
                           end: CGPoint(x: mid.x - normal.x * width * 0.6, y: mid.y - normal.y * width * 0.6),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // Grain: broken lines running the length of the stick.
    for _ in 0 ..< 13 {
        let lane = rng.range(-width * 0.4, width * 0.4)
        var t = rng.range(0, 0.3)
        while t < 1 {
            let run = rng.range(0.08, 0.35)
            let end = min(1, t + run)
            ctx.setStrokeColor(color(0.2, 0.14, 0.08, rng.range(0.08, 0.22)))
            ctx.setLineWidth(rng.range(0.5, 1.3))
            ctx.move(to: CGPoint(x: a.x + dx * t + normal.x * lane, y: a.y + dy * t + normal.y * lane))
            ctx.addLine(to: CGPoint(x: a.x + dx * end + normal.x * (lane + rng.range(-1.5, 1.5)),
                                    y: a.y + dy * end + normal.y * (lane + rng.range(-1.5, 1.5))))
            ctx.strokePath()
            t = end + rng.range(0.03, 0.15)
        }
    }
    let angle = atan2(dy, dx)
    // A faint knot: a short dark streak with grain bending round it.
    if rng.chance(0.7) {
        let t = rng.range(0.25, 0.75)
        let lane = rng.range(-width * 0.18, width * 0.18)
        let c = CGPoint(x: a.x + dx * t + normal.x * lane, y: a.y + dy * t + normal.y * lane)
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: angle)
        ctx.setFillColor(color(0.25, 0.17, 0.1, 0.32))
        ctx.fillEllipse(in: CGRect(x: -7, y: -2.2, width: 14, height: 4.4))
        ctx.setStrokeColor(color(0.25, 0.17, 0.1, 0.18))
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: CGRect(x: -12, y: -5, width: 24, height: 10))
        ctx.restoreGState()
    }
    // Bark left near the ends: dark, ragged patches.
    for end in [CGFloat(0.04), 0.96] where rng.chance(0.65) {
        let t = end + rng.range(-0.05, 0.05)
        let side: CGFloat = rng.chance(0.5) ? 1 : -1
        let c = CGPoint(x: a.x + dx * t + normal.x * side * width * 0.32, y: a.y + dy * t + normal.y * side * width * 0.32)
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: angle)
        let patch = CGMutablePath()
        let points = 9
        for k in 0 ..< points {
            let theta = CGFloat(k) / CGFloat(points) * .pi * 2
            let radius = rng.range(0.6, 1)
            let p = CGPoint(x: cos(theta) * rng.range(10, 22) * radius, y: sin(theta) * rng.range(5, 9) * radius)
            k == 0 ? patch.move(to: p) : patch.addLine(to: p)
        }
        patch.closeSubpath()
        ctx.addPath(patch)
        ctx.setFillColor(color(0.27, 0.19, 0.12, 0.75))
        ctx.fillPath()
        ctx.restoreGState()
    }
    // Pores and specks.
    for _ in 0 ..< 140 {
        let t = rng.range(0, 1)
        let lane = rng.range(-width * 0.5, width * 0.5)
        let c = CGPoint(x: a.x + dx * t + normal.x * lane, y: a.y + dy * t + normal.y * lane)
        let r = rng.range(0.4, 1.3)
        ctx.setFillColor(rng.chance(0.75) ? color(0.22, 0.15, 0.09, rng.range(0.12, 0.35)) : color(1, 1, 1, 0.25))
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }
    // Round it: the edges fall into shadow, as a cylinder's do.
    for (lineWidth, alpha) in [(CGFloat(12), CGFloat(0.12)), (7, 0.14), (3, 0.16)] {
        ctx.addPath(path)
        ctx.setStrokeColor(color(0.12, 0.08, 0.05, alpha))
        ctx.setLineWidth(lineWidth)
        ctx.strokePath()
    }
    ctx.restoreGState()
}

let bone = [color(0.95, 0.9, 0.8), color(0.84, 0.77, 0.65), color(0.6, 0.52, 0.41)]
let ember = [color(0.97, 0.6, 0.43), color(0.84, 0.43, 0.28), color(0.55, 0.24, 0.14)]

var sticks = Seeded(state: 0x5EED_0F_7A11)
let tops: [CGFloat] = [735, 748, 728, 742]
let bottoms: [CGFloat] = [285, 274, 290, 280]
for (index, x) in [346.0, 448, 552, 654].enumerated() {
    let lean = sticks.range(-10, 10)
    drawStick(&sticks, from: CGPoint(x: x - lean, y: bottoms[index]), to: CGPoint(x: x + lean, y: tops[index]),
              width: sticks.range(50, 58), tint: bone)
}
drawStick(&sticks, from: CGPoint(x: 252, y: 352), to: CGPoint(x: 776, y: 676), width: 54,
          tint: orangeSlash ? ember : bone)

// MARK: Blend

// Fine scratches over everything, sticks included, so they sit in the surface rather than on it.
var over = Seeded(state: 0xB1E_ED)
for _ in 0 ..< 40 {
    scratch(&over, in: tileRect.insetBy(dx: 80, dy: 80), light: over.chance(0.4), alpha: 0.05 ... 0.18, length: 15 ... 120)
}
// Cut marks across the sticks.
for _ in 0 ..< 26 {
    scratch(&over, in: CGRect(x: 300, y: 280, width: 420, height: 460), light: false, alpha: 0.18 ... 0.38, length: 8 ... 34)
}
// Dust on top.
for _ in 0 ..< 500 {
    let p = CGPoint(x: over.range(110, 914), y: over.range(110, 914))
    let r = over.range(0.4, 1.4)
    ctx.setFillColor(over.chance(0.5) ? color(0, 0, 0, over.range(0.15, 0.4)) : color(1, 0.96, 0.9, over.range(0.03, 0.09)))
    ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
}
// Vignette, so the edges fall away and the sticks hold the middle.
let vignette = CGGradient(colorsSpace: space, colors: [color(0, 0, 0, 0), color(0, 0, 0, 0.55)] as CFArray,
                          locations: [0.55, 1])!
ctx.drawRadialGradient(vignette, startCenter: CGPoint(x: 512, y: 530), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 530), endRadius: 600, options: [.drawsAfterEndLocation])
ctx.restoreGState()

// A hairline rim catching the light along the top edge.
ctx.saveGState()
ctx.addPath(tile)
ctx.clip()
ctx.addPath(tile)
ctx.setStrokeColor(color(1, 1, 1, 0.1))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

guard let image = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: image)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
