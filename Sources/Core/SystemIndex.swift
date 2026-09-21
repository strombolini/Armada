import AppKit

/// Non-file things Spotlight can open: System Settings panes, a few system actions, and a web search. They are
/// matched locally (never sent to Codiv) and appear as rows next to apps and files.
enum SystemIndex {
    struct Pane { let name: String; let keywords: [String]; let id: String }
    struct Action { let name: String; let keywords: [String]; let symbol: String; let confirm: Bool; let run: () -> Void }

    /// Identifiers verified against macOS 26's ExtensionKit bundles; unknown panes fall back to opening System Settings.
    static let panes: [Pane] = [
        Pane(name: "Wi-Fi", keywords: ["wifi", "wireless", "network"], id: "com.apple.wifi-settings-extension"),
        Pane(name: "Bluetooth", keywords: ["airpods", "headphones", "pairing"], id: "com.apple.BluetoothSettings"),
        Pane(name: "Network", keywords: ["ethernet", "vpn", "dns", "proxy"], id: "com.apple.Network-Settings.extension"),
        Pane(name: "Battery", keywords: ["power", "energy", "charging", "low power mode"], id: "com.apple.Battery-Settings.extension"),
        Pane(name: "General", keywords: ["about", "software update", "storage", "airdrop", "login items", "date", "time"], id: "com.apple.General-Settings.extension"),
        Pane(name: "Software Update", keywords: ["update", "upgrade", "macos"], id: "com.apple.Software-Update-Settings.extension"),
        Pane(name: "Storage", keywords: ["disk space", "free up"], id: "com.apple.settings.Storage"),
        Pane(name: "Login Items & Extensions", keywords: ["startup", "launch at login", "extensions"], id: "com.apple.LoginItems-Settings.extension"),
        Pane(name: "Date & Time", keywords: ["clock", "timezone"], id: "com.apple.Date-Time-Settings.extension"),
        Pane(name: "Language & Region", keywords: ["locale", "language"], id: "com.apple.Localization-Settings.extension"),
        Pane(name: "Sharing", keywords: ["screen sharing", "file sharing", "remote login", "hostname"], id: "com.apple.Sharing-Settings.extension"),
        Pane(name: "Time Machine", keywords: ["backup"], id: "com.apple.Time-Machine-Settings.extension"),
        Pane(name: "Startup Disk", keywords: ["boot"], id: "com.apple.Startup-Disk-Settings.extension"),
        Pane(name: "Transfer or Reset", keywords: ["erase", "reset", "migration"], id: "com.apple.Transfer-Reset-Settings.extension"),
        Pane(name: "Appearance", keywords: ["dark mode", "light mode", "accent color", "theme"], id: "com.apple.Appearance-Settings.extension"),
        Pane(name: "Accessibility", keywords: ["voiceover", "zoom", "display", "captions", "hearing"], id: "com.apple.Accessibility-Settings.extension"),
        Pane(name: "Control Center", keywords: ["menu bar", "menubar"], id: "com.apple.ControlCenter-Settings.extension"),
        Pane(name: "Siri", keywords: ["apple intelligence", "assistant"], id: "com.apple.Siri-Settings.extension"),
        Pane(name: "Privacy & Security", keywords: ["privacy", "security", "accessibility", "full disk access", "camera", "microphone", "permissions", "firewall", "filevault"], id: "com.apple.settings.PrivacySecurity.extension"),
        Pane(name: "Desktop & Dock", keywords: ["dock", "stage manager", "hot corners", "mission control", "windows"], id: "com.apple.Desktop-Settings.extension"),
        Pane(name: "Displays", keywords: ["monitor", "resolution", "brightness", "night shift", "true tone", "refresh rate"], id: "com.apple.Displays-Settings.extension"),
        Pane(name: "Wallpaper", keywords: ["background", "desktop picture"], id: "com.apple.Wallpaper-Settings.extension"),
        Pane(name: "Screen Saver", keywords: ["screensaver"], id: "com.apple.ScreenSaver-Settings.extension"),
        Pane(name: "Lock Screen", keywords: ["lock", "sleep", "password after"], id: "com.apple.Lock-Screen-Settings.extension"),
        Pane(name: "Touch ID & Password", keywords: ["fingerprint", "password", "apple watch unlock"], id: "com.apple.Touch-ID-Settings.extension"),
        Pane(name: "Users & Groups", keywords: ["accounts", "user", "guest", "admin"], id: "com.apple.Users-Groups-Settings.extension"),
        Pane(name: "Internet Accounts", keywords: ["mail account", "google account", "icloud", "exchange"], id: "com.apple.Internet-Accounts-Settings.extension"),
        Pane(name: "Game Center", keywords: ["games"], id: "com.apple.Game-Center-Settings.extension"),
        Pane(name: "Wallet & Apple Pay", keywords: ["apple pay", "cards", "payment"], id: "com.apple.Wallet-Settings.extension"),
        Pane(name: "Keyboard", keywords: ["shortcuts", "keyboard shortcuts", "input sources", "text replacement", "dictation", "key repeat"], id: "com.apple.Keyboard-Settings.extension"),
        Pane(name: "Trackpad", keywords: ["gestures", "tap to click", "scroll direction"], id: "com.apple.Trackpad-Settings.extension"),
        Pane(name: "Mouse", keywords: ["tracking speed", "scroll"], id: "com.apple.Mouse-Settings.extension"),
        Pane(name: "Printers & Scanners", keywords: ["printer", "print", "scanner"], id: "com.apple.Print-Scan-Settings.extension"),
        Pane(name: "Sound", keywords: ["volume", "output", "input", "speakers", "microphone", "alert sound"], id: "com.apple.Sound-Settings.extension"),
        Pane(name: "Notifications", keywords: ["alerts", "badges", "banners"], id: "com.apple.Notifications-Settings.extension"),
        Pane(name: "Focus", keywords: ["do not disturb", "dnd"], id: "com.apple.Focus-Settings.extension"),
        Pane(name: "Screen Time", keywords: ["limits", "downtime", "app limits"], id: "com.apple.Screen-Time-Settings.extension"),
        Pane(name: "Spotlight", keywords: ["search", "indexing"], id: "com.apple.Spotlight-Settings.extension"),
        Pane(name: "Profiles", keywords: ["mdm", "configuration profile"], id: "com.apple.Profiles-Settings.extension"),
        Pane(name: "Apple Account", keywords: ["apple id", "icloud", "family sharing", "subscriptions"], id: "com.apple.systempreferences.AppleIDSettings"),
    ]

