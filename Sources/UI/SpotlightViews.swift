import SwiftUI
import AppKit

/// Layout constants matching macOS 26 Spotlight.
enum SpotlightMetrics {
    static let width: CGFloat = Liquid.width            // 640
    static let searchRowHeight: CGFloat = Liquid.pill   // 56
    static let chipsRowHeight: CGFloat = 46
    static let rowHeight: CGFloat = 56
    static let maxHeight: CGFloat = 469                 // Spotlight's tallest panel (6½ rows show; the list scrolls)
    static let cornerRadius: CGFloat = Liquid.radius
    static let padding: CGFloat = 10
}

/// The big Spotlight-style text field: 24pt, no chrome, and the launcher keys (↑ ↓ ⏎ ⌘⏎ ⎋ ⌘Y ⌘C) handled here.
struct SpotlightTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat = 24
    var onMove: (Int) -> Void
    var onOpen: () -> Void
    var onReveal: () -> Void
    var onEscape: () -> Void
    var onQuickLook: () -> Void
    var onCopy: () -> Void
    var onOpenIndex: (Int) -> Void = { _ in }

    final class Field: NSTextField {
        // Not vibrant: vibrant text composites plus-lighter through the blur, which bleaches the selection highlight.
        override var allowsVibrancy: Bool { false }
        var onMove: ((Int) -> Void)?
        var onOpen: (() -> Void)?
        var onReveal: (() -> Void)?
        var onEscape: (() -> Void)?
        var onQuickLook: (() -> Void)?
        var onCopy: (() -> Void)?
        var onOpenIndex: ((Int) -> Void)?

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let cmd = event.modifierFlags.contains(.command)
            switch (event.keyCode, cmd) {
            case (36, true): onReveal?(); return true          // ⌘⏎ reveal in Finder
            case (16, true): onQuickLook?(); return true       // ⌘Y quick look
            case (12, true), (13, true): onEscape?(); return true   // ⌘Q / ⌘W close the panel — never reach the app behind it
            case (18...25, true), (29, true):                             // ⌘1…⌘9 open the nth result, like Spotlight
                let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
                if let n = digits[event.keyCode] { onOpenIndex?(n - 1); return true }
                return super.performKeyEquivalent(with: event)
            case (43, true): AppDelegate.shared.openSettings(); return true   // ⌘,
            case (8, true) where currentEditor()?.selectedRange.length == 0: onCopy?(); return true   // ⌘C with no text selection copies the file
            default: return super.performKeyEquivalent(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> Field {
        let f = Field()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: fontSize, weight: .regular)
        f.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor])
        f.delegate = context.coordinator
        f.cell?.wraps = false
        f.cell?.isScrollable = true
        f.lineBreakMode = .byTruncatingTail
        f.onMove = onMove; f.onOpen = onOpen; f.onReveal = onReveal; f.onEscape = onEscape; f.onQuickLook = onQuickLook; f.onCopy = onCopy; f.onOpenIndex = onOpenIndex
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return f
    }

    func updateNSView(_ f: Field, context: Context) {
        // Only push text into the field for programmatic changes (URL search, ⎋ clear). While the user is typing,
        // SwiftUI may re-render with a value one keystroke behind; writing that back would eat the keystroke.
        if f.stringValue != text, text != context.coordinator.lastTyped {
            f.stringValue = text
            context.coordinator.lastTyped = text
        }
        f.onMove = onMove; f.onOpen = onOpen; f.onReveal = onReveal; f.onEscape = onEscape; f.onQuickLook = onQuickLook; f.onCopy = onCopy; f.onOpenIndex = onOpenIndex
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SpotlightTextField
        var lastTyped = ""
        init(_ p: SpotlightTextField) { parent = p }

        func controlTextDidChange(_ n: Notification) {
            if let f = n.object as? NSTextField { lastTyped = f.stringValue; parent.text = f.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1); return true
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1); return true
            case #selector(NSResponder.insertNewline(_:)): parent.onOpen(); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onEscape(); return true
            case #selector(NSResponder.scrollPageDown(_:)): parent.onMove(5); return true
            case #selector(NSResponder.scrollPageUp(_:)): parent.onMove(-5); return true
            default: return false
            }
        }
    }
}

/// Tracks whether the pointer moved in the last few hundred milliseconds (hover-to-select needs a real mouse move).
final class MouseActivity {
    static let shared = MouseActivity()
    private var lastMove = Date.distantPast
    private var monitor: Any?
    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] e in self?.lastMove = Date(); return e }
    }
    var movedRecently: Bool { Date().timeIntervalSince(lastMove) < 0.4 }
}

