import AppKit
import SwiftUI

/// A borderless panel that takes keystrokes without activating Armada, so the app you were in stays frontmost
/// and ⏎ can paste straight into it.
final class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Opens with the clipboard hotkey (⌘⇧V by default): search field, history on the left, preview on the right.
@MainActor
final class ClipboardWindowController: ObservableObject {
    static let shared = ClipboardWindowController()

    @Published var query = "" { didSet { selectFirst() } }
    @Published var selectedID: UUID?

    private let history = ClipboardHistory.shared
    private var panel: ClipboardPanel?
    private var keyMonitor: Any?

    static let size = NSSize(width: 780, height: 480)

    var filtered: [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = history.items.filter { q.isEmpty || $0.searchText.lowercased().contains(q) }
        return all.filter(\.pinned) + all.filter { !$0.pinned }
    }

    var selected: ClipItem? { filtered.first { $0.id == selectedID } ?? filtered.first }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        let p = panel ?? makePanel()
        panel = p
        query = ""
        selectFirst()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.visibleFrame
        p.setFrameOrigin(NSPoint(x: f.midX - Self.size.width / 2, y: f.maxY - f.height * 0.18 - Self.size.height))
        p.makeKeyAndOrderFront(nil)
        if let field = p.contentView?.firstSubview(of: NSTextField.self) { p.makeFirstResponder(field) }
        installKeyMonitor()
    }

    func hide() {
        panel?.orderOut(nil)
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    func paste(_ item: ClipItem?) {
        guard let item else { return }
        history.copy(item)
        hide()
        if Settings.shared.clipboardPasteDirectly {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { ClipboardHistory.pasteIntoFrontApp() }
        }
    }

    func copyOnly(_ item: ClipItem?) {
        guard let item else { return }
        history.copy(item)
        hide()
    }

    private func selectFirst() { selectedID = filtered.first?.id }

    private func move(_ delta: Int) {
        let list = filtered
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.id == selected?.id } ?? 0
        selectedID = list[max(0, min(list.count - 1, i + delta))].id
    }

    private func makePanel() -> ClipboardPanel {
        let p = ClipboardPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                               styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isReleasedWhenClosed = false
        p.appearance = NSAppearance(named: .darkAqua)

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        let host = NSHostingView(rootView: ClipboardView(controller: self))
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        p.contentView = effect

        // Clicking anywhere else dismisses it, like Spotlight and Raycast.
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        return p
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let p = self.panel, e.window === p else { return e }
            return self.handle(e) ? nil : e
        }
    }

    /// Returns true when the key was ours.
    private func handle(_ e: NSEvent) -> Bool {
        let cmd = e.modifierFlags.contains(.command)
        switch e.keyCode {
        case 125: move(1); return true                                // ↓
        case 126: move(-1); return true                               // ↑
        case 36, 76: cmd ? copyOnly(selected) : paste(selected); return true   // ⏎ / ⌘⏎
        case 53: if query.isEmpty { hide() } else { query = "" }; return true  // ⎋
        case 51 where cmd:                                            // ⌘⌫
            if let s = selected {
                let list = filtered, i = list.firstIndex { $0.id == s.id } ?? 0
                history.delete(s)
                let rest = filtered
                selectedID = rest.isEmpty ? nil : rest[min(i, rest.count - 1)].id
            }
            return true
        case 35 where cmd: if let s = selected { history.togglePin(s) }; return true   // ⌘P
        default: break
        }
        if cmd, let c = e.charactersIgnoringModifiers, let n = Int(c), (1...9).contains(n) {   // ⌘1–⌘9
            let list = filtered
            if n <= list.count { paste(list[n - 1]) }
            return true
        }
        return false
    }
}

struct ClipboardView: View {
    @ObservedObject var controller: ClipboardWindowController
    @ObservedObject private var history = ClipboardHistory.shared