    static var actions: [Action] = [
        Action(name: "Lock Screen", keywords: ["lock", "lock the screen", "lock mac"], symbol: "lock.fill", confirm: false) { lockScreen() },
        Action(name: "Sleep", keywords: ["sleep mac", "go to sleep", "suspend"], symbol: "moon.zzz.fill", confirm: false) { run("/usr/bin/pmset", ["sleepnow"]) },
        Action(name: "Empty Trash", keywords: ["trash", "bin", "delete trash"], symbol: "trash.fill", confirm: true) { appleScript("tell application \"Finder\" to empty trash") },
        Action(name: "Toggle Dark Mode", keywords: ["dark mode", "light mode", "appearance", "theme"], symbol: "circle.lefthalf.filled", confirm: false) {
            appleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode") },
        Action(name: "Show Hidden Files in Finder", keywords: ["hidden files", "dotfiles", "show hidden"], symbol: "eye", confirm: false) {
            run("/usr/bin/defaults", ["write", "com.apple.finder", "AppleShowAllFiles", "-bool", "true"]); run("/usr/bin/killall", ["Finder"]) },
        Action(name: "Hide Hidden Files in Finder", keywords: ["hidden files", "hide hidden"], symbol: "eye.slash", confirm: false) {
            run("/usr/bin/defaults", ["write", "com.apple.finder", "AppleShowAllFiles", "-bool", "false"]); run("/usr/bin/killall", ["Finder"]) },
        Action(name: "Eject All Disks", keywords: ["eject", "unmount", "external drive"], symbol: "eject.fill", confirm: false) { appleScript("tell application \"Finder\" to eject (every disk whose ejectable is true)") },
        Action(name: "Restart", keywords: ["reboot", "restart mac"], symbol: "arrow.clockwise.circle.fill", confirm: true) { appleScript("tell application \"System Events\" to restart") },
        Action(name: "Shut Down", keywords: ["shutdown", "power off", "turn off"], symbol: "power.circle.fill", confirm: true) { appleScript("tell application \"System Events\" to shut down") },
        Action(name: "Log Out", keywords: ["logout", "sign out", "log off"], symbol: "rectangle.portrait.and.arrow.right", confirm: true) { appleScript("tell application \"System Events\" to log out") },
    ]

    // MARK: matching

    static func paneMatches(_ query: String, limit: Int = 4) -> [(Pane, Double)] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        let stripped = q.replacingOccurrences(of: "settings", with: "").replacingOccurrences(of: "preferences", with: "").replacingOccurrences(of: "system", with: "").trimmingCharacters(in: .whitespaces)
        guard !stripped.isEmpty else { return [] }
        var out: [(Pane, Double)] = []
        for p in panes {
            let name = p.name.lowercased()
            var s = 0.0
            if name == stripped { s = 0.97 }   // exact pane name beats a prefix-matching app ("bluetooth" → the pane, not Bluetooth File Exchange)
            else if name.hasPrefix(stripped) { s = 0.92 }
            else if name.split(separator: " ").contains(where: { $0.hasPrefix(stripped) }) { s = 0.86 }
            else if p.keywords.contains(where: { $0 == stripped || $0.hasPrefix(stripped) }) { s = 0.84 }
            else if stripped.count >= 4, p.keywords.contains(where: { $0.contains(stripped) }) || name.contains(stripped) { s = 0.7 }
            if s > 0 { out.append((p, s)) }
        }
        return Array(out.sorted { $0.1 > $1.1 }.prefix(limit))
    }

