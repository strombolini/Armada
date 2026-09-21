import AppKit
import SwiftUI
import ApplicationServices

/// Armada inside the real Finder and inside apps' Open panels — using their own UI. When the user types a query into
/// the search field and presses ⏎, the same engine runs *scoped to the folder that window shows*; its answers are
/// laid out, in rank order, as a folder of links that the window is then pointed at, so Finder's (or the panel's)
/// ordinary list/icon view, Quick Look, drag & drop and "Show Original" all just work. Until ⏎ — and whenever Codiv is
/// unreachable, Accessibility isn't granted, or the folder can't be determined — the standard search is what shows.
@MainActor
final class FinderSearchBridge {
    static let shared = FinderSearchBridge()

    private var appObserver: AXObserver?
    private var observedPID: pid_t = 0
    private var field: AXUIElement?
    private var folder: URL?
    private var folderByWindow: [AXUIElement: URL] = [:]   // last real folder each Finder window showed (search mode hides it)
    private var isFinder = false
    private var isOpenPanel = false
    private var tap: CFMachPort?
    private var running: Task<Void, Never>?
    private let engine = SemanticSearch()

    private init() {}

    nonisolated static var isTrusted: Bool { AXIsProcessTrusted() }
    nonisolated static func requestTrust() { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) }

    /// Call once at launch and whenever the setting / permission changes.
    func start() {
        guard Settings.shared.finderIntegration, FinderSearchBridge.isTrusted else { stop(); return }
        // Finder's *standard* search should be scoped to the folder too, so the fallback matches what Armada does:
        // Finder › Settings › Advanced › "When performing a search" = Search the Current Folder.
        let fd = UserDefaults(suiteName: "com.apple.finder")
        if fd?.string(forKey: "FXDefaultSearchScope") != "SCcf" { fd?.set("SCcf", forKey: "FXDefaultSearchScope"); Log.app.info("finder search scope → current folder") }
        guard tap == nil else { return }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        if let app = NSWorkspace.shared.frontmostApplication { attach(to: app) }
        installTap()
        Log.app.info("finder bridge started")
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        detachApp()
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); tap = nil }
    }

    // MARK: which app / which field

    @objc private func appActivated(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        attach(to: app)
    }

    private func attach(to app: NSRunningApplication) {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        detachApp()
        observedPID = app.processIdentifier
        isFinder = app.bundleIdentifier == "com.apple.finder"
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<FinderSearchBridge>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in me.focusChanged() }
        }
        guard AXObserverCreate(observedPID, cb, &obs) == .success, let obs else { return }
        let appEl = AXUIElementCreateApplication(observedPID)
        AXObserverAddNotification(obs, appEl, kAXFocusedUIElementChangedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        appObserver = obs
        focusChanged()
    }

    private func detachApp() {
        if let o = appObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .commonModes) }
        appObserver = nil
        field = nil; folder = nil
    }

    /// The focused element changed: is it the search field of a Finder window or of an Open panel?
    private func focusChanged() {
        guard observedPID > 0 else { return }
        let appEl = AXUIElementCreateApplication(observedPID)
        guard let focused = AX.element(appEl, kAXFocusedUIElementAttribute),
              AX.string(focused, kAXRoleAttribute) == kAXTextFieldRole, AX.string(focused, kAXSubroleAttribute) == "AXSearchField",
              let window = AX.element(focused, kAXWindowAttribute) else { field = nil; folder = nil; return }
        if let f = field, CFEqual(f, focused) { return }
        if isFinder {
            // Finder doesn't expose the folder as AXDocument; ask it (Apple Events). Once the window is in search mode
            // ("Searching …") it has no target any more, so remember what each window showed before the search began.
            if let f = FinderSearchBridge.finderFrontFolder() { folder = f; folderByWindow[window] = f }
            else { folder = folderByWindow[window] ?? scopeFolder(fromSearchWindow: window) }
            isOpenPanel = false
        } else {
            // An Open panel (a Save panel has a "Save As" name field: leave those alone — nobody saves into a results folder).
            let role = AX.string(window, kAXRoleAttribute)
            guard role == kAXSheetRole || role == kAXWindowRole && AX.string(window, kAXSubroleAttribute) == kAXDialogSubrole,
                  !AX.hasSaveAsField(window) else { field = nil; folder = nil; return }
            folder = AX.firstFileURL(in: window, depth: 0)?.deletingLastPathComponent()
            isOpenPanel = true
        }
        field = focused
        Log.app.info("finder bridge: search field focused, scope=\(self.folder?.path ?? "none", privacy: .public)")
    }

    /// A window already in search mode shows its scope as a button titled with the folder's name in quotes
    /// (Search: This Mac | “Downloads”). Map that name back to a folder.
    private func scopeFolder(fromSearchWindow window: AXUIElement) -> URL? {
        guard let title = AX.findButtonTitle(in: window, where: { $0.hasPrefix("“") || $0.hasPrefix("\"") }) else { return nil }
        let name = title.trimmingCharacters(in: CharacterSet(charactersIn: "“”\""))
        if let known = folderByWindow.values.first(where: { $0.lastPathComponent == name }) { return known }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for cand in [home.appendingPathComponent(name), home.appendingPathComponent("Desktop/\(name)"), home.appendingPathComponent("Documents/\(name)")]
            where (try? cand.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return cand }
        if name == home.lastPathComponent { return home }
        if let hit = Spotlight.mdfind(["-onlyin", home.path, "kMDItemFSName == '\(name)' && kMDItemContentType == 'public.folder'"], timeout: 2).first { return URL(fileURLWithPath: hit) }
        return nil
    }

    nonisolated static func finderFrontFolder() -> URL? {
        var err: NSDictionary?
        let r = NSAppleScript(source: "tell application \"Finder\" to POSIX path of (target of front Finder window as alias)")?.executeAndReturnError(&err)
        guard let path = r?.stringValue, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: ⏎ in the search field

    private func installTap() {
        guard tap == nil else { return }
        let cb: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon, type == .keyDown else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<FinderSearchBridge>.fromOpaque(refcon).takeUnretainedValue()
            me.handleKey(event)
            return Unmanaged.passUnretained(event)     // never swallowed: Finder / the panel behave exactly as before
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                        eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue), callback: cb,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
    }

    private nonisolated func handleKey(_ e: CGEvent) {
        let code = e.getIntegerValueField(.keyboardEventKeycode)
        guard code == 36 || code == 76, e.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty else { return }
        Task { @MainActor in self.enterPressed() }
    }

    private func enterPressed() {
        guard let field else { return }
        // Re-resolve the folder: the window may have left search mode and moved elsewhere since the field got focus.
        if isFinder, let f = FinderSearchBridge.finderFrontFolder(), let w = AX.element(field, kAXWindowAttribute) { folder = f; folderByWindow[w] = f }
        let query = (AX.string(field, kAXValueAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if folder == nil, isFinder, let w = AX.element(field, kAXWindowAttribute) { folder = scopeFolder(fromSearchWindow: w) }
        guard let folder else { Log.app.info("finder bridge: ⏎ but no folder known for this window"); return }
        guard query.count >= 2 else { return }
        Log.app.info("finder bridge: ⏎ '\(query, privacy: .public)' in \(folder.path, privacy: .public)")
        runScoped(query: query, folder: folder, openPanel: isOpenPanel, pid: observedPID)
    }

    /// The Finder-side search: Jev walk restricted to `folder`, then Finder's own window shows the ranked files.
    func runScoped(query: String, folder: URL, openPanel: Bool, pid: pid_t) {
        guard Reachability.shared.isOnline, !Settings.shared.apiKey.isEmpty else { return }
        running?.cancel()
        running = Task { [engine] in
            var opts = SemanticSearch.Options(); opts.roots = [folder.path]
            let results = await engine.search(query: query, options: opts) { _, _ in }
            guard !Task.isCancelled else { return }
            // "All the files Finder would show, but ranked": Jev's ranked answers first, then everything Finder's own
            // search (Spotlight, same folder) would list that Jev didn't rank, in Spotlight's order.
            var files = results.filter { $0.entry.url.isFileURL }.map(\.entry.url)
            var seen = Set(files.map(\.path))
            let standard = await Task.detached { Spotlight.mdfind(["-onlyin", folder.path, query]) }.value
            let q = query.lowercased()
            struct Rest { let url: URL; let tier: Int; let modified: Date }
            var rest: [Rest] = []
            for path in standard where seen.insert(path).inserted && !path.contains("/.") {
                let u = URL(fileURLWithPath: path)
                let name = u.lastPathComponent.lowercased()
                let tier = (name.contains(q) || u.pathExtension.lowercased() == q) ? 0 : 1      // name/kind hits before content hits
                let mod = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                rest.append(Rest(url: u, tier: tier, modified: mod))
            }
            rest.sort { a, b in a.tier != b.tier ? a.tier < b.tier : a.modified > b.modified }
            files += rest.map { $0.url }
            files = Array(files.prefix(300))
            guard !files.isEmpty else { Log.app.info("finder bridge: no results for '\(query, privacy: .public)', standard search stays"); return }
            guard let dir = ResultsFolder.build(query: query, scope: folder, files: files) else { return }
            // Only act if the same app is still in front — the user may have moved on while Codiv was thinking.
            guard pid == 0 || NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            if openPanel { ResultsFolder.show(inOpenPanel: dir) } else { ResultsFolder.show(inFinder: dir) }
        }
    }
}

/// A folder of links to the ranked results, so Finder's own window can display them in rank order (sorted by
/// the links' modification dates, which encode the rank).
enum ResultsFolder {
    static var base: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Armada/Results", isDirectory: true)
    }

    static func build(query: String, scope: URL, files: [URL]) -> URL? {
        let fm = FileManager.default
        let safe = query.replacingOccurrences(of: "/", with: "⁄").replacingOccurrences(of: ":", with: "∶").prefix(60)
        let dir = base.appendingPathComponent("\(safe) — in \(scope.lastPathComponent)", isDirectory: true)
        try? fm.removeItem(at: dir)
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return nil }
        var used: Set<String> = []
        for (i, f) in files.enumerated() {
            var name = f.lastPathComponent
            if !used.insert(name.lowercased()).inserted {
                name = f.deletingPathExtension().lastPathComponent + " (" + f.deletingLastPathComponent().lastPathComponent + ")" + (f.pathExtension.isEmpty ? "" : "." + f.pathExtension)
                _ = used.insert(name.lowercased())
            }
            let link = dir.appendingPathComponent(name)
            try? fm.createSymbolicLink(at: link, withDestinationURL: f)
            // The link's own modification time encodes the rank (best = newest), so Finder's default "Date Modified,
            // newest first" list order *is* the ranking — no custom UI needed.
            let when = Int(Date().timeIntervalSince1970) - i
            var times = [timeval(tv_sec: when, tv_usec: 0), timeval(tv_sec: when, tv_usec: 0)]
            _ = lutimes(link.path, &times)
        }
        return dir
    }

    /// Point the front Finder window at the folder, list view sorted by Date Created (= rank).
    @MainActor static func show(inFinder dir: URL) {
        let src = """
        tell application "Finder"
            if (count of Finder windows) > 0 then
                set w to front Finder window
                set target of w to (POSIX file "\(dir.path)") as alias
            else
                set w to make new Finder window to ((POSIX file "\(dir.path)") as alias)
            end if
            set current view of w to list view
            set opts to list view options of w
            set sort column of opts to column id modification date column of opts
            set sort direction of (column id modification date column of opts) to normal
            activate
        end tell
        """
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let err { Log.app.error("finder bridge: navigate failed \(err, privacy: .public)") }
    }

    /// Open panels have no scripting: use their own "Go to folder" (⌘⇧G, path, ⏎).
    @MainActor static func show(inOpenPanel dir: URL) {
        Keys.type(shortcut: 5, flags: [.maskCommand, .maskShift])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            Keys.type(text: dir.path)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Keys.type(shortcut: 36, flags: []) }
        }
    }
}

