import AppKit
import SwiftUI
import Combine

// MARK: - Measured geometry & timing
//
// Every number here was measured frame by frame from a 120 fps screen recording of macOS 26's Spotlight
// (see AGENTS.md › "Spotlight choreography"): a 640×56 capsule (radius 28, plain at both ends — Spotlight's
// mode-button split is deliberately not reproduced); results turn it into a 640-wide rounded rectangle that
// springs to its height; ⎋ collapses it; closing fades + grows 4 %.

enum Liquid {
    static let width: CGFloat = 640
    static let pill: CGFloat = 56
    static let radius: CGFloat = 28
    static let circle: CGFloat = 56
    static let gap: CGFloat = 8
    static let pillEmptyWidth: CGFloat = width - 4 * (circle + gap)      // 384
    static let margin: CGFloat = 24                                       // transparent window margin (shadow + the 4 % close zoom)
    static let stackX: CGFloat = 440                                      // where the four circles wait, hidden inside the full-width capsule
    static let smoothing: CGFloat = 14                                    // smooth-union radius of the liquid
    static var circleCenters: [CGFloat] {   // 420 484 548 612
        let first: CGFloat = pillEmptyWidth + gap + circle / 2
        let pitch: CGFloat = circle + gap
        return [first, first + pitch, first + 2 * pitch, first + 3 * pitch]
    }

    // Springs (ω rad/s, ζ) fitted to the recording.
    static let pillSplit  = Spring(omega: 15.5, zeta: 0.90)   // capsule 640 → 384, launched with −6000 pt/s
    static let pillSplitV0: Double = -6000
    static let circleSplit = Spring(omega: 12.0, zeta: 0.75)  // circles 440 → their slots
    static let circleMerge = Spring(omega: 14.0, zeta: 0.90)  // slots → 440 while typing
    static let pillMerge  = Spring(omega: 20.0, zeta: 1.00)   // 384 → 640 while typing (starts 50 ms in)
    static let pillMergeDelay = 0.05
    static let expand     = Spring(omega: 26.0, zeta: 0.80)   // results: from 70 % of the way, with velocity
    static let expandStartFraction = 0.70
    static let expandV0PerPt: Double = 4.85                   // v0 = 4.85 × (H − 56) pt/s
    static let collapse   = Spring(omega: 31.0, zeta: 1.00)   // ⎋: critically damped back to the capsule
    static let openFade = 0.03
    static let closeDuration = 0.085
    static let closeScale: CGFloat = 1.04
    static let glyphFade = 0.15                               // mode glyphs blur/fade in once their circle has separated

    /// Spotlight's default spot: centred, capsule top 12.7 % down the screen. If the user has dragged Spotlight,
    /// its own remembered frame is used so Armada appears exactly where Spotlight would.
    static func pillFrame(on screen: NSScreen) -> NSRect {
        if let s = UserDefaults.standard.string(forKey: "panelFrame") {          // the user dragged Armada itself
            let r = NSRectFromString(s)
            if r.width == width, screen.frame.contains(r) { return NSRect(x: r.minX, y: r.maxY - pill, width: width, height: pill) }
        }
        if let s = UserDefaults(suiteName: "com.apple.Spotlight")?.string(forKey: "lastWindowPosition") {
            let r = NSRectFromString(s)
            if r.width == width, screen.frame.contains(r) { return NSRect(x: r.minX, y: r.maxY - pill, width: width, height: pill) }
        }
        let f = screen.frame
        return NSRect(x: f.midX - width / 2, y: f.maxY - 0.1273 * f.height - pill, width: width, height: pill)
    }
}

/// Damped spring solved analytically, so any frame time can be sampled without stepping.
struct Spring {
    var omega: Double
    var zeta: Double
    func value(t: Double, from: Double, to: Double, v0: Double = 0) -> Double {
        guard t > 0 else { return from }
        let x0 = from - to
        if zeta < 1 {
            let wd = omega * sqrt(1 - zeta * zeta)
            let b = (v0 + zeta * omega * x0) / wd
            return to + exp(-zeta * omega * t) * (x0 * cos(wd * t) + b * sin(wd * t))
        }
        return to + (x0 + (v0 + omega * x0) * t) * exp(-omega * t)
    }
    func settled(t: Double, distance: Double) -> Bool { abs(distance) * exp(-zeta * omega * t) < 0.15 }
}

// MARK: - Shape at an instant

