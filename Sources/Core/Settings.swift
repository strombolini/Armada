import Foundation
import Combine

/// App settings. Everything except the API key lives in UserDefaults; the key lives in a private file (see `Keychain`).
final class Settings: ObservableObject {
    static let shared = Settings()

    enum Hotkey: String, CaseIterable, Identifiable {
        case cmdSpace, optSpace, ctrlSpace, cmdShiftSpace
        var id: String { rawValue }
        var label: String {
            switch self {
            case .cmdSpace: return "⌘ Space"
            case .optSpace: return "⌥ Space"
            case .ctrlSpace: return "⌃ Space"
            case .cmdShiftSpace: return "⌘⇧ Space"
            }
        }
    }

    /// Opens clipboard history (V with modifiers), or nothing.
    enum ClipboardHotkey: String, CaseIterable, Identifiable {
        case ctrlOptV, hyperV, cmdShiftV, optCmdV, ctrlCmdV, off
        var id: String { rawValue }
        var label: String {
            switch self {
            case .ctrlOptV: return "⌃⌥ V"
            case .hyperV: return "Hyper V (Caps Lock as Hyper in Raycast)"
            case .cmdShiftV: return "⌘⇧ V"
            case .optCmdV: return "⌥⌘ V"
            case .ctrlCmdV: return "⌃⌘ V"
            case .off: return "No shortcut"
            }
        }
    }

    enum Thoroughness: String, CaseIterable, Identifiable {
        case fast, balanced, thorough
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        /// (max routing requests, frontier size, folders expanded per level, max folder depth below the roots)
        var budget: (maxRequests: Int, frontier: Int, perLevel: Int, maxDepth: Int) {
            switch self {
            case .fast: return (6, 35, 3, 2)
            case .balanced: return (12, 45, 5, 2)
            case .thorough: return (20, 80, 7, 3)
            }
        }
    }

    enum OfflineBehavior: String, CaseIterable, Identifiable {
        case openFinder, nameSearch
        var id: String { rawValue }
        var label: String {
            switch self {
            case .openFinder: return "Open the real Finder (only when there is no network at all)"
            case .nameSearch: return "Open Armada anyway — name matches work offline"
            }
        }
    }

    private let d = UserDefaults.standard

    @Published var hotkey: Hotkey { didSet { d.set(hotkey.rawValue, forKey: "hotkey") } }
    @Published var alsoOptionSpace: Bool { didSet { d.set(alsoOptionSpace, forKey: "alsoOptionSpace") } }
    @Published var thoroughness: Thoroughness { didSet { d.set(thoroughness.rawValue, forKey: "thoroughness") } }
    @Published var offlineBehavior: OfflineBehavior { didSet { d.set(offlineBehavior.rawValue, forKey: "offlineBehavior") } }
    @Published var sendPreviews: Bool { didSet { d.set(sendPreviews, forKey: "sendPreviews") } }
    @Published var searchRoots: [String] { didSet { d.set(searchRoots, forKey: "searchRoots") } }
    @Published var ignoredNames: [String] { didSet { d.set(ignoredNames, forKey: "ignoredNames") } }
    @Published var showInDock: Bool { didSet { d.set(showInDock, forKey: "showInDock") } }
    @Published var searchExternalVolumes: Bool { didSet { d.set(searchExternalVolumes, forKey: "searchExternalVolumes") } }
    @Published var webSearchRow: Bool { didSet { d.set(webSearchRow, forKey: "webSearchRow") } }
    @Published var websiteRows: Bool { didSet { d.set(websiteRows, forKey: "websiteRows") } }
    @Published var finderIntegration: Bool { didSet { d.set(finderIntegration, forKey: "finderIntegration") } }
    @Published var clipboardEnabled: Bool { didSet { d.set(clipboardEnabled, forKey: "clipboardEnabled") } }
    @Published var clipboardHotkey: ClipboardHotkey { didSet { d.set(clipboardHotkey.rawValue, forKey: "clipboardHotkey") } }
    @Published var clipboardPasteDirectly: Bool { didSet { d.set(clipboardPasteDirectly, forKey: "clipboardPasteDirectly") } }
    @Published var clipboardLimit: Int { didSet { d.set(clipboardLimit, forKey: "clipboardLimit") } }

    /// Roots actually searched: the configured ones plus external volumes when enabled.
    var effectiveRoots: [String] { searchRoots + (searchExternalVolumes ? Settings.externalVolumeRoots : []) }
    @Published var baseURL: String { didSet { d.set(baseURL, forKey: "baseURL") } }
    @Published var model: String { didSet { d.set(model, forKey: "model") } }
    @Published var apiKey: String { didSet { Keychain.set(apiKey) } }

