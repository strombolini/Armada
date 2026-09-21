import Foundation
import AppKit
import UniformTypeIdentifiers

/// One file-system entry as Armada sees it.
struct FSEntry: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool      // a real, traversable folder (packages such as .app/.pages count as files)
    let isPackage: Bool
    let size: Int64
    let modified: Date
    let created: Date
    let kind: String

    var id: String { url.isFileURL ? url.path : url.absoluteString }
    var path: String { url.path }
    var ext: String { url.pathExtension.lowercased() }

    static func == (a: FSEntry, b: FSEntry) -> Bool { a.url == b.url }
    func hash(into h: inout Hasher) { h.combine(url) }
}

enum FileSystem {
    static let home = NSHomeDirectory()
    static let iCloudRoot = home + "/Library/Mobile Documents/com~apple~CloudDocs"
    static let fm = FileManager.default

    static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey,
                                         .creationDateKey, .localizedTypeDescriptionKey, .isHiddenKey, .isSymbolicLinkKey, .contentTypeKey]

    private static let cacheLock = NSLock()
    private static var listingCache: [String: (mtime: Date, entries: [FSEntry])] = [:]

    static func isIgnored(name: String) -> Bool {
        if name.hasPrefix(".") { return true }
        if Settings.shared.ignoredNames.contains(name) { return true }
        let lower = name.lowercased()
        if lower.hasSuffix(".pyc") || lower.hasSuffix(".map") || lower.hasSuffix(".min.js") || lower.hasSuffix(".min.css") || lower == "ds_store" { return true }
        return false
    }

    /// `~/Library` is skipped except for iCloud Drive.
    static func isSearchable(path: String) -> Bool {
        if path.hasPrefix(iCloudRoot) || path.hasPrefix(cloudStorageDir) { return true }
        if path.hasPrefix(home + "/Library") { return false }
        for comp in path.split(separator: "/") where isIgnored(name: String(comp)) { return false }
        return true
    }

    /// Lists a directory (visible, non-ignored entries), cached by directory modification time.
    static func list(_ dir: URL, includeHidden: Bool = false) -> [FSEntry] {
        let mtime = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let key = dir.path + (includeHidden ? "#h" : "")
        cacheLock.lock()
        if let c = listingCache[key], c.mtime == mtime { cacheLock.unlock(); return c.entries }
        cacheLock.unlock()

        var entries: [FSEntry] = []
        let opts: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: opts) else { return [] }
        for u in urls {
            let name = u.lastPathComponent
            if !includeHidden, isIgnored(name: name) { continue }
            // Symlinked folders (e.g. ~/Desktop/Applications → /Applications) would make the walk leave the tree.
            if (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
            if let e = entry(for: u) { entries.append(e) }
        }
        entries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        cacheLock.lock(); listingCache[key] = (mtime, entries); cacheLock.unlock()
        return entries
    }

    static func entry(for u: URL) -> FSEntry? {
        guard let rv = try? u.resourceValues(forKeys: Set(keys)) else { return nil }
        let isPkg = rv.isPackage ?? false
        let isDir = (rv.isDirectory ?? false) && !isPkg
        var kind = rv.localizedTypeDescription ?? (isDir ? "Folder" : "Document")
        if isDir { kind = "Folder" }
        return FSEntry(url: u, name: u.lastPathComponent, isDirectory: isDir, isPackage: isPkg,
                       size: Int64(rv.fileSize ?? 0), modified: rv.contentModificationDate ?? .distantPast,
                       created: rv.creationDate ?? .distantPast, kind: kind)
    }

    static let cloudStorageDir = home + "/Library/CloudStorage/"

    /// "~/Desktop/foo", "iCloud Drive/foo", "Google Drive/foo" for the model and the UI.
    static func displayPath(_ path: String) -> String {
        if path.hasPrefix(iCloudRoot) { return "iCloud Drive" + path.dropFirst(iCloudRoot.count) }
        if path.hasPrefix(cloudStorageDir) {
            let rest = path.dropFirst(cloudStorageDir.count)
            let provider = rest.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            return cloudDisplayName(provider) + rest.dropFirst(provider.count)
        }
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// "GoogleDrive-me@gmail.com" → "Google Drive", "Dropbox" → "Dropbox", "OneDrive-Personal" → "OneDrive"
    static func cloudDisplayName(_ folder: String) -> String {
        let base = folder.split(separator: "-").first.map(String.init) ?? folder
        return base.replacingOccurrences(of: "GoogleDrive", with: "Google Drive").replacingOccurrences(of: "OneDrive", with: "OneDrive")
    }

    static func displayName(forRoot path: String) -> String {
        if path == iCloudRoot { return "iCloud Drive" }
        if path == home { return "Home" }
        if path.hasPrefix(cloudStorageDir) { return cloudDisplayName((path as NSString).lastPathComponent) }
        return (path as NSString).lastPathComponent
    }

    static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .file; return f
    }()

    static func humanSize(_ n: Int64) -> String { sizeFormatter.string(fromByteCount: n) }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; f.doesRelativeDateFormatting = true; return f
    }()

    static let isoDay: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    static func icon(for entry: FSEntry) -> NSImage { IconCache.icon(forPath: entry.path, isDirectory: entry.isDirectory, isPackage: entry.isPackage, ext: entry.ext) }

    /// "2026-09-18 (3 days ago)" — absolute date plus a coarse relative age, so time words in a query can be resolved.
    static func dateAndAge(_ d: Date) -> String {
        let days = Int(Date().timeIntervalSince(d) / 86_400)
        let age: String
        switch days {
        case ..<0: age = "in the future"
        case 0: age = "today"
        case 1: age = "yesterday"
        case 2..<14: age = "\(days) days ago"
        case 14..<60: age = "\(days / 7) weeks ago"
        case 60..<365: age = "\(days / 30) months ago"
        default: age = String(format: "%.1f years ago", Double(days) / 365)
        }
        return "\(isoMinute.string(from: d)), \(age)"
    }

    static let isoMinute: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()

    /// Finder-style subtitle: "PDF document · 85 KB · 9/11/26, 7:53 PM"
    static let shortDate: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f
    }()

    static func availableSpace(at path: String) -> String {
        if let attrs = try? fm.attributesOfFileSystem(forPath: path), let free = attrs[.systemFreeSize] as? Int64 {
            return humanSize(free)
        }
        return "—"
    }
}

/// File icons are surprisingly slow to fetch (several ms each, more for .app bundles); rows ask for them on every
/// re-render, so cache them. Plain files share one icon per extension; folders, packages and apps are keyed by path.
enum IconCache {
    private static let cache = NSCache<NSString, NSImage>()
    static func icon(forPath path: String, isDirectory: Bool, isPackage: Bool, ext: String) -> NSImage {
        let key: NSString = (isDirectory || isPackage || ext.isEmpty) ? path as NSString : ("ext:" + ext) as NSString
        if let img = cache.object(forKey: key) { return img }
        let img = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(img, forKey: key)
        return img
    }
}
