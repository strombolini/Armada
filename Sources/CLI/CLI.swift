import AppKit
import Foundation
import ApplicationServices
import ServiceManagement

/// Headless mode used by the test harness:
///   "Armada" --search "query" [--root PATH ...] [--fast|--balanced|--thorough] [--no-previews] [--json] [--verbose]
///   "Armada" --set-key sk-codiv-...
///   "Armada" --ping | --doctor
enum CLI {
    static func runIfRequested() -> Bool {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let first = args.first, first.hasPrefix("--") else { return false }

        if first == "--set-key", args.count >= 2 {
            Settings.shared.apiKey = args[1]
            print(Keychain.get() == args[1] ? "API key saved to \(Keychain.fileURL.path)" : "Failed to save the key.")
            return true
        }
        if first == "--login-status" {
            let st = SMAppService.mainApp.status
            print("launch at login: \(st == .enabled ? "enabled" : st == .requiresApproval ? "requires approval in System Settings › General › Login Items" : st == .notFound ? "not registered" : "not registered")")
            return true
        }
        if first == "--apps", args.count >= 2 {
            for (a, sc) in AppIndex.shared.matches(args[1], limit: 10) { print(String(format: "%.3f  %@  (%@)", sc, a.name, a.path)) }
            print("index size: \(AppIndex.shared.apps.count)")
            return true
        }
        if first == "--finder-results", args.count >= 2 {
            // Same thing ⏎ in a Finder search field does: results for the query, scoped to --root, shown in Finder's own window.
            let rootArg = args.firstIndex(of: "--root").flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil }
            let root = (rootArg.map { ($0 as NSString).expandingTildeInPath }) ?? NSHomeDirectory()
            var finished = false
            Task {
                var o = SemanticSearch.Options(); o.roots = [root]
                let results = await SemanticSearch().search(query: args[1], options: o) { _, _ in }
                let files = results.filter { $0.entry.url.isFileURL && $0.score > 0.001 }.prefix(25).map(\.entry.url)
                if let dir = ResultsFolder.build(query: args[1], scope: URL(fileURLWithPath: root), files: Array(files)) {
                    print("results folder: \(dir.path) (\(files.count) links)")
                    await MainActor.run { ResultsFolder.show(inFinder: dir) }
                }
                finished = true
            }
            while !finished { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03)) }
            return true
        }
        if first == "--finder-bridge" {
            // Run the Finder/Open-panel bridge in this (terminal-trusted) process for N seconds — for testing.
            let secs = Double(args.count >= 2 ? args[1] : "30") ?? 30
            MainActor.assumeIsolated { FinderSearchBridge.shared.start() }
            print("bridge running for \(Int(secs)) s (trusted: \(FinderSearchBridge.isTrusted))")
            RunLoop.main.run(until: Date(timeIntervalSinceNow: secs))
            return true
        }
        if first == "--ax-probe" {
            // What the Finder bridge would see right now: frontmost app, its focused element, the window's folder.
            print("accessibility trusted: \(FinderSearchBridge.isTrusted)")
            guard let app = NSWorkspace.shared.frontmostApplication else { return true }
            let el = AXUIElementCreateApplication(app.processIdentifier)
            print("frontmost: \(app.bundleIdentifier ?? "?")")
            if let w = AX.element(el, kAXFocusedWindowAttribute) {
                print("window role: \(AX.string(w, kAXRoleAttribute) ?? "-") subrole: \(AX.string(w, kAXSubroleAttribute) ?? "-") title: \(AX.string(w, kAXTitleAttribute) ?? "-")")
                if app.bundleIdentifier == "com.apple.finder" { print("finder front folder: \(FinderSearchBridge.finderFrontFolder()?.path ?? "-")") }
                print("first file url in window: \(AX.firstFileURL(in: w, depth: 0)?.path ?? "-")")
            }
            if let f = AX.element(el, kAXFocusedUIElementAttribute) {
                print("focused: role \(AX.string(f, kAXRoleAttribute) ?? "-") subrole \(AX.string(f, kAXSubroleAttribute) ?? "-") value '\(AX.string(f, kAXValueAttribute) ?? "")' frame \(AX.frame(f).map { "\($0)" } ?? "-")")
            }
            return true
        }
        if first == "--sites", args.count >= 2 {
            WebIndex.shared.loadNow()
            for h in WebIndex.shared.matches(args[1], limit: 5) { print(String(format: "%.3f  %@  — %@  <%@>", h.score, h.name, h.detail, h.url.absoluteString)) }
            print("index size: \(WebIndex.shared.sites.count) sites, \(WebIndex.shared.pages.count) pages")
            return true
        }
        if first == "--calc", args.count >= 2 { print(Calculator.evaluate(args[1]) ?? "not an expression"); return true }
        if first == "--doctor" {
            // Everything an installer/agent needs to know, one line each, machine-parseable (OK/FAIL prefix).
            var finished = false
            Task {
                let keySet = !Settings.shared.apiKey.isEmpty
                var keyWorks = false
                if keySet { keyWorks = (try? await CodivClient.shared.choices(state: ["ping": "hi"], questions: ["q": CodivClient.Choice(instructions: "greeting?", criteria: [("yes", ""), ("no", "")])])) != nil }
                func line(_ ok: Bool, _ name: String, _ hint: String) { print("\(ok ? "OK  " : "FAIL") \(name)\(ok ? "" : " — " + hint)") }
                line(keySet, "api key stored", "run --set-key sk-codiv-… (get one at https://codiv.ai/signup)")
                line(keyWorks, "codiv answers with this key", keySet ? "check the key / network; curl https://api.codiv.ai/v1/models" : "no key")
                line(Permissions.hasFullDiskAccess, "full disk access", "System Settings › Privacy & Security › Full Disk Access → Armada (per-folder prompts otherwise)")
                line(FinderSearchBridge.isTrusted, "accessibility (finder + open/save panel search)", "System Settings › Privacy & Security › Accessibility → Armada")
                line(SMAppService.mainApp.status == .enabled, "launch at login", "toggle in Settings › Behaviour or the setup checklist")
                line(!HotKeyCenter.spotlightOwnsCommandSpace(), "⌘ space owned by armada", "the running app turns Spotlight's shortcut off automatically; launch it")
                line(FileManager.default.fileExists(atPath: "/Applications/Armada.app"), "installed in /Applications", "copy the app there for a stable code identity")
                print("roots: " + Settings.shared.effectiveRoots.map(FileSystem.displayPath).joined(separator: ", "))
                finished = true
            }
            while !finished { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03)) }
            return true
        }
        if first == "--ping" {
            let sem = DispatchSemaphore(value: 0)
            Task { print(await CodivClient.shared.ping() ? "Codiv reachable" : "Codiv unreachable"); sem.signal() }
            sem.wait()
            return true
        }
        guard first == "--search" else {
            FileHandle.standardError.write(Data("Unknown option \(first)\n".utf8))
            return true
        }

        var query = ""
        var opts = SemanticSearch.Options()
        var roots: [String] = []
        var json = false
        var i = 1
        while i < args.count {
            let a = args[i]
            switch a {
            case "--root": if i + 1 < args.count { roots.append((args[i + 1] as NSString).expandingTildeInPath); i += 1 }
            case "--fast": opts.budget = Settings.Thoroughness.fast.budget
            case "--balanced": opts.budget = Settings.Thoroughness.balanced.budget
            case "--thorough": opts.budget = Settings.Thoroughness.thorough.budget
            case "--no-previews": opts.sendPreviews = false
            case "--json": json = true
            case "--verbose", "-v": opts.verbose = true
            default: query = query.isEmpty ? a : query + " " + a
            }
            i += 1
        }
        if !roots.isEmpty { opts.roots = roots }
        guard !query.isEmpty else { print("usage: --search \"query\" [--root PATH] [--json]"); return true }

        // The engine reports progress on the main actor, so keep the main run loop turning instead of blocking it.
        var finished = false
        let started = Date()
        Task {
            let engine = SemanticSearch()
            WebIndex.shared.loadNow()
            let files = await engine.search(query: query, options: opts) { _, _ in }
            // Same merge as the panel: launcher-style app matches first, then Jev's files.
            let results = await MainActor.run { SearchController.merge(apps: SearchController.appHits(for: query), system: SearchController.systemHits(for: query), sites: SearchController.siteHits(for: query), files: files) }
            if let calc = Calculator.evaluate(query) { print(json ? "" : "  = \(calc)") ; _ = calc }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            if json {
                let payload: [String: Any] = [
                    "query": query, "ms": ms, "requests": CodivClient.shared.requestCount, "tokens": CodivClient.shared.tokenCount,
                    "calc": Calculator.evaluate(query) ?? "",
                    "results": results.prefix(25).map { ["path": $0.entry.url.isFileURL ? $0.entry.path : $0.entry.url.absoluteString, "name": $0.entry.name, "score": $0.score, "prior": $0.prior,
                                                           "sources": $0.sources.map(\.rawValue).sorted(), "dir": $0.entry.isDirectory] },
                ]
                let data = try! JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                print(String(data: data, encoding: .utf8)!)
            } else {
                print("== \(query)  (\(ms) ms, \(CodivClient.shared.requestCount) requests, \(CodivClient.shared.tokenCount) tokens)")
                for r in results.prefix(10) {
                    let label = r.entry.url.isFileURL ? FileSystem.displayPath(r.entry.path) + (r.entry.isDirectory ? "/" : "") : "\(r.entry.name)  [\(r.sources.map(\.rawValue).joined())]"
                    print(String(format: "  %5.1f%%  %@", r.score * 100, label))
                }
            }
            finished = true
        }
        while !finished { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03)) }
        return true
    }
}
