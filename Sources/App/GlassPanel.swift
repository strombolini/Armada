import AppKit
import SwiftUI
import Quartz

/// A borderless, non-activating floating panel with Spotlight's rounded glass look.
final class GlassPanel: NSPanel {
    private let effect = NSVisualEffectView()
    private var hosting: NSView?
    var onResignKey: (() -> Void)?

    init(width: CGFloat, cornerRadius: CGFloat) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: 60),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        animationBehavior = .utilityWindow
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        acceptsMouseMovedEvents = true
        // The HUD material is always dark, so every control inside must resolve its colours in the dark appearance
        // regardless of the system setting — otherwise text selection etc. come out in light-mode pastels.
        appearance = NSAppearance(named: .darkAqua)
        effect.appearance = NSAppearance(named: .darkAqua)

        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.autoresizingMask = [.width, .height]
        // The silhouette (capsule / circles / rounded rect) is a per-frame mask; the 1 pt specular rim is a layer on top.
        rim.contentsScale = 2
        rim.opacity = 0.22
        rim.zPosition = 1
        effect.layer?.addSublayer(rim)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 60))
        root.wantsLayer = true
        root.autoresizingMask = [.width, .height]
        effect.frame = root.bounds
        root.addSubview(effect)
        contentView = root
    }

    private let rim = CALayer()

    /// Uniform zoom of everything in the window (the 4 % growth while closing), about the centre.
    var contentScale: CGFloat = 1 {
        didSet {
            guard let l = effect.layer else { return }
            let b = effect.bounds
            l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            l.position = CGPoint(x: b.midX, y: b.midY)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            l.transform = CATransform3DMakeScale(contentScale, contentScale, 1)
            CATransaction.commit()
        }
    }

    /// Install the liquid silhouette for this frame.
    func applyLiquid(_ shape: LiquidShape) {
        let size = frame.size
        guard let out = LiquidRaster.render(shape, size: size, origin: CGPoint(x: Liquid.margin, y: Liquid.margin), scale: backingScaleFactor) else { return }
        let img = NSImage(cgImage: out.mask, size: size)
        img.resizingMode = .stretch
        effect.maskImage = img
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rim.contents = out.rim
        rim.frame = CGRect(origin: .zero, size: size)
        CATransaction.commit()
        invalidateShadow()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The SwiftUI content sits inside the transparent margin, pinned to the top-left at its own laid-out size, so
    /// the window can grow/shrink around it frame by frame without reflowing it.
    func setContent<V: View>(_ view: V) {
        hosting?.removeFromSuperview()
        let h = NSHostingView(rootView: view)
        h.translatesAutoresizingMaskIntoConstraints = false
        h.layer?.zPosition = 2
        effect.addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: Liquid.margin),
            h.topAnchor.constraint(equalTo: effect.topAnchor, constant: Liquid.margin),
            h.widthAnchor.constraint(equalToConstant: Liquid.width),
        ])
        hosting = h
    }

    override func resignKey() {
        super.resignKey()
        // While our app stays active, nothing else should hold the keyboard: if key status went to nothing (or to an
        // invisible helper window), take it back. Dismissal happens on app deactivation (see AppDelegate).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.isVisible, !self.isKeyWindow, NSApp.isActive else { return }
            if let k = NSApp.keyWindow, k.isVisible, k !== self {
                if k is GlassPanel || k.className.contains("QLPreviewPanel") { return }
                Log.app.debug("resignKey → \(k.className, privacy: .public) took key; hiding")
                self.onResignKey?()
                return
            }
            Log.app.debug("resignKey → reclaiming key")
            self.makeKey()
        }
    }

    override func cancelOperation(_ sender: Any?) { onResignKey?() }

    /// The search field edits in a non-vibrant field editor. Vibrant text views composite their selection
    /// highlight through the blur (plus-lighter), which turns the system accent into a garish cyan block.
    private lazy var plainFieldEditor: NSTextView = {
        let tv = PlainFieldEditor(frame: .zero)
        tv.isFieldEditor = true
        // Spotlight's selection on its dark glass measures #6885ad with white text (accent hue, 40 % saturation,
        // 68 % brightness); AppKit's plain dark selection (#3f638b) reads too heavy here, the vibrant one too pale.
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        let sel = NSColor(hue: accent.hueComponent, saturation: 0.40, brightness: 0.68, alpha: 1)
        tv.selectedTextAttributes = [.backgroundColor: sel, .foregroundColor: NSColor.white]
        tv.insertionPointColor = .labelColor
        return tv
    }()

    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        object is NSTextField || object is NSTextFieldCell ? plainFieldEditor : super.fieldEditor(createFlag, for: object)
    }
}

private final class PlainFieldEditor: NSTextView {
    override var allowsVibrancy: Bool { false }
}

/// Quick Look for the panels (Space/⌘Y).
final class PanelQuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = PanelQuickLook()
    var items: [URL] = []

    func toggle(urls: [URL]) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.orderOut(nil); return }
        items = urls
        guard !items.isEmpty else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        if QLPreviewPanel.sharedPreviewPanelExists(), let p = QLPreviewPanel.shared(), p.isVisible { p.orderOut(nil) }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { items[index] as NSURL }
}
