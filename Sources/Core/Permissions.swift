import AppKit

/// macOS privacy permissions. Without Full Disk Access, macOS asks separately for Desktop, Documents, Downloads,
/// iCloud Drive, every external volume… One FDA grant replaces all of those prompts (and Spotlight's own index
/// becomes fully visible to `mdfind`).
enum Permissions {
    /// Probes every FDA-protected location. Besides answering the question, each attempt registers the app with
    /// TCC, which is what makes "Armada" show up in the Full Disk Access list (apps that never tried to read
    /// protected data are simply absent from it, and the user would have to add them with "+").
    static var hasFullDiskAccess: Bool {
        let home = NSHomeDirectory()
        var granted = false
        for p in [home + "/Library/Safari/Bookmarks.plist", home + "/Library/Application Support/com.apple.TCC/TCC.db",
                  home + "/Library/Mail", home + "/Library/Messages", home + "/Library/Safari", home + "/Library/HomeKit"] {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if (try? FileManager.default.contentsOfDirectory(atPath: p)) != nil { granted = true }
            } else {
                let fd = open(p, O_RDONLY)
                if fd >= 0 { close(fd); granted = true }
            }
        }
        return granted
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    static func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

}
