import AppKit
import SQLite3

/// Websites the user actually visits, read from the browsers' own history and bookmark stores. Spotlight only reads
/// Safari; Jev reads Safari (needs Full Disk Access), the Chromium family (Chrome, Brave, Edge, Arc, Vivaldi) and
/// Firefox. Matched locally like apps — nothing here is ever sent to Codiv.
final class WebIndex {
    static let shared = WebIndex()

    struct Site { let url: URL; let host: String; let title: String; let visits: Int; let lastVisit: Date; let bookmarked: Bool }
    struct Page { let url: URL; let host: String; let title: String; let visits: Int }
    struct Hit { let url: URL; let name: String; let detail: String; let score: Double }

    private(set) var sites: [Site] = []
    private(set) var pages: [Page] = []
    private var favicons: [String: NSImage] = [:]
    private var loadedAt = Date.distantPast
    private var loading = false
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ai.codiv.armada.webindex", qos: .utility)

    init() {}
    /// Test seam.
    init(sites: [Site], pages: [Page] = []) { self.sites = sites; self.pages = pages; loadedAt = Date() }

    /// Loads on first use and every 5 minutes after; callers get whatever is loaded right now.
    func refreshIfStale() {
        lock.lock(); defer { lock.unlock() }
        guard !loading, Date().timeIntervalSince(loadedAt) > 300 else { return }
        loading = true
        queue.async { self.load() }
    }

    /// Blocking load for the CLI, which exits before the background refresh would land.
    func loadNow() { lock.lock(); loading = true; lock.unlock(); load() }

    func favicon(for host: String) -> NSImage? { lock.lock(); defer { lock.unlock() }; return favicons[host] }

    // MARK: matching

    /// Host rows ("youtube.com") for a query that names a site, plus visited pages whose title matches every word.
    func matches(_ query: String, limit: Int = 3) -> [Hit] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        lock.lock(); let sites = self.sites, pages = self.pages; lock.unlock()
        var out: [Hit] = []

