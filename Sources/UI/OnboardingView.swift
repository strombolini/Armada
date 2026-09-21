import SwiftUI
import AppKit

/// One window, every setup step with a live check mark, shown on first launch and from the menu bar. Nothing here
/// is required to *start* using Jev; each row explains what it unlocks.
struct OnboardingView: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var reach = Reachability.shared
    @State private var keyDraft = Settings.shared.apiKey
    @State private var keyStatus: (ok: Bool?, text: String) = (nil, "")
    @State private var fda = Permissions.hasFullDiskAccess
    @State private var ax = FinderSearchBridge.isTrusted
    @State private var spotlightOff = !HotKeyCenter.spotlightOwnsCommandSpace()
    @State private var login = AppDelegate.shared?.launchAtLogin ?? false
    private let tick = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Armada").font(.title2.weight(.semibold))
                    Text("⌘ Space, describe a file.").foregroundStyle(.secondary)
                }
            }

            row(done: keyStatus.ok == true || (!settings.apiKey.isEmpty && keyStatus.ok == nil && reach.isOnline),
                title: "Codiv API key", detail: "Free at codiv.ai.") {
                HStack {
                    SecureField("sk-codiv-…", text: $keyDraft).textFieldStyle(.roundedBorder).frame(width: 260)
                    Button("Save") { saveAndTest() }.disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    Link("Get a key", destination: URL(string: "https://codiv.ai/signup")!)
                }
                if !keyStatus.text.isEmpty { Text(keyStatus.text).font(.caption).foregroundStyle(keyStatus.ok == true ? .green : .orange) }
            }

            row(done: fda, title: "Full Disk Access", detail: "Turn on Armada.") {
                HStack {
                    Button("Open Settings") { Permissions.openFullDiskAccessSettings(); revealApp() }
                    Text("Not listed? Click + and pick it.").font(.caption).foregroundStyle(.secondary)
                }
            }

            row(done: spotlightOff || settings.hotkey != .cmdSpace, title: "⌘ Space is Armada's",
                detail: spotlightOff ? "Spotlight shortcut off." : "Spotlight shortcut still on.") {
                if !spotlightOff && settings.hotkey == .cmdSpace { Button("Turn off") { SpotlightShortcut.setEnabled(false); spotlightOff = !HotKeyCenter.spotlightOwnsCommandSpace() } }
            }

            row(done: ax, title: "Accessibility", detail: "Armada in Finder and file panels.") {
                if !ax { Button("Open Settings") { FinderSearchBridge.requestTrust(); Permissions.openAccessibilitySettings() } }
            }

            row(done: login, title: "Launch at login", detail: "Always on.") {
                if !login { Button("Enable") { AppDelegate.shared.setLaunchAtLogin(true); login = AppDelegate.shared.launchAtLogin } }
            }

            HStack {
                Text("Menu bar icon › Setup checklist to reopen.").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { onDone() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 640)
        .onReceive(tick) { _ in
            fda = Permissions.hasFullDiskAccess
            if ax != FinderSearchBridge.isTrusted { ax = FinderSearchBridge.isTrusted; FinderSearchBridge.shared.start() }
            spotlightOff = !HotKeyCenter.spotlightOwnsCommandSpace(); login = AppDelegate.shared?.launchAtLogin ?? false
        }
        .onAppear { if !settings.apiKey.isEmpty { test() } }
    }

    @ViewBuilder
    private func row<Content: View>(done: Bool, title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20)).foregroundStyle(done ? Color.green : Color.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
    }

    private func revealApp() { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Bundle.main.bundlePath)]) }

    private func saveAndTest() {
        settings.apiKey = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        test()
    }

    private func test() {
        keyStatus = (nil, "Testing…")
        Task {
            do {
                let r = try await CodivClient.shared.choices(state: ["ping": "hello"],
                    questions: ["q": CodivClient.Choice(instructions: "Is this a greeting?", criteria: [("yes", "a greeting"), ("no", "not a greeting")])])
                keyStatus = (true, "Works")
            } catch { keyStatus = (false, error.localizedDescription) }
        }
    }
}
