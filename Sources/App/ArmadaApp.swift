import SwiftUI
import AppKit

struct ArmadaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject private var reach = Reachability.shared

    var body: some Scene {
        MenuBarExtra {
            Button("Open Armada") { delegate.showPanel() }
                .keyboardShortcut("j", modifiers: [.command, .option])
            Text(reach.isOnline ? "Codiv: reachable" : "Codiv: unreachable — falling back to Finder")
            if delegate.spotlightConflict {
                Button("Spotlight also opens on ⌘ Space — turn its shortcut off") { SpotlightShortcut.setEnabled(false) }
            }
            Button(Permissions.hasFullDiskAccess ? "Setup checklist…" : "Setup checklist (Full Disk Access pending)…") { delegate.openOnboarding() }
            Divider()
            Button("Settings…") { delegate.openSettings() }.keyboardShortcut(",", modifiers: .command)
            Divider()
            Button("Quit Armada") { delegate.quit() }.keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(systemName: "sparkle.magnifyingglass")
        }

        SwiftUI.Settings { SettingsView() }
            .commands {
                CommandGroup(replacing: .appTermination) {
                    // ⌘Q while the panel is up just hides it; the agent keeps running (quit from the menu bar icon).
                    Button("Hide Armada") { delegate.hidePanel() }.keyboardShortcut("q", modifiers: .command)
                }
                CommandGroup(replacing: .newItem) {
                    Button("Armada") { delegate.showPanel() }.keyboardShortcut("f", modifiers: .command)
                    Button("Close") { delegate.hidePanel() }.keyboardShortcut("w", modifiers: .command)
                }
            }
    }
}