    static let defaultIgnored = [
        ".git", "node_modules", ".Trash", "__pycache__", "DerivedData", ".cache", ".npm", ".cargo",
        ".venv", "venv", "site-packages", "Pods", ".next", "dist", "build", "target", ".build", "vendor",
        ".gradle", ".idea", ".vscode", "Caches", "Cache", "CacheStorage", "Service Worker", "chrome-profile",
        "Code Cache", "GPUCache", "IndexedDB", "Session Storage", "Local Storage", "blob_storage",
    ]

    static var defaultRoots: [String] {
        let home = NSHomeDirectory()
        var roots = [home]
        let icloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if FileManager.default.fileExists(atPath: icloud) { roots.append(icloud) }
        roots.append(contentsOf: cloudStorageRoots)
        return roots
    }

    /// Dropbox / Google Drive / OneDrive / Box live under ~/Library/CloudStorage on macOS 12.3+.
    static var cloudStorageRoots: [String] {
        let dir = NSHomeDirectory() + "/Library/CloudStorage"
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { !$0.hasPrefix(".") }.map { dir + "/" + $0 }.sorted()
    }

    /// Mounted external / network volumes (opt-in; they can be slow).
    static var externalVolumeRoots: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []).compactMap { name -> String? in
            let p = "/Volumes/" + name
            guard !name.hasPrefix("."), (try? URL(fileURLWithPath: p).resourceValues(forKeys: [.volumeIsRootFileSystemKey]).volumeIsRootFileSystem) == false else { return nil }
            return p
        }
    }

    private init() {
        Settings.migrateFromJevFinder(d)
        hotkey = Hotkey(rawValue: d.string(forKey: "hotkey") ?? "") ?? .cmdSpace
        alsoOptionSpace = d.object(forKey: "alsoOptionSpace") as? Bool ?? true
        thoroughness = Thoroughness(rawValue: d.string(forKey: "thoroughness") ?? "") ?? .balanced
        offlineBehavior = OfflineBehavior(rawValue: d.string(forKey: "offlineBehavior") ?? "") ?? .nameSearch
        if d.object(forKey: "offlineMigrated") == nil { d.set(true, forKey: "offlineMigrated"); offlineBehavior = .nameSearch }
        sendPreviews = d.object(forKey: "sendPreviews") as? Bool ?? true
        searchRoots = d.stringArray(forKey: "searchRoots") ?? Settings.defaultRoots
        ignoredNames = d.stringArray(forKey: "ignoredNames") ?? Settings.defaultIgnored
        showInDock = d.object(forKey: "showInDock") as? Bool ?? false
        searchExternalVolumes = d.object(forKey: "searchExternalVolumes") as? Bool ?? false
        webSearchRow = d.object(forKey: "webSearchRow") as? Bool ?? true
        websiteRows = d.object(forKey: "websiteRows") as? Bool ?? true
        finderIntegration = d.object(forKey: "finderIntegration") as? Bool ?? true
        clipboardEnabled = d.object(forKey: "clipboardEnabled") as? Bool ?? true
        clipboardHotkey = ClipboardHotkey(rawValue: d.string(forKey: "clipboardHotkey") ?? "") ?? .ctrlOptV
        clipboardPasteDirectly = d.object(forKey: "clipboardPasteDirectly") as? Bool ?? true
        clipboardLimit = d.object(forKey: "clipboardLimit") as? Int ?? 300
        baseURL = d.string(forKey: "baseURL") ?? "https://api.codiv.ai"
        model = d.string(forKey: "model") ?? "openjev-latest"
        apiKey = Keychain.get() ?? ProcessInfo.processInfo.environment["CODIV_API_KEY"] ?? ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"] ?? ""
    }
}

extension Settings {
    /// The app used to be "Jev Finder" (bundle ai.codiv.JevFinder): carry its preferences, usage and key over once.
    static func migrateFromJevFinder(_ d: UserDefaults) {
        guard d.object(forKey: "migratedFromJevFinder") == nil else { return }
        d.set(true, forKey: "migratedFromJevFinder")
        if let old = d.persistentDomain(forName: "ai.codiv.JevFinder") {
            // Everything except the first-run flags: the new bundle has to register its own login item.
            for (k, v) in old where d.object(forKey: k) == nil && k != "didOfferLoginItem" { d.set(v, forKey: k) }
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldKey = support.appendingPathComponent("Jev Finder/api-key")
        if Keychain.get() == nil, let k = try? String(contentsOf: oldKey, encoding: .utf8) { Keychain.set(k.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

/// The API key lives in a 0600 file in Application Support (the macOS keychain prompts on every rebuild of an ad-hoc-signed app).
enum Keychain {
    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Armada", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("api-key")
    }

    static func get() -> String? {
        guard let s = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    @discardableResult
    static func set(_ value: String) -> Bool {
        if value.isEmpty { try? FileManager.default.removeItem(at: fileURL); return true }
        do {
            try value.write(to: fileURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch { return false }
    }
}