/// The magnifying glass doubles as the progress indicator: it starts empty and fills left→right as Jev walks the
/// folders, ending fully drawn when the ranked results are in.
struct ProgressGlyph: View {
    let progress: Double
    private let size: CGFloat = 26

    var body: some View {
        ZStack(alignment: .leading) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.10))
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
                .mask(alignment: .leading) {
                    // Only the fill animates. Animating the whole glyph also animated its *position*, so it
                    // visibly bobbed whenever the panel resized while a search was running.
                    Rectangle().frame(width: size * max(0, min(1, progress)))
                        .animation(.easeOut(duration: 0.28), value: progress)
                }
        }
        .frame(width: size, height: size, alignment: .leading)
        .accessibilityLabel(progress < 1 ? "Searching, \(Int(progress * 100)) percent" : "Search")
    }
}

/// One Spotlight-style result row: icon · title / subtitle · match %.
struct ResultRowView: View {
    let result: SearchResult
    let selected: Bool
    let compact: Bool

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if result.sources.contains(.setting) {
                    Image(nsImage: IconCache.icon(forPath: "/System/Applications/System Settings.app", isDirectory: false, isPackage: true, ext: "app")).resizable().interpolation(.high)
                } else if result.sources.contains(.action) {
                    Image(systemName: result.entry.kind).font(.system(size: compact ? 18 : 22)).foregroundStyle(Color.accentColor)
                        .frame(width: compact ? 28 : 36, height: compact ? 28 : 36)
                } else if result.sources.contains(.site) {
                    if let fav = WebIndex.shared.favicon(for: result.entry.name) ?? WebIndex.shared.favicon(for: result.entry.kind) {
                        Image(nsImage: fav).resizable().interpolation(.high).frame(width: compact ? 22 : 26, height: compact ? 22 : 26)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    } else {
                        Image(systemName: "globe").font(.system(size: compact ? 18 : 22)).foregroundStyle(.secondary)
                    }
                } else if result.sources.contains(.web) {
                    Image(systemName: "globe").font(.system(size: compact ? 18 : 22)).foregroundStyle(.secondary)
                        .frame(width: compact ? 28 : 36, height: compact ? 28 : 36)
                } else {
                    Image(nsImage: FileSystem.icon(for: result.entry)).resizable().interpolation(.high)
                }
            }
            .frame(width: compact ? 28 : 36, height: compact ? 28 : 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.sources.contains(.app) ? result.entry.url.deletingPathExtension().lastPathComponent : result.entry.name)
                    .font(.system(size: compact ? 13 : 17, weight: .regular))
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(SearchController.subtitle(for: result))
                    if result.entry.url.isFileURL, !result.sources.contains(.app) {
                        Text("·")
                        Image(systemName: "folder").font(.system(size: 10))
                        Text(SearchController.parentLabel(for: result))
                    }
                }
                .font(.system(size: compact ? 11 : 13))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 8)
        .frame(height: compact ? 44 : SpotlightMetrics.rowHeight)
        .background(selected ? Color.white.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// Spotlight's row of filter chips.
struct ChipsRow: View {
    @ObservedObject var controller: SearchController
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(controller.availableCategories) { cat in
                    let on = controller.filter == cat
                    Button(cat.rawValue) { controller.filter = on ? nil : cat; controller.selectedIndex = 0 }
                        .buttonStyle(.plain)
                        .font(.system(size: 15, weight: .regular))
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(on ? Color.accentColor.opacity(0.4) : Color.white.opacity(0.06), in: Capsule())
                }
            }
            .padding(.horizontal, 18)
        }
        .frame(height: SpotlightMetrics.chipsRowHeight)
    }
}

