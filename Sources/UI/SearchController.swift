import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

/// Result categories used for Spotlight-style filter chips.
enum ResultCategory: String, CaseIterable, Identifiable {
    case apps = "Applications", settings = "Settings", actions = "Actions", websites = "Websites", folders = "Folders", documents = "Documents", pdfs = "PDFs", images = "Images",
         videos = "Videos", audio = "Audio", code = "Code", spreadsheets = "Spreadsheets", presentations = "Presentations", archives = "Archives", other = "Other"
    var id: String { rawValue }

    static func of(_ r: SearchResult) -> ResultCategory {
        if r.sources.contains(.setting) { return .settings }
        if r.sources.contains(.site) { return .websites }
        if r.sources.contains(.action) || r.sources.contains(.web) { return .actions }
        return of(r.entry)
    }

    static func of(_ e: FSEntry) -> ResultCategory {
        if e.ext == "app" { return .apps }
        if e.isDirectory { return .folders }
        switch e.ext {
        case "pdf": return .pdfs
        case "jpg", "jpeg", "png", "heic", "gif", "webp", "svg", "avif", "tiff", "bmp", "raw", "dng", "psd", "aae": return .images
        case "mov", "mp4", "m4v", "mkv", "avi", "webm": return .videos
        case "mp3", "wav", "m4a", "aiff", "flac", "aac": return .audio
        case "xlsx", "xls", "csv", "numbers", "tsv": return .spreadsheets
        case "key", "pptx", "ppt": return .presentations
        case "zip", "tar", "gz", "xip", "dmg", "pkg", "7z", "rar": return .archives
        case "py", "sh", "js", "ts", "tsx", "jsx", "swift", "rb", "go", "rs", "c", "h", "cpp", "java", "kt", "json", "yaml", "yml", "toml", "html", "css", "sql": return .code
        case "txt", "md", "rtf", "docx", "doc", "pages", "tex", "epub": return .documents
        default: return .other
        }
    }
}

/// Drives one search UI (the ⌘Space panel or the Finder overlay): query → debounced Jev search → results + selection.
@MainActor
final class SearchController: ObservableObject {
    // Every property that changes the panel's height calls `onStateChange` from its didSet. That runs synchronously,
    // *before* SwiftUI's next render pass, so the window is already the right size when the new content is drawn —
    // otherwise the footer gets squeezed into the old 60-pt window for a frame or two.
    @Published var query = "" { didSet { onStateChange?() } }
    @Published private(set) var allResults: [SearchResult] = [] { didSet { onStateChange?() } }
    @Published private(set) var phase: SearchPhase = .idle
    @Published var selectedIndex = 0
    @Published var filter: ResultCategory? = nil { didSet { onStateChange?() } }
    @Published var scopeRoots: [String]? = nil          // nil = Settings.searchRoots ("This Mac")
    @Published private(set) var appHits: [SearchResult] = [] { didSet { onStateChange?() } }   // Spotlight-style app launcher matches (instant)
    @Published private(set) var systemHits: [SearchResult] = [] { didSet { onStateChange?() } }   // System Settings panes + actions (instant, local)
    @Published private(set) var siteHits: [SearchResult] = [] { didSet { onStateChange?() } }     // websites from browser history/bookmarks (instant, local)
    @Published private(set) var calcResult: String? = nil { didSet { onStateChange?() } }      // "2+2" → "4"
    @Published private(set) var recents: [SearchResult] = [] { didSet { onStateChange?() } }   // shown while the query is empty
    var onStateChange: (() -> Void)?

    var onOpen: (() -> Void)?                            // called after an item was opened (panel hides)

    private var debounce: AnyCancellable?
    private var task: Task<Void, Never>?
    private var lastRun = ""
    private let engine = SemanticSearch()

    private var localDebounce: AnyCancellable?

