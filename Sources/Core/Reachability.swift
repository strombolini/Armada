import Foundation
import Network
import Combine

/// Tracks whether Codiv is reachable: network path + a cached API ping + outcomes of real requests.
final class Reachability: ObservableObject {
    static let shared = Reachability()

    @Published private(set) var networkAvailable = true
    @Published private(set) var apiReachable = true
    private(set) var lastCheck = Date.distantPast

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ai.codiv.armada.reachability")
    private var timer: Timer?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                let ok = path.status == .satisfied
                if ok != self.networkAvailable { self.networkAvailable = ok }
                if ok { Task { await self.refresh(force: true) } } else { self.apiReachable = false }
            }
        }
        monitor.start(queue: queue)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { await self?.refresh(force: false) } }
        Task { await refresh(force: true) }
    }

    /// True when we believe Codiv can be reached right now (answers instantly from cache).
    var isOnline: Bool { networkAvailable && apiReachable }

    func noteSuccess() { DispatchQueue.main.async { self.apiReachable = true; self.lastCheck = Date() } }
    func noteFailure() {
        DispatchQueue.main.async {
            self.apiReachable = false; self.lastCheck = Date()
            // Re-check soon so a transient blip doesn't leave the "offline" badge up for a minute.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { Task { await self.refresh(force: true) } }
        }
    }

    @discardableResult
    func refresh(force: Bool) async -> Bool {
        if !force, Date().timeIntervalSince(lastCheck) < 20 { return isOnline }
        guard networkAvailable else { return false }
        let ok = await CodivClient.shared.ping()
        await MainActor.run { self.apiReachable = ok; self.lastCheck = Date() }
        return ok
    }
}