        let bare = q.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "www.", with: "")
        let oneWord = !bare.contains(" ")
        for s in sites {
            let labels = s.host.split(separator: ".").map(String.init)
            let sansTLD = labels.dropLast().joined(separator: ".")
            let title = s.title.lowercased()
            var score = 0.0
            if oneWord, s.host == bare || sansTLD == bare || labels.first == bare { score = 0.93 }           // "youtube" → youtube.com
            else if oneWord, bare.count >= 3, s.host.hasPrefix(bare) || labels.first?.hasPrefix(bare) == true { score = s.visits >= 10 || s.bookmarked ? 0.9 : 0.85 }
            else if bare.count >= 3, title == bare || title.hasPrefix(bare + " ") { score = 0.88 }   // site called "Hacker News"
            guard score > 0 else { continue }
            score += min(0.02, log10(Double(max(1, s.visits))) / 200) + (s.bookmarked ? 0.005 : 0)
            out.append(Hit(url: s.url, name: s.host, detail: s.title, score: score))
        }
        out.sort { $0.score > $1.score }
        out = Array(out.prefix(limit))

        // Pages: "vice documentary" → the history entry titled "vice documentary - YouTube".
        let words = q.split(separator: " ").map(String.init).filter { $0.count >= 2 }
        if q.count >= 5, !words.isEmpty {
            var pageHits: [Hit] = []
            for p in pages {
                let hay = (p.title + " " + p.host).lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                guard words.allSatisfy({ w in hay.contains(where: { $0.hasPrefix(w) }) }) else { continue }
                let score = 0.72 + min(0.05, log10(Double(max(1, p.visits))) / 60)
                pageHits.append(Hit(url: p.url, name: p.title, detail: p.host, score: score))
            }
            pageHits.sort { $0.score > $1.score }
            // A one-word query that already produced the site row doesn't need that site's pages too.
            let shownHosts = Set(out.map(\.name))
            for h in pageHits.prefix(2) where !out.contains(where: { $0.url == h.url }) && !(words.count == 1 && shownHosts.contains(h.detail)) { out.append(h) }
        }
        return out
    }

    // MARK: loading

    private struct Raw { var url: URL; var title: String; var visits: Int; var last: Date; var bookmarked: Bool }

    private func load() {
        var raws: [Raw] = []
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        raws += WebIndex.safari(home)
        for dir in ["Google/Chrome", "BraveSoftware/Brave-Browser", "Microsoft Edge", "Arc/User Data", "Chromium", "Vivaldi"] {
            raws += WebIndex.chromium("\(home)/Library/Application Support/\(dir)")
        }
        raws += WebIndex.firefox("\(home)/Library/Application Support/Firefox/Profiles")

        // One row per host: bookmarks beat the site root beats the most visited page; visits are summed per host.
        var byHost: [String: (best: Raw, title: String, titleRank: Int, visits: Int, last: Date, bookmarked: Bool)] = [:]
        var pageList: [Page] = []
        for r in raws {
            guard let host = WebIndex.host(of: r.url) else { continue }
            if !r.title.isEmpty, r.visits >= 2 { pageList.append(Page(url: r.url, host: host, title: r.title, visits: r.visits)) }
            // The site's label: its bookmark name, else the front page's title with the "page - " part dropped.
            let label = r.bookmarked || WebIndex.isRoot(r.url) ? WebIndex.siteLabel(r.title) : ""
            let labelRank = label.isEmpty ? -1 : WebIndex.rank(r)
            if var cur = byHost[host] {
                cur.visits += r.visits; cur.last = max(cur.last, r.last); cur.bookmarked = cur.bookmarked || r.bookmarked
                if WebIndex.rank(r) > WebIndex.rank(cur.best) { cur.best = r }
                if labelRank > cur.titleRank { cur.title = label; cur.titleRank = labelRank }
                byHost[host] = cur
            } else {
                byHost[host] = (r, label, labelRank, r.visits, r.last, r.bookmarked)
            }
        }
        let sites = byHost.map { host, v in
            Site(url: WebIndex.rootURL(v.best.url), host: host, title: v.title, visits: v.visits, lastVisit: v.last, bookmarked: v.bookmarked)
        }.sorted { $0.visits > $1.visits }
        pageList.sort { $0.visits > $1.visits }
        let icons = WebIndex.chromiumFavicons(home: home, hosts: sites.prefix(400).map(\.host))

        lock.lock()
        self.sites = sites; self.pages = Array(pageList.prefix(4000)); self.favicons = icons
        loadedAt = Date(); loading = false
        lock.unlock()
        Log.search.info("web index: \(sites.count) sites, \(pageList.count) pages, \(icons.count) favicons")
    }

    private static func rank(_ r: Raw) -> Int { (r.bookmarked ? 1_000_000 : 0) + (isRoot(r.url) ? 100_000 : 0) + r.visits }
    private static func isRoot(_ u: URL) -> Bool { (u.path.isEmpty || u.path == "/") && u.query == nil }
    /// A site's row opens its front page, not the deepest page the user once visited.
    private static func rootURL(_ u: URL) -> URL {
        guard var c = URLComponents(url: u, resolvingAgainstBaseURL: false), c.path.count > 1 || c.query != nil else { return u }
        c.path = "/"; c.query = nil; c.fragment = nil
        return c.url ?? u
    }

    static func host(of u: URL) -> String? {
        guard let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https", var h = u.host?.lowercased() else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        guard h.contains("."), !h.hasPrefix("localhost"), !h.contains("127.0.0.1"), !h.contains("accounts."), !h.hasPrefix("login.") else { return nil }
        return h
    }

    /// "cats - YouTube" → "YouTube", "Claude Code limits | Claude Help Center" → "Claude Help Center".
    static func siteLabel(_ title: String) -> String {
        let t = cleanTitle(title)
        for sep in [" - ", " | ", " – ", " — ", " · ", " : "] {
            if let r = t.range(of: sep, options: .backwards) {
                let tail = t[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if (2...30).contains(tail.count) { return tail }
            }
        }
        return t.count <= 40 ? t : ""
    }

    static func cleanTitle(_ t: String) -> String {
        var s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: #"^\(\d+\+?\)\s*"#, options: .regularExpression) { s.removeSubrange(r) }   // "(66) YouTube"
        return s
    }

    // Safari: History.db + Bookmarks.plist (both behind Full Disk Access; silently empty without it).
    private static func safari(_ home: String) -> [Raw] {
        var out: [Raw] = []
        rows(db: "\(home)/Library/Safari/History.db",
             sql: "select i.url, i.visit_count, coalesce(max(v.visit_time),0), coalesce(max(v.title),'') from history_items i left join history_visits v on v.history_item = i.id group by i.id order by i.visit_count desc limit 5000") { s in
            guard let u = URL(string: text(s, 0)) else { return }
            out.append(Raw(url: u, title: cleanTitle(text(s, 3)), visits: Int(sqlite3_column_int64(s, 1)), last: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(s, 2)), bookmarked: false))
        }
        if let data = FileManager.default.contents(atPath: "\(home)/Library/Safari/Bookmarks.plist"),
           let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            func walk(_ node: [String: Any]) {
                if node["WebBookmarkType"] as? String == "WebBookmarkTypeLeaf", let s = node["URLString"] as? String, let u = URL(string: s) {
                    let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? ""
                    out.append(Raw(url: u, title: cleanTitle(title), visits: 1, last: .distantPast, bookmarked: true))
                }
                for c in node["Children"] as? [[String: Any]] ?? [] { walk(c) }
            }
            walk(root)
        }
        return out
    }

    // Chromium family: <profile>/History (sqlite) + <profile>/Bookmarks (json). Times are µs since 1601-01-01.
    private static func chromium(_ base: String) -> [Raw] {
        var out: [Raw] = []
        for profile in profiles(base) {
            rows(db: "\(profile)/History", sql: "select url, title, visit_count, last_visit_time from urls where hidden = 0 order by visit_count desc limit 5000") { s in
                guard let u = URL(string: text(s, 0)) else { return }
                let t = Date(timeIntervalSince1970: Double(sqlite3_column_int64(s, 3)) / 1_000_000 - 11_644_473_600)
                out.append(Raw(url: u, title: cleanTitle(text(s, 1)), visits: Int(sqlite3_column_int64(s, 2)), last: t, bookmarked: false))
            }
            if let data = FileManager.default.contents(atPath: "\(profile)/Bookmarks"),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let roots = json["roots"] as? [String: Any] {
                func walk(_ node: [String: Any]) {
                    if node["type"] as? String == "url", let s = node["url"] as? String, let u = URL(string: s) {
                        out.append(Raw(url: u, title: cleanTitle(node["name"] as? String ?? ""), visits: 1, last: .distantPast, bookmarked: true))
                    }
                    for c in node["children"] as? [[String: Any]] ?? [] { walk(c) }
                }
                for r in roots.values { if let d = r as? [String: Any] { walk(d) } }
            }
        }
        return out
    }

    private static func profiles(_ base: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base) else { return [] }
        return names.filter { $0 == "Default" || $0.hasPrefix("Profile ") }.map { "\(base)/\($0)" }
    }

    // Firefox: places.sqlite, times in µs since 1970.
    private static func firefox(_ profilesDir: String) -> [Raw] {
        var out: [Raw] = []
        for p in (try? FileManager.default.contentsOfDirectory(atPath: profilesDir)) ?? [] {
            rows(db: "\(profilesDir)/\(p)/places.sqlite", sql: "select url, coalesce(title,''), visit_count, coalesce(last_visit_date,0) from moz_places where visit_count > 0 order by visit_count desc limit 5000") { s in
                guard let u = URL(string: text(s, 0)) else { return }
                out.append(Raw(url: u, title: cleanTitle(text(s, 1)), visits: Int(sqlite3_column_int64(s, 2)), last: Date(timeIntervalSince1970: Double(sqlite3_column_int64(s, 3)) / 1_000_000), bookmarked: false))
            }
        }
        return out
    }

    /// Chrome keeps favicons in a sqlite file; the largest bitmap per host makes the row look like Spotlight's.
    private static func chromiumFavicons(home: String, hosts: [String]) -> [String: NSImage] {
        var icons: [String: NSImage] = [:]
        let wanted = Set(hosts)
        for dir in ["Google/Chrome", "BraveSoftware/Brave-Browser", "Microsoft Edge", "Arc/User Data", "Chromium", "Vivaldi"] {
            for profile in profiles("\(home)/Library/Application Support/\(dir)") {
                rows(db: "\(profile)/Favicons", sql: "select m.page_url, b.image_data, b.width from icon_mapping m join favicon_bitmaps b on b.icon_id = m.icon_id where b.width >= 16 order by b.width desc") { s in
                    guard let u = URL(string: text(s, 0)), let h = host(of: u), wanted.contains(h), icons[h] == nil,
                          let bytes = sqlite3_column_blob(s, 1) else { return }
                    let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(s, 1)))
                    if let img = NSImage(data: data) { icons[h] = img }
                }
            }
        }
        return icons
    }

    // MARK: sqlite

    /// Opens the browser's live database read-only and lock-free (`immutable=1`), so it works while the browser runs.
    private static func rows(db path: String, sql: String, _ body: (OpaquePointer) -> Void) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        var db: OpaquePointer?
        let uri = "file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path) + "?immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else { return }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { body(stmt) }
    }

    private static func text(_ s: OpaquePointer, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(s, i) else { return "" }
        return String(cString: c)
    }
}