/// The full ⌘Space panel content.
struct SpotlightPanelView: View {
    @ObservedObject var controller: SearchController
    @ObservedObject var liquid: LiquidState
    @ObservedObject var reach = Reachability.shared
    var onEscape: () -> Void
    var onQuickLook: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
            HStack(spacing: 14) {
                ProgressGlyph(progress: controller.progress)
                SpotlightTextField(text: $controller.query, placeholder: "Search",
                                   onMove: { controller.moveSelection($0) },
                                   onOpen: { if controller.calcResult != nil, controller.results.isEmpty { controller.copyCalcResult() } else { controller.openSelected() } },
                                   onReveal: { controller.revealSelected() },
                                   onEscape: { if controller.query.isEmpty { onEscape() } else { controller.query = "" } },
                                   onQuickLook: onQuickLook,
                                   onCopy: { controller.copySelected() },
                                   onOpenIndex: { controller.open($0) })
                .overlay(alignment: .leading) {
                    if let c = controller.completion {
                        // Inline completion exactly as Spotlight draws it (measured on macOS 26): the rest of the name
                        // in full-strength text, then "— Open" dimmed, both on a 12 %-white capsule.
                        HStack(spacing: 0) {
                            Text(controller.query).font(.system(size: 24)).hidden()
                            HStack(spacing: 0) {
                                Text(c.remainder).font(.system(size: 24)).foregroundStyle(.primary)
                                Text("  —  \(c.action)").font(.system(size: 17)).foregroundStyle(.primary.opacity(0.38)).baselineOffset(1)
                            }
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .padding(.leading, -7)
                        }
                        .lineLimit(1)
                        .allowsHitTesting(false)
                    }
                }
                if let top = controller.results.first, top.entry.url.isFileURL, !controller.isBusy {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: top.entry.path)).resizable().frame(width: 32, height: 32)
                }
            }
            .padding(.leading, 18).padding(.trailing, 16)
            .frame(width: SpotlightMetrics.width, height: SpotlightMetrics.searchRowHeight, alignment: .leading)
            }
            .frame(width: SpotlightMetrics.width, height: SpotlightMetrics.searchRowHeight, alignment: .topLeading)

            if !controller.query.isEmpty {
                Divider().padding(.horizontal, 14).opacity(liquid.contentAlpha)
                if !controller.availableCategories.isEmpty { ChipsRow(controller: controller).opacity(liquid.contentAlpha) }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if let c = controller.calcResult {
                                HStack(spacing: 12) {
                                    Image(systemName: "equal.square.fill").font(.system(size: 30)).foregroundStyle(Color.accentColor)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(c).font(.system(size: 22, weight: .medium, design: .rounded))
                                        Text("Calculator · ⏎ copies the result").font(.system(size: 12)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 12).frame(height: SpotlightMetrics.rowHeight + 8)
                                .background(controller.results.isEmpty ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .contentShape(Rectangle())
                                .onTapGesture { controller.copyCalcResult() }
                            }
                            ForEach(Array(controller.results.enumerated()), id: \.element.id) { i, r in
                                ResultRowView(result: r, selected: i == controller.selectedIndex, compact: false)
                                    .id(r.id)
                                    // Hovering moves the highlight, like Spotlight — but only for real mouse movement, so
                                    // results streaming in under a resting pointer don't yank the keyboard selection.
                                    .onHover { inside in if inside, MouseActivity.shared.movedRecently { controller.selectedIndex = i } }
                                    .onTapGesture(count: 2) { controller.selectedIndex = i; controller.openSelected() }
                                    .onTapGesture(count: 1) { controller.selectedIndex = i }
                                    .contextMenu {
                                        Button("Open") { controller.selectedIndex = i; controller.openSelected() }
                                        Button("Show in Finder") { controller.selectedIndex = i; controller.revealSelected() }
                                        Button("Quick Look") { controller.selectedIndex = i; onQuickLook() }
                                        Button("Copy") { controller.selectedIndex = i; controller.copySelected() }
                                    }
                            }
                            if controller.results.isEmpty, controller.calcResult == nil {
                                HStack {
                                    Spacer()
                                    Text(controller.isBusy ? "Asking Jev…" : "No results").foregroundStyle(.secondary).font(.system(size: 13))
                                    Spacer()
                                }
                                .frame(height: SpotlightMetrics.rowHeight)
                            }
                        }
                        .padding(.horizontal, SpotlightMetrics.padding)
                        .padding(.vertical, 6)
                    }
                    .onChange(of: controller.selectedIndex) { _, i in
                        if let r = controller.results.indices.contains(i) ? controller.results[i] : nil { proxy.scrollTo(r.id, anchor: nil) }
                    }
                    .onChange(of: controller.results.first?.id) { _, _ in
                        if controller.selectedIndex == 0, let r = controller.results.first { proxy.scrollTo(r.id, anchor: .top) }
                    }
                }
                .opacity(liquid.contentAlpha)
                if !reach.isOnline || { if case .failed = controller.phase { return true }; return false }() {
                    // Only shown when something is actually wrong; the footer is otherwise empty.
                    HStack(spacing: 6) {
                        Image(systemName: "wifi.slash").foregroundStyle(.orange)
                        Text(controller.statusLine ?? "Codiv unreachable — name matches only").lineLimit(1)
                        Spacer()
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 24)
                }
            }
        }
        // Laid out at the panel's *target* height, pinned to the top: the window animates around this content and the
        // liquid mask clips it, so nothing reflows mid-animation.
        .frame(width: SpotlightMetrics.width, height: liquid.contentHeight, alignment: .top)
        .clipped()
    }
}