/// The panel's silhouette: a rounded rectangle (the capsule when `height == pill`) smoothly unioned with four circles.
struct LiquidShape {
    var rectWidth: CGFloat        // right edge of the rounded rect / capsule
    var height: CGFloat           // rect height (56 = capsule)
    var circleX: [CGFloat]        // circle centres (y = 28); empty when merged
    var circleR: CGFloat = Liquid.circle / 2

    private func rectSDF(_ px: CGFloat, _ py: CGFloat) -> CGFloat {
        let r = Liquid.radius, hw = rectWidth / 2, hh = height / 2
        let qx = abs(px - hw) - (hw - r), qy = abs(py - hh) - (hh - r)
        let ox = max(qx, 0), oy = max(qy, 0)
        return sqrt(ox * ox + oy * oy) + min(max(qx, qy), 0) - r
    }

    /// Signed distance (points) to the union; negative inside.
    func distance(_ px: CGFloat, _ py: CGFloat) -> CGFloat {
        var d = rectSDF(px, py)
        let k = Liquid.smoothing
        for cx in circleX {
            let dx = px - cx, dy = py - Liquid.pill / 2
            let dc = sqrt(dx * dx + dy * dy) - circleR
            let h = max(k - abs(d - dc), 0) / k
            d = min(d, dc) - h * h * k * 0.25
        }
        return d
    }

    /// Rows (points, in shape space) that need the full field; everything else is the plain rounded rect.
    var bandRows: ClosedRange<CGFloat> { circleX.isEmpty ? (-1)...(-1) : (-8)...(Liquid.pill + 30) }
}

/// Rasterises a LiquidShape into the visual-effect mask (alpha) and the 1 pt specular rim (RGBA), at backing scale.
enum LiquidRaster {
    struct Output { let mask: CGImage; let rim: CGImage }

    /// `size` is the whole window in points; the shape is offset by `origin` (the transparent margin).
    static func render(_ shape: LiquidShape, size: CGSize, origin: CGPoint, scale: CGFloat) -> Output? {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard w > 0, h > 0 else { return nil }
        var mask = [UInt8](repeating: 0, count: w * h)
        var rim = [UInt8](repeating: 0, count: w * h * 4)
        let rimPx = 1.0 * scale                         // 1 pt specular rim
        let band = shape.bandRows
        let inv = 1 / scale
        let r = Liquid.radius

        mask.withUnsafeMutableBufferPointer { mp in
        rim.withUnsafeMutableBufferPointer { rp in
            @inline(__always) func put(_ col: Int, _ m: Int, _ dpx: CGFloat) {
                let cov = max(0, min(1, 0.5 - dpx))
                guard cov > 0 else { return }
                mp[m + col] = UInt8(cov * 255 + 0.5)
                let inner = max(0, min(1, 0.5 - (dpx + rimPx)))
                let rv = cov - inner
                if rv > 0.01 {
                    let i = (m + col) * 4, a = UInt8(rv * 255 + 0.5)
                    rp[i] = a; rp[i + 1] = a; rp[i + 2] = a; rp[i + 3] = a
                }
            }
            for row in 0..<h {
                let py = (CGFloat(row) + 0.5) * inv - origin.y
                let m = row * w
                if band.contains(py) {
                    // Liquid band: the full smooth-union field, every pixel.
                    for col in 0..<w {
                        let px = (CGFloat(col) + 0.5) * inv - origin.x
                        put(col, m, shape.distance(px, py) * scale)
                    }
                    continue
                }
                guard py > -1.5, py < shape.height + 1.5 else { continue }
                // Plain rounded rectangle: only the pixels near the two edges need the field; the interior is solid.
                let inset: CGFloat
                if py < r { let dy = max(0, r - py); inset = r - sqrt(max(0, r * r - dy * dy)) }
                else if py > shape.height - r { let dy = max(0, py - (shape.height - r)); inset = r - sqrt(max(0, r * r - dy * dy)) }
                else { inset = 0 }
                let nearEdgeRow = py < 0.5 || py > shape.height - 0.5 || py < r + 0.5 && inset > r - 1 || py > shape.height - r - 0.5 && inset > r - 1
                if nearEdgeRow || inset > r - 2 {
                    for col in 0..<w {
                        let px = (CGFloat(col) + 0.5) * inv - origin.x
                        guard px > -1, px < shape.rectWidth + 1 else { continue }
                        put(col, m, shape.rectSDFPublic(px, py) * scale)
                    }
                    continue
                }
                let left = (origin.x + inset) * scale, right = (origin.x + shape.rectWidth - inset) * scale
                let c0 = max(0, Int(left) - 4), c1 = min(w - 1, Int(right) + 4)
                for col in c0...c1 {
                    let px = (CGFloat(col) + 0.5) * inv - origin.x
                    let fc = CGFloat(col)
                    if fc > left + 4, fc < right - 5 { mp[m + col] = 255 } else { put(col, m, shape.rectSDFPublic(px, py) * scale) }
                }
            }
        }
        }
        guard let maskImage = image(alpha: mask, w: w, h: h), let rimImage = image(rgba: rim, w: w, h: h) else { return nil }
        return Output(mask: maskImage, rim: rimImage)
    }

