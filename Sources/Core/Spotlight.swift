import Foundation

/// Name-based candidates via Spotlight (`mdfind`). This is the channel that makes an exact file name
/// (or any word of it) surface instantly, with or without Codiv.
enum Spotlight {
    static let stopwords: Set<String> = ["the", "and", "for", "with", "from", "that", "this", "file", "files", "folder", "document",
                                         "documents", "about", "into", "some", "what", "where", "which", "was", "were", "have", "has",
                                         "one", "any", "all", "not", "but", "are", "our", "your", "you", "its", "his", "her", "they",
                                         "them", "when", "who", "how", "did", "does", "made", "last", "latest", "recent", "new", "old",
                                         "thing", "something", "stuff", "get", "find", "show", "open", "called", "named", "like"]

    static func words(_ query: String) -> [String] {
        let parts = query.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
        return parts.filter { $0.count >= 3 && !stopwords.contains($0) }
    }

    /// Runs `mdfind` and returns matching paths (empty on any failure). Reads stdout to EOF *before* waiting for
    /// exit, so large result sets never dead-lock on a full pipe.
    static func mdfind(_ args: [String], timeout: TimeInterval = 3) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        if p.terminationReason != .exit { return [] }
        return (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
    }

    static func indexAvailable(root: String) -> Bool { !mdfind(["-onlyin", root, "-name", "a"]).isEmpty }

    /// Roots minus those already covered by another root (iCloud Drive lives inside ~).
    static func effectiveRoots(_ roots: [String]) -> [String] {
        roots.filter { r in !roots.contains { o in o != r && r.hasPrefix(o + "/") } }
    }

