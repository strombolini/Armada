import Carbon
import AppKit

/// Global hotkeys via Carbon's RegisterEventHotKey (no Accessibility permission needed).
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var installed = false

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            HotKeyCenter.shared.handlers[hk.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Registers a hotkey. Returns an id usable with `unregister`, or nil if the combo could not be registered.
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> UInt32? {
        installHandlerIfNeeded()
        let id = nextID; nextID += 1
        var ref: EventHotKeyRef?
        let hk = EventHotKeyID(signature: OSType(0x4A455646) /* 'JEVF' */, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hk, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        handlers[id] = handler
        refs[id] = ref
        return id
    }

    func unregisterAll() {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll(); handlers.removeAll()
    }

    static func modifiers(for hk: Settings.Hotkey) -> UInt32 {
        switch hk {
        case .cmdSpace: return UInt32(cmdKey)
        case .optSpace: return UInt32(optionKey)
        case .ctrlSpace: return UInt32(controlKey)
        case .cmdShiftSpace: return UInt32(cmdKey | shiftKey)
        }
    }

    static func modifiers(for hk: Settings.ClipboardHotkey) -> UInt32? {
        switch hk {
        case .cmdShiftV: return UInt32(cmdKey | shiftKey)
        case .optCmdV: return UInt32(optionKey | cmdKey)
        case .ctrlCmdV: return UInt32(controlKey | cmdKey)
        case .off: return nil
        }
    }

    /// Whether Spotlight still owns ⌘Space (System Settings › Keyboard › Keyboard Shortcuts › Spotlight).
    static func spotlightOwnsCommandSpace() -> Bool {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Preferences/com.apple.symbolichotkeys.plist")
        guard let data = try? Data(contentsOf: url),
              let root = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let dict = root["AppleSymbolicHotKeys"] as? [String: Any],
              let entry = dict["64"] as? [String: Any] else { return true }   // untouched defaults = Spotlight enabled
        if let enabled = entry["enabled"] as? Bool { return enabled }
        if let enabled = entry["enabled"] as? Int { return enabled != 0 }
        return true
    }
}

/// Spotlight's own ⌘ Space shortcut (symbolic hotkey 64). Jev wins while it runs, but Spotlight still flashes;
/// the user can turn it off from Jev's Settings with one click instead of digging through System Settings.
enum SpotlightShortcut {
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        let plist = """
        <dict><key>enabled</key><\(enabled ? "true" : "false")/><key>value</key><dict><key>parameters</key><array>\
        <integer>32</integer><integer>49</integer><integer>1048576</integer></array><key>type</key><string>standard</string></dict></dict>
        """
        let write = Process()
        write.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        write.arguments = ["write", "com.apple.symbolichotkeys", "AppleSymbolicHotKeys", "-dict-add", "64", plist]
        do { try write.run(); write.waitUntilExit() } catch { return false }
        guard write.terminationStatus == 0 else { return false }
        // Tell the system to reload the shortcut table without logging out.
        let activate = Process()
        activate.executableURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings")
        activate.arguments = ["-u"]
        try? activate.run(); activate.waitUntilExit()
        UserDefaults(suiteName: "com.apple.symbolichotkeys")?.synchronize()
        return true
    }
}