    init(debounceMs: Int = 420) {
        // Local channels (apps, settings, calculator) answer almost immediately; the Jev walk — the part that costs
        // tokens — waits for a real pause in typing so half-typed queries don't burn requests.
        localDebounce = $query.removeDuplicates()
            .debounce(for: .milliseconds(60), scheduler: DispatchQueue.main)
            .sink { [weak self] q in self?.runLocal(q) }
        debounce = $query.removeDuplicates()
            .debounce(for: .milliseconds(debounceMs), scheduler: DispatchQueue.main)
            .sink { [weak self] q in self?.run(q) }
        loadRecents()
    }

    func loadRecents() {
        recents = UsageStore.shared.recents(limit: 8).compactMap { id -> SearchResult? in
            if id.hasPrefix("/"), let e = FileSystem.entry(for: URL(fileURLWithPath: id)) {
                return SearchResult(entry: e, score: 0, prior: 0, sources: e.ext == "app" ? [.app, .recent] : [.recent])
            }
            if id.hasPrefix("http"), let u = URL(string: id), let host = WebIndex.host(of: u) {
                let title = WebIndex.shared.sites.first(where: { $0.host == host })?.title ?? ""
                return SearchResult(entry: SearchController.siteEntry(url: u, name: host, detail: title), score: 0, prior: 0, sources: [.site, .recent])
            }
            return nil
        }
    }