    /// Score in 0...1 = fraction of query words found in the file name, weighted by how rare each word is.
    /// One `mdfind -name` per word, all in parallel (~60 ms total).
    static func nameMatches(query: String, roots: [String], limit: Int = 30) -> [String: Double] {
        let ws = words(query)
        let whole = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !ws.isEmpty || !whole.isEmpty else { return [:] }
        var terms = ws
        if !whole.isEmpty, !ws.contains(whole), whole.count >= 3 { terms.append(whole) }
        let roots = effectiveRoots(roots)
        var jobs: [(String, String)] = []
        for r in roots { for t in terms { jobs.append((r, t)) } }
        var perTerm: [String: [String]] = [:]
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
            let (root, term) = jobs[i]
            let found = mdfind(["-onlyin", root, "-name", term]).filter { FileSystem.isSearchable(path: $0) }
            lock.lock(); perTerm[term, default: []].append(contentsOf: found); lock.unlock()
        }
        var hits: [String: Double] = [:]
        if let wholeHits = perTerm[whole], whole.count >= 3 {
            for p in wholeHits where (p as NSString).lastPathComponent.lowercased().contains(whole) { hits[p] = 1.0 }
        }
        for w in ws {
            let found = (perTerm[w] ?? []).filter { ($0 as NSString).lastPathComponent.lowercased().contains(w) }
            // Rare words are strong evidence ("lingbot"), words that match hundreds of files ("script") are weak.
            let weight = min(1.0, 40.0 / Double(max(found.count, 1)))
            for p in found where hits[p] != 1.0 { hits[p, default: 0] += weight / Double(ws.count) }
        }
        if hits.isEmpty, let root = roots.first, !indexAvailable(root: root) {
            // No Spotlight index (e.g. a temp directory used in tests): scan instead.
            localScan(roots: roots, words: ws, whole: whole, into: &hits)
        }
        let ranked = hits.sorted { a, b in
            if a.value != b.value { return a.value > b.value }
            let ma = (try? URL(fileURLWithPath: a.key).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let mb = (try? URL(fileURLWithPath: b.key).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return ma > mb
        }
        return Dictionary(uniqueKeysWithValues: ranked.prefix(limit).map { ($0.key, min(1, $0.value)) })
    }

    /// Full-text candidates (Spotlight content index): one exact-word query per distinctive word, in parallel;
    /// files are ranked by how many query words they contain. Words that appear in thousands of files are ignored.
    /// Returns "path\tscore" strings (score in 0…1).
    /// Full-text candidates (Spotlight content index): one exact-word query per distinctive word, in parallel.
    /// Files are scored by the rarity-weighted number of query words they contain (IDF); small files that match
    /// several words (a note that *is* about them) are kept alongside the biggest scorers.
    static func contentMatches(query: String, roots: [String], limit: Int = 20) -> [String] {
        let ws = words(query).filter { $0.count >= 5 }
        guard !ws.isEmpty else { return [] }
        let roots = effectiveRoots(roots)
        var jobs: [(String, String)] = []
        for r in roots { for w in ws { jobs.append((r, w)) } }
        var perWord: [String: Set<String>] = [:]
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
            let (root, w) = jobs[i]
            let found = mdfind(["-onlyin", root, "kMDItemTextContent == \"\(w.replacingOccurrences(of: "\"", with: ""))\"cd"], timeout: 1.5)
            guard found.count <= 4000 else { return }   // hopelessly common
            let ok = found.filter { FileSystem.isSearchable(path: $0) }
            lock.lock(); perWord[w, default: []].formUnion(ok); lock.unlock()
        }
        guard !perWord.isEmpty else { return [] }
        var idf: [String: Double] = [:]
        for (w, paths) in perWord { idf[w] = 1.0 / log(2.0 + Double(paths.count)) }
        let maxScore = idf.values.reduce(0, +)
        var scores: [String: (Double, Int)] = [:]
        for (w, paths) in perWord { for p in paths { let c = scores[p] ?? (0, 0); scores[p] = (c.0 + (idf[w] ?? 0), c.1 + 1) } }
        // Personal documents live shallow (~/Downloads/x, ~/Documents/y); code trees live deep. Prefer shallow.
        let homeDepth = FileSystem.home.split(separator: "/").count
        for (p, v) in scores {
            let depth = p.split(separator: "/").count - homeDepth
            let bonus = 1.0 + Double(max(0, 4 - depth)) * 0.5
            scores[p] = (v.0 * bonus, v.1)
        }
        let minCount = ws.count >= 3 ? 2 : 1
        func size(_ p: String) -> Int { (try? URL(fileURLWithPath: p).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max }
        let eligible = scores.filter { $0.value.1 >= minCount }
        let sizes = Dictionary(uniqueKeysWithValues: eligible.keys.map { ($0, size($0)) })
        func bucket(_ maxSize: Int, _ n: Int) -> [String] {
            eligible.filter { (sizes[$0.key] ?? .max) <= maxSize }
                .sorted { a, b in a.value.0 != b.value.0 ? a.value.0 > b.value.0 : (sizes[a.key] ?? 0) < (sizes[b.key] ?? 0) }
                .prefix(n).map(\.key)
        }
        // Big scorers, then small files, then tiny notes — so a 60-byte note that names the thing is never crowded out.
        let picks = bucket(.max, 10) + bucket(40_000, 8) + bucket(4_000, 6)
        var out: [String] = []
        var seen: Set<String> = []
        for p in picks where seen.insert(p).inserted && out.count < limit + 4 {
            out.append("\(p)\t\(min(1.0, (scores[p]?.0 ?? 0) / max(maxScore, 0.0001)))")
        }
        return out
    }

    /// Spotlight's index has gaps (fresh or oddly-created files). A shallow scan of the user folders — cached
    /// listings, three levels deep, capped — covers them. Runs off the critical path and is merged when done.
    static func localScan(roots: [String], words: [String], whole: String, into hits: inout [String: Double], maxDepth: Int = 3, maxEntries: Int = 12_000) {
        guard !words.isEmpty || whole.count >= 3 else { return }
        var roots = roots
        if let i = roots.firstIndex(of: FileSystem.home) {
            roots.remove(at: i)
            roots.append(contentsOf: ["Desktop", "Documents", "Downloads"].map { FileSystem.home + "/" + $0 })
        }
        var scanned = 0
        var matched: [(String, String)] = []   // (path, lowercased name)
        var counts: [String: Int] = [:]
        func visit(_ dir: URL, depth: Int) {
            guard scanned < maxEntries else { return }
            for e in FileSystem.list(dir) {
                scanned += 1
                let lower = e.name.lowercased()
                var any = false
                for w in words where lower.contains(w) { counts[w, default: 0] += 1; any = true }
                if any || (whole.count >= 3 && lower.contains(whole)) { matched.append((e.path, lower)) }
                if e.isDirectory, depth < maxDepth, scanned < maxEntries { visit(e.url, depth: depth + 1) }
            }
        }
        for r in roots { visit(URL(fileURLWithPath: r), depth: 1) }
        for (p, name) in matched where hits[p] == nil {
            if whole.count >= 3, name.contains(whole) { hits[p] = 1.0; continue }
            var score = 0.0
            for w in words where name.contains(w) { score += min(1.0, 40.0 / Double(max(counts[w] ?? 1, 1))) / Double(max(words.count, 1)) }
            if score > 0 { hits[p] = score }
        }
    }

    private static func bruteForce(root: String, words: [String], into hits: inout [String: Double]) {
        guard !words.isEmpty, let en = FileManager.default.enumerator(atPath: root) else { return }
        var n = 0
        while let rel = en.nextObject() as? String {
            n += 1; if n > 200_000 { break }
            let name = (rel as NSString).lastPathComponent
            if FileSystem.isIgnored(name: name) { en.skipDescendants(); continue }
            let lower = name.lowercased()
            let score = words.reduce(0.0) { $0 + (lower.contains($1) ? 1.0 / Double(words.count) : 0) }
            if score > 0 { hits[root + "/" + rel] = score }
        }
    }
}
