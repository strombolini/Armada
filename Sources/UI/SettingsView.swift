import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var reach = Reachability.shared
    @ObservedObject var usage = UsageMeter.shared
    @State private var keyDraft = Settings.shared.apiKey
    @State private var testStatus = ""
    @State private var launchAtLogin = AppDelegate.shared?.launchAtLogin ?? false
    @State private var fda = Permissions.hasFullDiskAccess
    @State private var ax = FinderSearchBridge.isTrusted
    @State private var spotlightOn = HotKeyCenter.spotlightOwnsCommandSpace()
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Codiv") {
                SecureField("API key (sk-codiv-…)", text: $keyDraft).onSubmit { save() }
                HStack {
                    Button("Save & Test") { save(); test() }
                    Text(testStatus).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Link("Get a key", destination: URL(string: "https://codiv.ai")!)
                }
                TextField("Base URL", text: $settings.baseURL)
                TextField("Model", text: $settings.model)
                LabeledContent("Status") {
                    Label(reach.isOnline ? "Reachable" : "Unreachable", systemImage: reach.isOnline ? "checkmark.circle.fill" : "wifi.slash")
                        .foregroundStyle(reach.isOnline ? .green : .orange)
                }
                LabeledContent("Usage") { Text(usage.summary).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
            }
            Section("⌘ Space") {
                Picker("Open Armada with", selection: $settings.hotkey) {
                    ForEach(Settings.Hotkey.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Also respond to ⌥ Space", isOn: $settings.alsoOptionSpace)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: spotlightOn ? "exclamationmark.triangle.fill" : "checkmark.circle.fill").foregroundStyle(spotlightOn ? .yellow : .green)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(spotlightOn ? "Spotlight's own ⌘ Space shortcut is still on, so both can pop up." : "Spotlight's ⌘ Space shortcut is off — ⌘ Space is Armada's alone.")
                            .font(.callout.weight(.semibold))
                        HStack {
                            if spotlightOn {
                                Button("Turn off Spotlight's ⌘ Space shortcut") { SpotlightShortcut.setEnabled(false); spotlightOn = HotKeyCenter.spotlightOwnsCommandSpace() }
                            } else {
                                Button("Give ⌘ Space back to Spotlight") { SpotlightShortcut.setEnabled(true); spotlightOn = HotKeyCenter.spotlightOwnsCommandSpace() }
                            }
                            Button("Keyboard Shortcuts…") { AppDelegate.shared.openKeyboardShortcutSettings() }
                        }
                        Text("Spotlight itself keeps working from the menu-bar icon; only the shortcut changes.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onReceive(tick) { _ in spotlightOn = HotKeyCenter.spotlightOwnsCommandSpace() }
            }
            Section("Clipboard history") {
                Toggle("Keep a history of what you copy", isOn: $settings.clipboardEnabled)
                Picker("Open it with", selection: $settings.clipboardHotkey) {
                    ForEach(Settings.ClipboardHotkey.allCases) { Text($0.label).tag($0) }
                }
                Toggle("⏎ pastes into the app you were in (otherwise it just copies)", isOn: $settings.clipboardPasteDirectly)
                if settings.clipboardPasteDirectly && !ax {
                    Text("Pasting needs Accessibility (see below). Until then ⏎ copies and you press ⌘V.").font(.caption).foregroundStyle(.secondary)
                }
                Picker("Keep", selection: $settings.clipboardLimit) {
                    ForEach([100, 300, 1000], id: \.self) { Text("Last \($0) items").tag($0) }
                }
                HStack {
                    Button("Clear history") { ClipboardHistory.shared.clearUnpinned() }
                    Text("Pinned items stay. Password manager copies are never saved, and nothing here is sent to Codiv.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Files") {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: fda ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(fda ? .green : .yellow)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fda ? "Full Disk Access granted — no per-folder prompts." : "Without Full Disk Access, macOS asks for each folder (Desktop, Documents, Downloads, iCloud, external disks) separately.")
                            .font(.callout)
                        if !fda { Button("Grant Full Disk Access…") { AppDelegate.shared.openFullDiskAccess() } }
                    }
                }
                .onReceive(tick) { _ in fda = Permissions.hasFullDiskAccess }
            }
            Section("Finder & Open/Save panels") {
                Toggle("Search with Armada in Finder windows and file panels, scoped to the folder shown", isOn: $settings.finderIntegration)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: ax ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(ax ? .green : .yellow)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ax ? "Accessibility granted — Armada can see the search field you type in." : "Needs Accessibility (to read the search field and the folder). Finder's own results always keep working.")
                            .font(.callout)
                        if !ax { Button("Grant Accessibility…") { FinderSearchBridge.requestTrust(); Permissions.openAccessibilitySettings() } }
                    }
                }
                .onReceive(tick) { _ in ax = FinderSearchBridge.isTrusted }
            }
            Section("Behaviour") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in AppDelegate.shared.setLaunchAtLogin(on) }
                Toggle("Show in Dock", isOn: $settings.showInDock)
                Picker("When Codiv is unreachable", selection: $settings.offlineBehavior) {
                    ForEach(Settings.OfflineBehavior.allCases) { Text($0.label).tag($0) }
                }
                Picker("Search depth", selection: $settings.thoroughness) {
                    ForEach(Settings.Thoroughness.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Send short text previews of candidate files to Codiv (better ranking)", isOn: $settings.sendPreviews)
            }
            Section("Search locations") {
                ForEach(settings.searchRoots, id: \.self) { root in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: root)).resizable().frame(width: 16, height: 16)
                        Text(FileSystem.displayPath(root)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { settings.searchRoots.removeAll { $0 == root } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                    }
                }
                HStack {
                    Button("Add Folder…") { addRoot() }
                    Button("Reset") { settings.searchRoots = Settings.defaultRoots }
                }
                Toggle("Also search external and network volumes", isOn: $settings.searchExternalVolumes)
                Toggle("Offer “Search the web” as the last result", isOn: $settings.webSearchRow)
                Toggle("Show websites from your browsers’ history and bookmarks", isOn: $settings.websiteRows)
                Text("Ignored folder names: " + settings.ignoredNames.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 580, height: 720)
    }

    private func save() { settings.apiKey = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func test() {
        testStatus = "Testing…"
        Task {
            let ok = await Reachability.shared.refresh(force: true)
            if !ok { testStatus = "Cannot reach Codiv"; return }
            do {
                let r = try await CodivClient.shared.choices(state: ["ping": "hello"],
                    questions: ["q": CodivClient.Choice(instructions: "Is this a greeting?", criteria: [("yes", "a greeting"), ("no", "not a greeting")])])
                testStatus = "OK — \(r.model), \(r.latencyMs) ms"
            } catch { testStatus = error.localizedDescription }
        }
    }

    private func addRoot() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
        if p.runModal() == .OK {
            for u in p.urls where !settings.searchRoots.contains(u.path) { settings.searchRoots.append(u.path) }
        }
    }
}
