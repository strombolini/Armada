import Foundation
import AppKit

/// Spotlight-style application launcher: every .app the system knows about, matched by name the way Spotlight
/// does (prefix, word prefix, initials, then subsequence), ranked by match quality and recent launches.
final class AppIndex {
    static let shared = AppIndex()

    struct App: Hashable {
        let name: String        // "Claude"
        let path: String        // "/Applications/Claude.app"
        let lower: String
        let words: [String]
    }

    private(set) var apps: [App] = []
    static let aliases: [String: String] = ["ppt": "powerpoint", "pp": "powerpoint", "word": "word", "xl": "excel", "vscode": "visual studio code",
                                            "vs code": "visual studio code", "prefs": "system settings", "preferences": "system settings",
                                            "sysprefs": "system settings", "settings": "system settings", "chrome": "google chrome",
                                            "imessage": "messages", "text": "messages", "vpn": "protonvpn", "ps": "photoshop", "ai": "illustrator"]
    private var lastRefresh = Date.distantPast
    private let lock = NSLock()
    private var launchCounts: [String: Int] = UserDefaults.standard.dictionary(forKey: "appLaunchCounts") as? [String: Int] ?? [:]

    private init() { load() }

    /// Rebuilds the list at most every 5 minutes (Spotlight query + the usual folders, ~50 ms).
    func refresh(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastRefresh) > 300 else { return }
        DispatchQueue.global(qos: .utility).async { [self] in load() }
    }

    private func load() {
        lastRefresh = Date()
        let home = NSHomeDirectory()
        var paths = Spotlight.mdfind(["kMDItemContentType == 'com.apple.application-bundle'"], timeout: 4)
        // Always union the standard folders: Spotlight can lag behind fresh installs.
        for dir in ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities", home + "/Applications",
                    "/System/Library/CoreServices/Applications"] {
            for n in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where n.hasSuffix(".app") { paths.append(dir + "/" + n) }
        }
        paths.append("/System/Library/CoreServices/Finder.app")
        let allowedPrefixes = ["/Applications/", "/System/Applications/", home + "/Applications/", "/System/Library/CoreServices/Finder.app",
                               "/System/Library/CoreServices/Applications/", "/Users/Shared/"]
        var seen: Set<String> = []
        var out: [App] = []
        for p in paths where p.hasSuffix(".app") && !p.contains(".app/") {
            guard allowedPrefixes.contains(where: { p.hasPrefix($0) }), seen.insert(p).inserted else { continue }
            // Mac apps have Contents/Info.plist; iPhone/iPad apps installed on Apple silicon are wrappers (WrappedBundle).
            guard FileManager.default.fileExists(atPath: p + "/Contents/Info.plist") || FileManager.default.fileExists(atPath: p + "/WrappedBundle") else { continue }
            let name = ((p as NSString).lastPathComponent as NSString).deletingPathExtension
            out.append(App(name: name, path: p, lower: name.lowercased(), words: name.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)))
        }
        lock.lock(); apps = out; lock.unlock()
    }

    func noteLaunch(_ app: App) {
        launchCounts[app.path, default: 0] += 1
        UserDefaults.standard.set(launchCounts, forKey: "appLaunchCounts")
    }

    /// Ranked matches for a query. Score ≥ 0.9 means "this is what Spotlight would open on ⏎".
    func matches(_ query: String, limit: Int = 5) -> [(App, Double)] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty, q.count <= 40 else { return [] }
        let qWords = q.split(separator: " ").map(String.init)
        refresh()
        lock.lock(); let list = apps; lock.unlock()
        var out: [(App, Double)] = []
        for a in list {
            var s = 0.0
            if a.lower == q { s = 1.0 }
            else if a.lower.hasPrefix(q) { s = 0.95 }
            else if a.words.contains(where: { $0.hasPrefix(q) }) { s = 0.9 }
            else if qWords.count > 1, qWords.allSatisfy({ w in a.words.contains { $0.hasPrefix(w) } }) { s = 0.88 }
            else if q.count >= 2, a.words.count >= 2, a.words.map({ String($0.prefix(1)) }).joined().hasPrefix(q) { s = 0.8 }   // initials: "vsc"
            else if q.count >= 3, a.words.joined().hasPrefix(q) { s = 0.9 }          // "flyjuggle" → "Fly Juggle"
            else if let alias = AppIndex.aliases[q], a.lower == alias || a.words.contains(alias) { s = 0.9 }   // "ppt" → PowerPoint
            else if q.count >= 3, a.lower.contains(q) { s = 0.6 }
            else if q.count >= 4, isSubsequence(q, of: a.lower) { s = 0.35 }
            guard s > 0 else { continue }
            let uses = Double(launchCounts[a.path] ?? 0)
            s += min(0.04, uses * 0.005)
            if a.path.hasPrefix("/Applications/") || a.path.hasPrefix("/System/Applications/") { s += 0.005 }
            out.append((a, s))
        }
        return Array(out.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name.count < $1.0.name.count }.prefix(limit))
    }

    private func isSubsequence(_ q: String, of s: String) -> Bool {
        var it = s.makeIterator()
        for c in q { var found = false; while let x = it.next() { if x == c { found = true; break } }; if !found { return false } }
        return true
    }
}