    var body: some View {
        let list = controller.filtered
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.on.clipboard").font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary)
                TextField("Search clipboard history", text: $controller.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22))
            }
            .padding(.horizontal, 20)
            .frame(height: 60)
            Divider()
            if list.isEmpty {
                empty
            } else {
                HStack(spacing: 0) {
                    listView(list).frame(width: 320)
                    Divider()
                    ClipPreview(item: controller.selected).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack(spacing: 18) {
                hint("⏎", Settings.shared.clipboardPasteDirectly ? "Paste" : "Copy")
                hint("⌘⏎", "Copy")
                hint("⌘P", controller.selected?.pinned == true ? "Unpin" : "Pin")
                hint("⌘⌫", "Delete")
                Spacer()
                Text("\(history.items.count) items").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: 34)
        }
        .frame(width: ClipboardWindowController.size.width, height: ClipboardWindowController.size.height)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard").font(.system(size: 40)).foregroundStyle(.tertiary)
            Text(controller.query.isEmpty ? "Copy something and it shows up here" : "No matches")
                .font(.system(size: 16)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func listView(_ list: [ClipItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                        if i == 0, item.pinned { header("Pinned") }
                        if !item.pinned, i == 0 || list[i - 1].pinned { header("Recent") }
                        ClipRow(item: item, index: i, selected: item.id == controller.selected?.id)
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { controller.paste(item) }
                            .onTapGesture { controller.selectedID = item.id }
                    }
                }
                .padding(8)
            }
            .onChange(of: controller.selectedID) { _, id in if let id { proxy.scrollTo(id) } }
        }
    }

    private func header(_ s: String) -> some View {
        Text(s).font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(.system(size: 11, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.1)))
            Text(label).font(.system(size: 12))
        }
        .foregroundStyle(.secondary)
    }
}

private struct ClipRow: View {
    let item: ClipItem
    let index: Int
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ClipIcon(item: item).frame(width: 22, height: 22)
            Text(item.title).font(.system(size: 14)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if item.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(.secondary) }
            if index < 9 { Text("⌘\(index + 1)").font(.system(size: 11)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.55) : .clear))
    }
}

private struct ClipIcon: View {
    let item: ClipItem

    var body: some View {
        switch item.kind {
        case .image:
            if let img = ClipboardHistory.shared.image(for: item) {
                Image(nsImage: img).resizable().scaledToFill().clipShape(RoundedRectangle(cornerRadius: 4))
            } else { symbol("photo") }
        case .files:
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.paths?.first ?? "/")).resizable()
        case .link: symbol("link")
        case .text: symbol("text.alignleft")
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 22, height: 22)
    }
}

private struct ClipPreview: View {
    let item: ClipItem?

    private static let ago: RelativeDateTimeFormatter = { let f = RelativeDateTimeFormatter(); f.unitsStyle = .full; return f }()

    var body: some View {
        if let item {
            VStack(alignment: .leading, spacing: 0) {
                content(item).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    meta("From", item.app ?? "Unknown app")
                    meta("Copied", Self.ago.localizedString(for: item.date, relativeTo: Date()))
                    if let t = item.text { meta("Size", "\(t.count) characters") }
                }
                .padding(14)
            }
        }
    }

    @ViewBuilder
    private func content(_ item: ClipItem) -> some View {
        switch item.kind {
        case .text, .link:
            ScrollView(.vertical) {
                Text(String((item.text ?? "").prefix(20_000)))
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .id(item.id)
        case .image:
            if let img = ClipboardHistory.shared.image(for: item) {
                Image(nsImage: img).resizable().scaledToFit().padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .files:
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(item.paths ?? [], id: \.self) { p in
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: p)).resizable().frame(width: 32, height: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                Text((p as NSString).lastPathComponent).font(.system(size: 14))
                                Text(FileSystem.displayPath((p as NSString).deletingLastPathComponent)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private func meta(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(.tertiary)
            Spacer()
            Text(v).foregroundStyle(.secondary).lineLimit(1)
        }
        .font(.system(size: 12))
    }
}
