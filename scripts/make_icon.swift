import AppKit

func draw(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let s = size
    let r = NSRect(x: 0, y: 0, width: s, height: s)
    let radius = s * 0.225
    let clip = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
    clip.addClip()
    // Left half: light blue; right half: deep blue (Finder's two-tone face).
    NSColor(calibratedRed: 0.62, green: 0.83, blue: 0.98, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: s * 0.5, height: s).fill()
    NSColor(calibratedRed: 0.06, green: 0.36, blue: 0.86, alpha: 1).setFill(); NSRect(x: s * 0.5, y: 0, width: s * 0.5, height: s).fill()
    // Face: eyes and smile.
    let line = NSBezierPath(); line.lineWidth = s * 0.055; line.lineCapStyle = .round
    NSColor(calibratedWhite: 0.08, alpha: 0.9).setStroke()
    line.move(to: NSPoint(x: s * 0.31, y: s * 0.60)); line.line(to: NSPoint(x: s * 0.31, y: s * 0.70))
    line.stroke()
    NSColor.white.setStroke()
    let re = NSBezierPath(); re.lineWidth = s * 0.055; re.lineCapStyle = .round
    re.move(to: NSPoint(x: s * 0.69, y: s * 0.60)); re.line(to: NSPoint(x: s * 0.69, y: s * 0.70)); re.stroke()
    let smile = NSBezierPath(); smile.lineWidth = s * 0.05; smile.lineCapStyle = .round
    smile.appendArc(withCenter: NSPoint(x: s * 0.5, y: s * 0.47), radius: s * 0.21, startAngle: 200, endAngle: 340)
    NSColor(calibratedWhite: 0.08, alpha: 0.9).setStroke()
    smile.stroke()
    // Magnifying glass badge, bottom right.
    let glass = NSBezierPath(); glass.lineWidth = s * 0.06; glass.lineCapStyle = .round
    glass.appendOval(in: NSRect(x: s * 0.58, y: s * 0.12, width: s * 0.2, height: s * 0.2))
    glass.move(to: NSPoint(x: s * 0.62, y: s * 0.16)); glass.line(to: NSPoint(x: s * 0.52, y: s * 0.06))
    NSColor.white.setStroke(); glass.stroke()
    img.unlockFocus()
    return img
}

let sizes: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var entries: [[String: Any]] = []
for (pt, scale) in sizes {
    let px = pt * scale
    let img = draw(size: CGFloat(px))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    let name = "icon_\(pt)x\(pt)@\(scale)x.png"
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "/" + name))
    entries.append(["size": "\(pt)x\(pt)", "idiom": "mac", "filename": name, "scale": "\(scale)x"])
}
let contents: [String: Any] = ["images": entries, "info": ["version": 1, "author": "xcode"]]
try! JSONSerialization.data(withJSONObject: contents, options: .prettyPrinted).write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "/Contents.json"))
print("icon written")