/// Spotlight also evaluates arithmetic typed into the field ("2+2", "15% of 80", "sqrt(2)", "2^10"). A tiny
/// recursive-descent parser — no NSExpression, so malformed input can't raise an Objective-C exception.
enum Calculator {
    static func evaluate(_ query: String) -> String? {
        var q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 3, q.rangeOfCharacter(from: .decimalDigits) != nil else { return nil }
        if let r = q.range(of: #"^(\d+(?:\.\d+)?)\s*%\s*of\s*(\d+(?:\.\d+)?)$"#, options: .regularExpression) {
            let m = String(q[r]).replacingOccurrences(of: " ", with: "").split(separator: "%")
            if m.count == 2, let a = Double(m[0]), let b = Double(m[1].dropFirst(2)) { return format(a / 100 * b) }
        }
        q = q.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/").replacingOccurrences(of: " ", with: "")
        guard q.rangeOfCharacter(from: CharacterSet(charactersIn: "+-*/^%(")) != nil || q.hasPrefix("sqrt") else { return nil }
        guard q.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789.+-*/^%()sqrtpie").contains($0) }) else { return nil }
        var p = Parser(Array(q))
        guard let v = p.expr(), p.i == p.s.count, v.isFinite else { return nil }
        return format(v)
    }

    private struct Parser {
        let s: [Character]; var i = 0
        init(_ s: [Character]) { self.s = s }
        mutating func expr() -> Double? {
            guard var v = term() else { return nil }
            while i < s.count, s[i] == "+" || s[i] == "-" { let op = s[i]; i += 1; guard let r = term() else { return nil }; v = op == "+" ? v + r : v - r }
            return v
        }
        mutating func term() -> Double? {
            guard var v = power() else { return nil }
            while i < s.count, s[i] == "*" || s[i] == "/" || s[i] == "%" {
                let op = s[i]; i += 1; guard let r = power() else { return nil }
                v = op == "*" ? v * r : op == "/" ? v / r : v.truncatingRemainder(dividingBy: r)
            }
            return v
        }
        mutating func power() -> Double? {
            guard let b = unary() else { return nil }
            if i < s.count, s[i] == "^" { i += 1; guard let e = power() else { return nil }; return pow(b, e) }
            return b
        }
        mutating func unary() -> Double? {
            if i < s.count, s[i] == "-" { i += 1; return unary().map { -$0 } }
            if i < s.count, s[i] == "+" { i += 1; return unary() }
            return atom()
        }
        mutating func atom() -> Double? {
            if match("sqrt(") { guard let v = expr(), match(")") else { return nil }; return v.squareRoot() }
            if match("pi") { return Double.pi }
            if match("e") { return M_E }
            if match("(") { guard let v = expr(), match(")") else { return nil }; return v }
            let start = i
            while i < s.count, s[i].isNumber || s[i] == "." { i += 1 }
            guard i > start, let v = Double(String(s[start..<i])) else { return nil }
            if i < s.count, s[i] == "%", !(i + 1 < s.count && (s[i + 1].isNumber || s[i + 1] == "(")) { i += 1; return v / 100 }
            return v
        }
        mutating func match(_ t: String) -> Bool {
            let c = Array(t); guard i + c.count <= s.count, Array(s[i..<i + c.count]) == c else { return false }; i += c.count; return true
        }
    }

    private static func format(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        let f = NumberFormatter(); f.maximumFractionDigits = 8; f.minimumFractionDigits = 0; f.usesGroupingSeparator = false
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }
}
