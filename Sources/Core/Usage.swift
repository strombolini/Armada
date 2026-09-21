import Foundation
import os

/// One logger per subsystem area; visible in Console.app under subsystem ai.codiv.Armada.
enum Log {
    static let app = Logger(subsystem: "ai.codiv.Armada", category: "app")
    static let search = Logger(subsystem: "ai.codiv.Armada", category: "search")
    static let api = Logger(subsystem: "ai.codiv.Armada", category: "api")
}

/// "Frecency": what the user opened through Jev, so it ranks higher next time and fills the empty-query Recents list.
final class UsageStore {
    static let shared = UsageStore()
    private let key = "usage.v1"
    private var entries: [String: (count: Int, last: Date)] = [:]
    private let lock = NSLock()

    private init() {
        if let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Double]] {
            for (p, v) in raw { entries[p] = (Int(v["c"] ?? 0), Date(timeIntervalSince1970: v["t"] ?? 0)) }
        }
    }

    func noteOpen(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        let e = entries[id] ?? (0, .distantPast)
        entries[id] = (e.count + 1, Date())
        if entries.count > 500 {   // keep the store small: drop the least recently used
            let victims = entries.sorted { $0.value.last < $1.value.last }.prefix(entries.count - 400).map(\.key)
            for v in victims { entries.removeValue(forKey: v) }
        }
        persist()
    }

    /// 0…1 boost that decays over ~a month and saturates after a handful of opens.
    func boost(_ id: String) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[id] else { return 0 }
        let days = Date().timeIntervalSince(e.last) / 86_400
        let recency = exp(-days / 30)
        let frequency = min(1.0, Double(e.count) / 5)
        return 0.5 * recency + 0.5 * frequency
    }

    /// Most recently opened items first (for the empty-query view).
    func recents(limit: Int = 8) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return entries.sorted { $0.value.last > $1.value.last }.prefix(limit).map(\.key)
    }

    private func persist() {
        var raw: [String: [String: Double]] = [:]
        for (p, v) in entries { raw[p] = ["c": Double(v.count), "t": v.last.timeIntervalSince1970] }
        UserDefaults.standard.set(raw, forKey: key)
    }
}

/// Running Codiv usage, so the user can see how much of the free allowance searches consume.
final class UsageMeter: ObservableObject {
    static let shared = UsageMeter()
    static let freeAllowance = 100_000_000   // Codiv's free System One quota (input tokens)

    @Published private(set) var monthTokens: Int
    @Published private(set) var monthRequests: Int
    @Published private(set) var monthSearches: Int
    @Published private(set) var totalTokens: Int
    private var monthKey: String

    private init() {
        let d = UserDefaults.standard
        monthKey = UsageMeter.currentMonthKey()
        if d.string(forKey: "usage.month") != monthKey {
            d.set(monthKey, forKey: "usage.month"); d.set(0, forKey: "usage.monthTokens"); d.set(0, forKey: "usage.monthRequests"); d.set(0, forKey: "usage.monthSearches")
        }
        monthTokens = d.integer(forKey: "usage.monthTokens")
        monthRequests = d.integer(forKey: "usage.monthRequests")
        monthSearches = d.integer(forKey: "usage.monthSearches")
        totalTokens = d.integer(forKey: "usage.totalTokens")
    }

    private static func currentMonthKey() -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: Date())
        return "\(c.year ?? 0)-\(c.month ?? 0)"
    }

    func record(tokens: Int, requests: Int, searches: Int = 0) {
        DispatchQueue.main.async {
            if UsageMeter.currentMonthKey() != self.monthKey {
                self.monthKey = UsageMeter.currentMonthKey(); self.monthTokens = 0; self.monthRequests = 0; self.monthSearches = 0
                UserDefaults.standard.set(self.monthKey, forKey: "usage.month")
            }
            self.monthTokens += tokens; self.monthRequests += requests; self.monthSearches += searches; self.totalTokens += tokens
            let d = UserDefaults.standard
            d.set(self.monthTokens, forKey: "usage.monthTokens"); d.set(self.monthRequests, forKey: "usage.monthRequests")
            d.set(self.monthSearches, forKey: "usage.monthSearches"); d.set(self.totalTokens, forKey: "usage.totalTokens")
        }
    }

    var summary: String {
        let pct = Double(totalTokens) / Double(UsageMeter.freeAllowance) * 100
        let perSearch = monthSearches > 0 ? monthTokens / monthSearches : 0
        return String(format: "This month: %@ tokens over %d searches (≈%@/search) · lifetime %@ = %.2f%% of the free 100M",
                      UsageMeter.human(monthTokens), monthSearches, UsageMeter.human(perSearch), UsageMeter.human(totalTokens), pct)
    }

    static func human(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}