    private static func image(alpha: [UInt8], w: Int, h: Int) -> CGImage? {
        alpha.withUnsafeBufferPointer { buf in
            guard let ctx = CGContext(data: UnsafeMutableRawPointer(mutating: buf.baseAddress), width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
            return ctx.makeImage()
        }
    }

    private static func image(rgba: [UInt8], w: Int, h: Int) -> CGImage? {
        rgba.withUnsafeBufferPointer { buf in
            guard let ctx = CGContext(data: UnsafeMutableRawPointer(mutating: buf.baseAddress), width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            return ctx.makeImage()
        }
    }
}

extension LiquidShape {
    func rectSDFPublic(_ px: CGFloat, _ py: CGFloat) -> CGFloat {
        let r = Liquid.radius, hw = rectWidth / 2, hh = height / 2
        let qx = abs(px - hw) - (hw - r), qy = abs(py - hh) - (hh - r)
        let ox = max(qx, 0), oy = max(qy, 0)
        return sqrt(ox * ox + oy * oy) + min(max(qx, qy), 0) - r
    }
}

// MARK: - What SwiftUI needs to know each frame

final class LiquidState: ObservableObject {
    @Published var pillWidth: CGFloat = Liquid.width       // the search field lives inside this
    @Published var contentAlpha: Double = 0                // results/chips fade
    @Published var contentHeight: CGFloat = Liquid.pill    // laid-out height of the results content
}

// MARK: - Choreographer

/// Drives the window frame, the liquid mask and the SwiftUI state from a display link, replaying Spotlight's timing.
/// Two independent tracks: the liquid (buttons fanned out ↔ merged into a full-width capsule) and the height.
@MainActor
final class PanelChoreographer {
    let state = LiquidState()
    private weak var panel: GlassPanel?
    private var link: CADisplayLink?
    private(set) var isVisible = false

    // Silhouette: always the full-width capsule / rounded rectangle (no mode buttons).
    private var pillR: Double = 640, circles: [Double] = []
    // Height track.
    private var heightStart: Double?, heightFrom: Double = 56, heightTarget: Double = 56, heightV0: Double = 0
    private var heightSpring = Liquid.expand
    private var height: Double = 56
    // Fades.
    private var contentFadeStart: Double?, contentFadeFrom: Double = 0, contentFadeTo: Double = 0
    private var openStart: Double?, closeStart: Double?
    private var closeCompletion: (() -> Void)?
    private var pillTop: CGFloat = 0, pillLeft: CGFloat = 0
    private var lastShape: LiquidShape?

    init(panel: GlassPanel) { self.panel = panel }

    /// Show at Spotlight's spot, already in the right layout for the current query/results (no transition on open
    /// besides Spotlight's 30 ms fade).
    func open(on screen: NSScreen, queryEmpty: Bool, contentHeight: CGFloat) {
        guard let panel else { return }
        let pf = Liquid.pillFrame(on: screen)
        pillLeft = pf.minX; pillTop = pf.maxY
        let now = CACurrentMediaTime()
        isVisible = true
        openStart = now; closeStart = nil; closeCompletion = nil
        heightStart = nil; contentFadeStart = nil
        height = Double(max(contentHeight, Liquid.pill)); heightTarget = height
        state.contentHeight = CGFloat(height)
        state.contentAlpha = height > 56 ? 1 : 0
        pillR = 640; circles = []
        panel.alphaValue = 0
        panel.contentScale = 1
        applyFrame()
        renderIfNeeded(force: true)
        startLink()
    }

    /// Called after every state change: what the panel should be showing now.
    func update(queryEmpty: Bool, contentHeight: CGFloat) {
        guard isVisible, closeStart == nil else { return }
        let now = CACurrentMediaTime()
        let target = Double(max(contentHeight, Liquid.pill))
        if abs(target - heightTarget) > 0.5 {
            let opening = heightTarget <= 56 && target > 56
            let closing = target <= 56
            if opening {
                heightSpring = Liquid.expand
                heightFrom = 56 + Liquid.expandStartFraction * (target - 56)
                heightV0 = Liquid.expandV0PerPt * (target - 56)
            } else if closing {
                heightSpring = Liquid.collapse; heightFrom = height; heightV0 = 0
            } else {
                heightSpring = Spring(omega: 40, zeta: 1); heightFrom = height; heightV0 = 0
            }
            heightTarget = target; heightStart = now
            state.contentHeight = CGFloat(max(target, 56))
            beginContentFade(to: target > 56 ? 1 : 0, now)
        }
        startLink()
    }

    func close(completion: @escaping () -> Void) {
        guard isVisible, closeStart == nil else { completion(); return }
        closeStart = CACurrentMediaTime()
        closeCompletion = completion
        startLink()
    }

    /// The user dragged the panel: adopt (and remember) the new spot, like Spotlight does.
    func noteMoved() {
        guard let panel, isVisible, link == nil else { return }
        let m = Liquid.margin
        pillLeft = panel.frame.minX + m; pillTop = panel.frame.maxY - m
        UserDefaults.standard.set(NSStringFromRect(NSRect(x: pillLeft, y: pillTop - Liquid.pill, width: Liquid.width, height: Liquid.pill)), forKey: "panelFrame")
    }

    func hideImmediately() {
        isVisible = false; stopLink(); closeStart = nil
        panel?.contentScale = 1
    }

    // MARK: internals

    private func beginContentFade(to: Double, _ now: Double) {
        contentFadeFrom = state.contentAlpha; contentFadeTo = to; contentFadeStart = now
    }

    private func startLink() {
        guard link == nil, let panel, let v = panel.contentView else { return }
        let l = v.displayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }
    private func stopLink() { link?.invalidate(); link = nil }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        var active = false

        if let s = openStart, let panel {
            let p = min(1, (now - s) / Liquid.openFade)
            panel.alphaValue = CGFloat(p)
            if p < 1 { active = true } else { openStart = nil }
        }

        if let s = heightStart {
            let t = now - s
            height = heightSpring.value(t: t, from: heightFrom, to: heightTarget, v0: heightV0)
            let span = max(abs(heightFrom - heightTarget), abs(heightV0) / heightSpring.omega, 1)
            if t > 0.08, heightSpring.settled(t: t, distance: span) { height = heightTarget; heightStart = nil } else { active = true }
        }

        if let s = contentFadeStart {
            let p = min(1, (now - s) / 0.1)
            state.contentAlpha = contentFadeFrom + (contentFadeTo - contentFadeFrom) * p
            if p < 1 { active = true } else { contentFadeStart = nil }
        }

        if let s = closeStart, let panel {
            let p = min(1, (now - s) / Liquid.closeDuration)
            panel.alphaValue = CGFloat(pow(1 - p, 1.5))
            panel.contentScale = 1 + (Liquid.closeScale - 1) * CGFloat(p)
            if p >= 1 {
                closeStart = nil; isVisible = false
                stopLink()
                let done = closeCompletion; closeCompletion = nil
                done?()
                return
            }
            active = true
        }

        state.pillWidth = CGFloat(pillR)
        applyFrame()
        renderIfNeeded(force: false)
        if !active { stopLink() }
    }

    private func applyFrame() {
        guard let panel else { return }
        let m = Liquid.margin
        let h = CGFloat(max(height, 56))
        let f = NSRect(x: pillLeft - m, y: pillTop - h - m, width: Liquid.width + 2 * m, height: h + 2 * m)
        if panel.frame != f { panel.setFrame(f, display: true) }
    }

    private func renderIfNeeded(force: Bool) {
        guard let panel else { return }
        let shape = LiquidShape(rectWidth: CGFloat(pillR), height: CGFloat(max(height, 56)), circleX: circles.map { CGFloat($0) })
        if !force, let l = lastShape, l.rectWidth == shape.rectWidth, l.height == shape.height, l.circleX == shape.circleX { return }
        lastShape = shape
        panel.applyLiquid(shape)
    }
}
