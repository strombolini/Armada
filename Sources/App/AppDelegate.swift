import AppKit
import SwiftUI
import ServiceManagement
import Combine
import Quartz

/// Owns the always-running agent: the global hotkey, the Spotlight-style panel, the Finder integration, the offline fallback.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!

    let controller = SearchController()
    private var panel: GlassPanel?
    private var choreo: PanelChoreographer?
    private var cancellables: Set<AnyCancellable> = []
    private var settingsWindow: NSWindow?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("launched; hotkey=\(Settings.shared.hotkey.rawValue, privacy: .public) key=\(Settings.shared.apiKey.isEmpty ? "missing" : "set", privacy: .public)")
        NSApp.setActivationPolicy(Settings.shared.showInDock ? .regular : .accessory)
        registerHotkeys()
        controller.onOpen = { [weak self] in self?.hidePanel() }
        Settings.shared.$hotkey.dropFirst().sink { [weak self] _ in self?.registerHotkeys() }.store(in: &cancellables)
        Settings.shared.$alsoOptionSpace.dropFirst().sink { [weak self] _ in self?.registerHotkeys() }.store(in: &cancellables)
        Settings.shared.$showInDock.dropFirst().sink { show in NSApp.setActivationPolicy(show ? .regular : .accessory) }.store(in: &cancellables)
        // Re-size the panel synchronously with every state change (see SearchController.onStateChange).
        controller.onStateChange = { [weak self] in self?.layoutPanel() }
        Reachability.shared.$apiReachable.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.layoutPanel() }.store(in: &cancellables)
        _ = Reachability.shared
        _ = MouseActivity.shared
        WebIndex.shared.refreshIfStale()   // warm the websites index before the first keystroke
        FinderSearchBridge.shared.start()  // Finder / Open-panel search fields (needs Accessibility; no-op without)
        if !FinderSearchBridge.isTrusted, UserDefaults.standard.object(forKey: "askedAccessibility") == nil {
            // One system prompt, once: it lists Armada under Privacy & Security › Accessibility so the user can turn it on.
            UserDefaults.standard.set(true, forKey: "askedAccessibility")
            FinderSearchBridge.requestTrust()
        }
        Settings.shared.$finderIntegration.dropFirst().sink { _ in FinderSearchBridge.shared.start() }.store(in: &cancellables)
        DispatchQueue.global(qos: .utility).async { _ = AppIndex.shared }   // warm the app launcher index
        let firstRun = UserDefaults.standard.object(forKey: "didOnboard") == nil
        if firstRun || Settings.shared.apiKey.isEmpty || !Permissions.hasFullDiskAccess {
            UserDefaults.standard.set(true, forKey: "didOnboard")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.openOnboarding() }
        }
        if UserDefaults.standard.object(forKey: "didOfferLoginItem") == nil {
            UserDefaults.standard.set(true, forKey: "didOfferLoginItem")
            setLaunchAtLogin(true)
        }
        // Without Full Disk Access, touch the user folders now so the per-folder prompts come together at launch
        // rather than in the middle of the first search (declining one only hides that folder from Jev).
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
            guard !Permissions.hasFullDiskAccess else { return }
            for r in Settings.shared.searchRoots {
                for name in ["Desktop", "Documents", "Downloads"] { _ = FileSystem.list(URL(fileURLWithPath: r + "/" + name)) }
                _ = FileSystem.list(URL(fileURLWithPath: r))
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }

    /// armada://show · armada://hide · armada://search?q=… · armada://settings
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            switch url.host {
            case "hide": hidePanel()
            case "settings": openSettings()
            case "setup":
                if url.query == "close" { onboardingWindow?.orderOut(nil); if !Settings.shared.showInDock { NSApp.setActivationPolicy(.accessory) } }
                else { openOnboarding() }
            case "finder-search":
                // Debug hook: what ⏎ in a Finder search field does, without the keyboard. armada://finder-search?q=…&root=…
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let q = items.first { $0.name == "q" }?.value ?? ""
                let root = (items.first { $0.name == "root" }?.value ?? NSHomeDirectory()) as NSString
                FinderSearchBridge.shared.runScoped(query: q, folder: URL(fileURLWithPath: root.expandingTildeInPath), openPanel: false, pid: 0)
            case "search":
                let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
                showPanel()
                controller.query = q
            default: showPanel()
            }
        }
    }

    // MARK: Hotkeys

    private func registerHotkeys() {
        HotKeyCenter.shared.unregisterAll()
        let s = Settings.shared
        let space: UInt32 = 49
        // ⌘ Space must open Armada alone. Spotlight's own shortcut would otherwise pop up on the same keystroke,
        // so it is switched off while Jev owns ⌘ Space and restored when the user picks another key for Jev.
        if s.hotkey == .cmdSpace, HotKeyCenter.spotlightOwnsCommandSpace() {
            if SpotlightShortcut.setEnabled(false) { UserDefaults.standard.set(true, forKey: "jevDisabledSpotlightShortcut"); Log.app.info("Spotlight ⌘Space shortcut turned off") }
        } else if s.hotkey != .cmdSpace, UserDefaults.standard.bool(forKey: "jevDisabledSpotlightShortcut"), !HotKeyCenter.spotlightOwnsCommandSpace() {
            SpotlightShortcut.setEnabled(true); UserDefaults.standard.set(false, forKey: "jevDisabledSpotlightShortcut"); Log.app.info("Spotlight ⌘Space shortcut restored")
        }
        HotKeyCenter.shared.register(keyCode: space, modifiers: HotKeyCenter.modifiers(for: s.hotkey)) { [weak self] in self?.hotkeyPressed() }
        if s.alsoOptionSpace, s.hotkey != .optSpace {
            HotKeyCenter.shared.register(keyCode: space, modifiers: HotKeyCenter.modifiers(for: .optSpace)) { [weak self] in self?.hotkeyPressed() }
        }
    }

    var spotlightConflict: Bool { Settings.shared.hotkey == .cmdSpace && HotKeyCenter.spotlightOwnsCommandSpace() }

    private func hotkeyPressed() {
        // ⌘ Space always means "Armada". Only with the network completely down (not a Codiv hiccup or a slow
        // ping) and the user having opted in does it fall back to the real Finder.
        if Settings.shared.offlineBehavior == .openFinder, !Reachability.shared.networkAvailable { openRealFinder(); return }
        if let p = panel, p.isVisible { hidePanel() } else { showPanel() }
    }

    // MARK: Panel

    private func makePanel() -> GlassPanel {
        let p = GlassPanel(width: SpotlightMetrics.width + 2 * Liquid.margin, cornerRadius: SpotlightMetrics.cornerRadius)
        let c = PanelChoreographer(panel: p)
        choreo = c
        p.setContent(SpotlightPanelView(controller: controller, liquid: c.state,
                                        onEscape: { [weak self] in self?.hidePanel() },
                                        onQuickLook: { [weak self] in
                                            guard let r = self?.controller.selected else { return }
                                            PanelQuickLook.shared.toggle(urls: [r.entry.url])
                                        }))
        p.onResignKey = { [weak self] in
            // Clicking elsewhere dismisses, like Spotlight — unless Quick Look just took the focus.
            if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { return }
            self?.hidePanel()
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { [weak self] _ in self?.choreo?.noteMoved() }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            // The user switched to another app: get out of the way (Quick Look stays if it is what took over).
            guard let self, let p = self.panel, p.isVisible else { return }
            if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { return }
            Log.app.debug("app resigned active → hide panel")
            self.hidePanel()
        }
        return p
    }

    func showPanel() {
        let p = panel ?? makePanel()
        panel = p
        guard let c = choreo else { return }
        controller.loadRecents()
        let wasHidden = !p.isVisible || !c.isVisible
        if wasHidden {
            // Where Spotlight would appear (its own remembered spot, else centred 12.7 % down), on the mouse's screen.
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
            c.open(on: screen, queryEmpty: controller.query.isEmpty, contentHeight: contentHeight())
        } else {
            layoutPanel()
        }
        // Activate so keystrokes reach us and menu shortcuts work; the panel reclaims key focus if a hidden helper
        // window grabs it (GlassPanel.resignKey) and is dismissed when the app itself loses focus (below).
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        p.makeKey()
        // Select the previous query so typing replaces it, exactly like Spotlight.
        if let field = p.contentView?.firstSubview(of: SpotlightTextField.Field.self) {
            p.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        Task { await Reachability.shared.refresh(force: false) }
    }

    func hidePanel() {
        Log.app.debug("hidePanel")
        PanelQuickLook.shared.hide()
        // Spotlight's exit: 85 ms fade with a 4 % zoom, then gone.
        choreo?.close { [weak self] in
            self?.panel?.orderOut(nil)
            if NSApp.isActive, !Settings.shared.showInDock { NSApp.hide(nil) }
        }
    }

    /// The panel's target height for the current state: Spotlight's capsule alone for an empty query, otherwise
    /// header + chips + rows, capped at Spotlight's tallest panel.
    private func contentHeight() -> CGFloat {
        var h = SpotlightMetrics.searchRowHeight
        guard !controller.query.isEmpty else { return h }
        let rows = controller.results.count + (controller.calcResult == nil ? 0 : 1)
        guard rows > 0 || controller.isBusy else { return h }
        h += 1
        if !controller.availableCategories.isEmpty { h += SpotlightMetrics.chipsRowHeight }
        h += CGFloat(max(rows, 1)) * SpotlightMetrics.rowHeight + 12 + (controller.calcResult == nil ? 0 : 8)
        let problem = !Reachability.shared.isOnline || { if case .failed = controller.phase { return true }; return false }()
        if problem { h += 24 }
        return min(h, SpotlightMetrics.maxHeight)
    }

    private func layoutPanel() {
        choreo?.update(queryEmpty: controller.query.isEmpty, contentHeight: contentHeight())
    }

    // MARK: Fallbacks & helpers

    /// "Revert to normal Finder": bring up the real Finder with a fresh window.
    func openRealFinder() {
        let src = """
        tell application "Finder"
            activate
            make new Finder window to (path to home folder)
        end tell
        """
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        if err != nil { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory())) }
    }

    func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 720), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Armada Settings"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: SettingsView())
            w.center()
            settingsWindow = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.app.error("launch at login: \(error.localizedDescription, privacy: .public)")
        }
    }

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func openKeyboardShortcutSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts")!)
    }

    func openFullDiskAccess() { openOnboarding() }

    private var onboardingWindow: NSWindow?
    func openOnboarding() {
        if onboardingWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Set up Armada"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: OnboardingView { [weak self] in self?.onboardingWindow?.orderOut(nil); if !Settings.shared.showInDock { NSApp.setActivationPolicy(.accessory) } })
            w.center()
            onboardingWindow = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        if UserDefaults.standard.bool(forKey: "jevDisabledSpotlightShortcut") {
            SpotlightShortcut.setEnabled(true)
            UserDefaults.standard.set(false, forKey: "jevDisabledSpotlightShortcut")
        }
    }
}

extension NSView {
    func firstSubview<T: NSView>(of type: T.Type) -> T? {
        for v in subviews {
            if let t = v as? T { return t }
            if let t = v.firstSubview(of: type) { return t }
        }
        return nil
    }
}