// MARK: - Accessibility helpers

enum AX {
    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }
    static func url(_ el: AXUIElement, _ attr: String) -> URL? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v else { return nil }
        if let u = v as? URL { return u }
        if let s = v as? String { return s.hasPrefix("file://") ? URL(string: s) : URL(fileURLWithPath: s) }
        return nil
    }
    static func frame(_ el: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p) == .success, let p,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s) == .success, let s else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt); AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }
    static func children(_ el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success, let arr = v as? [AXUIElement] else { return [] }
        return arr
    }
    static func findButtonTitle(in el: AXUIElement, where pred: (String) -> Bool, depth: Int = 0) -> String? {
        if depth > 8 { return nil }
        if string(el, kAXRoleAttribute) == kAXButtonRole || string(el, kAXRoleAttribute) == kAXRadioButtonRole,
           let t = string(el, kAXTitleAttribute) ?? string(el, kAXDescriptionAttribute), pred(t) { return t }
        for c in children(el).prefix(80) { if let t = findButtonTitle(in: c, where: pred, depth: depth + 1) { return t } }
        return nil
    }

    /// A Save panel has an editable name field ("Save As:"); Open panels don't.
    static func hasSaveAsField(_ window: AXUIElement) -> Bool {
        func walk(_ el: AXUIElement, _ depth: Int) -> Bool {
            if depth > 5 { return false }
            if string(el, kAXRoleAttribute) == kAXTextFieldRole, string(el, kAXSubroleAttribute) != "AXSearchField" { return true }
            for c in children(el).prefix(40) where walk(c, depth + 1) { return true }
            return false
        }
        return walk(window, 0)
    }

    /// Depth-limited search for any element carrying a file URL (rows in an Open panel's file list).
    static func firstFileURL(in el: AXUIElement, depth: Int) -> URL? {
        if depth > 7 { return nil }
        if let u = url(el, "AXURL"), u.isFileURL { return u }
        for c in children(el).prefix(60) { if let u = firstFileURL(in: c, depth: depth + 1) { return u } }
        return nil
    }
}

/// Synthetic keystrokes for driving an Open/Save panel's "Go to folder".
enum Keys {
    static func type(shortcut key: CGKeyCode, flags: CGEventFlags) {
        guard let d = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true), let u = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { return }
        d.flags = flags; u.flags = flags
        d.post(tap: .cghidEventTap); u.post(tap: .cghidEventTap)
    }
    static func type(text: String) {
        for ch in text.utf16 {
            guard let d = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true), let u = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { continue }
            var c = ch
            d.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c); u.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
            d.post(tap: .cghidEventTap); u.post(tap: .cghidEventTap)
        }
    }
}