    static func actionMatches(_ query: String, limit: Int = 3) -> [(Action, Double)] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard q.count >= 3 else { return [] }
        var out: [(Action, Double)] = []
        for a in actions {
            let name = a.name.lowercased()
            var s = 0.0
            if name == q { s = 0.96 }
            else if name.hasPrefix(q) { s = 0.9 }
            else if a.keywords.contains(where: { $0 == q || $0.hasPrefix(q) }) { s = 0.85 }
            else if q.count >= 4, name.contains(q) || a.keywords.contains(where: { $0.contains(q) }) { s = 0.65 }
            if s > 0 { out.append((a, s)) }
        }
        return Array(out.sorted { $0.1 > $1.1 }.prefix(limit))
    }

    // MARK: opening

    static func open(pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:" + pane.id) { NSWorkspace.shared.open(url) }
    }

    @MainActor
    static func perform(_ action: Action) {
        if action.confirm {
            let alert = NSAlert()
            alert.messageText = action.name + "?"
            alert.informativeText = "Armada will \(action.name.lowercased()) now."
            alert.addButton(withTitle: action.name)
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        action.run()
    }

    static func webSearchURL(_ query: String) -> URL? {
        var c = URLComponents(string: "https://www.google.com/search")
        c?.queryItems = [URLQueryItem(name: "q", value: query)]
        return c?.url
    }

    // MARK: helpers

    private static func run(_ path: String, _ args: [String]) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        try? p.run()
    }

    private static func appleScript(_ src: String) {
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
    }

    private static func lockScreen() {
        // The documented way to lock immediately (what ⌃⌘Q does).
        run("/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession", ["-suspend"])
    }
}