    /// Apps that Spotlight would open on ⏎ go first, then Jev's ranked files, then weaker app matches.
    var results: [SearchResult] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return recents }
        var list = SearchController.merge(apps: appHits, system: systemHits, sites: siteHits, files: allResults)
        if Settings.shared.webSearchRow, query.count >= 3, let w = SearchController.webRow(for: query) { list.append(w) }
        guard let f = filter else { return list }
        return list.filter { ResultCategory.of($0) == f }
    }

    /// Shared by the panel, the Finder overlay and the CLI so the tests measure exactly what the user sees.
    /// Order: things the user almost certainly means (exact/prefix app, settings pane, action) → Jev's ranked files →
    /// weaker launcher matches → web search.
    static func merge(apps: [SearchResult], system: [SearchResult] = [], sites: [SearchResult] = [], files: [SearchResult]) -> [SearchResult] {
        var list: [SearchResult] = []
        var seen: Set<String> = []
        func add(_ r: SearchResult) { if seen.insert(r.entry.id).inserted { list.append(r) } }
        let strongApps = apps.filter { $0.score >= 0.9 }
        let strongSystem = system.filter { $0.score >= 0.84 }
        let strongSites = sites.filter { $0.score >= 0.9 }     // "youtube" → youtube.com, like Spotlight's Websites
        // A strong app beats a strong settings pane unless the pane matched better (e.g. "bluetooth" has no app).
        for r in (strongApps + strongSystem + strongSites).sorted(by: { $0.score > $1.score }) { add(r) }
        for r in files { add(r) }
        for r in (apps + system + sites).sorted(by: { $0.score > $1.score }) { add(r) }
        return list
    }

    static func webRow(for q: String) -> SearchResult? {
        guard let url = SystemIndex.webSearchURL(q) else { return nil }
        let e = FSEntry(url: url, name: "Search the web for “\(q)”", isDirectory: false, isPackage: false, size: 0, modified: .distantPast, created: .distantPast, kind: "Web search")
        return SearchResult(entry: e, score: 0, prior: 0, sources: [.web])
    }

    static func siteEntry(url: URL, name: String, detail: String) -> FSEntry {
        FSEntry(url: url, name: name, isDirectory: false, isPackage: false, size: 0, modified: .distantPast, created: .distantPast, kind: detail)
    }

    static func siteHits(for q: String) -> [SearchResult] {
        guard Settings.shared.websiteRows else { return [] }
        WebIndex.shared.refreshIfStale()
        return WebIndex.shared.matches(q).map { h in
            SearchResult(entry: siteEntry(url: h.url, name: h.name, detail: h.detail), score: h.score, prior: h.score, sources: [.site])
        }
    }

    static func systemHits(for q: String) -> [SearchResult] {
        var out: [SearchResult] = []
        for (p, score) in SystemIndex.paneMatches(q) {
            let e = FSEntry(url: URL(string: "x-apple.systempreferences:" + p.id)!, name: p.name, isDirectory: false, isPackage: false, size: 0,
                            modified: .distantPast, created: .distantPast, kind: "System Settings")
            out.append(SearchResult(entry: e, score: score, prior: score, sources: [.setting]))
        }
        for (a, score) in SystemIndex.actionMatches(q) {
            let e = FSEntry(url: URL(string: "jev-action://" + a.name.replacingOccurrences(of: " ", with: "-").lowercased())!, name: a.name, isDirectory: false,
                            isPackage: false, size: 0, modified: .distantPast, created: .distantPast, kind: a.symbol)
            out.append(SearchResult(entry: e, score: score, prior: score, sources: [.action]))
        }
        return out.sorted { $0.score > $1.score }
    }

    static func appHits(for q: String) -> [SearchResult] {
        AppIndex.shared.matches(q).compactMap { app, score in
            guard let e = FileSystem.entry(for: URL(fileURLWithPath: app.path)) else { return nil }
            return SearchResult(entry: e, score: score, prior: score, sources: [.app])
        }
    }

    /// Categories present in the current results, in a stable order — the filter chips.
    var availableCategories: [ResultCategory] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        var present = Set(allResults.map { ResultCategory.of($0.entry) })
        if !appHits.isEmpty { present.insert(.apps) }
        for r in systemHits { present.insert(ResultCategory.of(r)) }
        if !siteHits.isEmpty { present.insert(.websites) }
        present.remove(.actions)   // the web row alone doesn't deserve a chip
        if systemHits.contains(where: { $0.sources.contains(.action) }) { present.insert(.actions) }
        return ResultCategory.allCases.filter { present.contains($0) }
    }

    /// Inline completion for the search field, like Spotlight's "claud|e — Open".
    var completion: (remainder: String, action: String)? {
        let q = query
        guard !q.isEmpty, filter == nil, let top = results.first else { return nil }
        guard !top.sources.contains(.web) else { return nil }
        let name = top.sources.contains(.app) ? top.entry.url.deletingPathExtension().lastPathComponent : top.entry.name
        guard name.lowercased().hasPrefix(q.lowercased()), name.count > q.count else { return nil }
        return (String(name.dropFirst(q.count)), "Open")
    }

    var selected: SearchResult? {
        let r = results
        guard !r.isEmpty else { return nil }
        return r[min(max(0, selectedIndex), r.count - 1)]
    }

    /// 0…1 while Jev is working — drives the search icon's left-to-right fill. Full when idle or done.
    var progress: Double {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return 1 }
        switch phase {
        case .idle: return lastRun.isEmpty ? 1 : 0.05        // typed, walk not started yet
        case .names: return 0.18
        case .routing(let done):
            let budget = Double(max(Settings.shared.thoroughness.budget.maxRequests, 1))
            return 0.25 + 0.55 * min(1, Double(done) / budget)
        case .reranking: return 0.88
        case .done, .offline, .failed: return 1
        }
    }

    var isBusy: Bool {
        switch phase { case .names, .routing, .reranking: return true; default: return false }
    }

    var statusLine: String? {
        switch phase {
        case .idle: return nil
        case .names: return "Name matches · asking Jev…"
        case .routing(let n): return "Jev is walking your folders… \(n)"
        case .reranking: return "Ranking…"
        case .done(let r, let t, let ms): return r == 0 ? "cached" : "\(r) Jev calls · \(t) tokens · \(String(format: "%.1f", Double(ms) / 1000))s"
        case .offline: return "Offline — name matches only"
        case .failed(let m): return m
        }
    }

    /// Instant, local channels: apps, settings panes, actions, arithmetic. These never wait for Jev.
    func runLocal(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { allResults = []; appHits = []; systemHits = []; siteHits = []; calcResult = nil; phase = .idle; lastRun = ""; selectedIndex = 0; task?.cancel(); loadRecents(); return }
        calcResult = Calculator.evaluate(q)
        appHits = SearchController.appHits(for: q)
        systemHits = SearchController.systemHits(for: q)
        siteHits = SearchController.siteHits(for: q)
        selectedIndex = 0
    }

    func run(_ text: String, force: Bool = false) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        task?.cancel()
        guard !q.isEmpty else { return }
        if !force, q == lastRun { return }
        lastRun = q
        if q.count < 2 { allResults = []; phase = .idle; return }   // one letter: launcher matches only
        var opts = SemanticSearch.Options()
        if let roots = scopeRoots { opts.roots = roots }
        let engine = self.engine
        task = Task { [weak self] in
            _ = await engine.search(query: q, options: opts) { [weak self] partial, phase in
                guard let self, !Task.isCancelled, self.lastRun == q else { return }
                let keepPath = self.selected?.entry.path
                self.allResults = partial
                self.phase = phase
                // Keep the user's selection stable while results stream in; default to the top hit.
                if let keepPath, self.selectedIndex > 0, let i = self.results.firstIndex(where: { $0.entry.path == keepPath }) { self.selectedIndex = i }
                else if self.selectedIndex >= self.results.count { self.selectedIndex = 0 }
            }
        }
    }

    func cancel() { task?.cancel() }

    func moveSelection(_ delta: Int) {
        let n = results.count
        guard n > 0 else { return }
        selectedIndex = min(max(0, selectedIndex + delta), n - 1)
    }

    func open(_ index: Int) {
        guard results.indices.contains(index) else { return }
        selectedIndex = index
        openSelected()
    }

    func openSelected() {
        guard let r = selected else { return }
        if r.sources.contains(.web) {
            NSWorkspace.shared.open(r.entry.url)
        } else if r.sources.contains(.site) {
            NSWorkspace.shared.open(r.entry.url)
            UsageStore.shared.noteOpen(r.entry.id)
        } else if r.sources.contains(.setting) {
            NSWorkspace.shared.open(r.entry.url)
            UsageStore.shared.noteOpen(r.entry.id)
        } else if r.sources.contains(.action) {
            if let a = SystemIndex.actions.first(where: { $0.name == r.entry.name }) { onOpen?(); SystemIndex.perform(a); return }
        } else if r.sources.contains(.app) {
            if let app = AppIndex.shared.apps.first(where: { $0.path == r.entry.path }) { AppIndex.shared.noteLaunch(app) }
            UsageStore.shared.noteOpen(r.entry.path)
            NSWorkspace.shared.openApplication(at: r.entry.url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        } else {
            UsageStore.shared.noteOpen(r.entry.path)
            NSWorkspace.shared.open(r.entry.url)
        }
        onOpen?()
    }

    func copyCalcResult() {
        guard let c = calcResult else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(c, forType: .string)
        onOpen?()
    }

    func revealSelected() {
        guard let r = selected, r.entry.url.isFileURL else { openSelected(); return }
        UsageStore.shared.noteOpen(r.entry.path)
        NSWorkspace.shared.activateFileViewerSelecting([r.entry.url])
        onOpen?()
    }

    func copySelected() {
        guard let r = selected else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([r.entry.url as NSURL])
        pb.setString(r.entry.path, forType: .string)
    }

    static func subtitle(for r: SearchResult) -> String {
        let e = r.entry
        if r.sources.contains(.app) { return "Application" }
        if r.sources.contains(.setting) { return "System Settings" }
        if r.sources.contains(.action) { return "Action" }
        if r.sources.contains(.web) { return "Web search" }
        if r.sources.contains(.site) { return r.entry.kind.isEmpty || r.entry.kind.lowercased() == e.name ? "Website" : "Website · " + r.entry.kind }
        var parts: [String] = []
        parts.append(e.isDirectory ? "Folder" : e.kind)
        if !e.isDirectory { parts.append(FileSystem.humanSize(e.size)) }
        parts.append(FileSystem.shortDate.string(from: e.modified))
        return parts.joined(separator: " · ")
    }

    static func parentLabel(for r: SearchResult) -> String {
        FileSystem.displayPath(r.entry.url.deletingLastPathComponent().path)
    }
}
