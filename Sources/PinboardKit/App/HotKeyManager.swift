import AppKit
import Carbon

/// Global hotkey (`⌃⌥⇧⌘P` by default) via Carbon `RegisterEventHotKey` —
/// works while the app sits in the background and needs no accessibility
/// permission. Re-registering is immediate; settings persist in `Preferences`.
final class HotKeyManager {
    struct Shortcut: Equatable {
        var keyCode: UInt32
        /// Carbon modifier mask (cmdKey | shiftKey | optionKey | controlKey).
        var carbonModifiers: UInt32
    }

    static let shared = HotKeyManager()
    static let defaultShortcut = Shortcut(
        keyCode: Preferences.defaultHotkeyKeyCode,
        carbonModifiers: Preferences.defaultHotkeyModifiers
    )

    var onTrigger: (() -> Void)?
    private(set) var current: Shortcut?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static let hotKeyID = EventHotKeyID(signature: OSType(0x50424B48 /* 'PBKH' */), id: 1)

    private init() {
        onTrigger = { URLCommandRouter.perform(.paste, manager: .shared) }
    }

    /// Re-reads `Preferences` and (re)registers. Call at launch and whenever
    /// the hotkey settings change.
    @discardableResult
    func applyFromPreferences() -> Bool {
        let preferences = Preferences.shared
        guard preferences.hotkeyEnabled else {
            if current != nil { unregister() }
            return true
        }
        let shortcut = Shortcut(keyCode: preferences.hotkeyKeyCode,
                                carbonModifiers: preferences.hotkeyModifiers)
        guard shortcut != current else { return true } // nothing to re-register
        return register(shortcut)
    }

    /// Registers a global shortcut. Returns false when the system refuses it
    /// (already taken by another app or system-reserved) — callers must show
    /// that as a failure, not a success.
    @discardableResult
    func register(_ shortcut: Shortcut) -> Bool {
        guard shortcut != current else { return true }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            HotKeyManager.hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return false }
        // Keep the existing binding live until its replacement is secured.
        // Settings retains the old shortcut when registration fails.
        unregister()
        hotKeyRef = ref
        current = shortcut
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        current = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                if hotKeyID.signature == HotKeyManager.hotKeyID.signature,
                   hotKeyID.id == HotKeyManager.hotKeyID.id {
                    DispatchQueue.main.async { HotKeyManager.shared.onTrigger?() }
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &handlerRef
        )
    }
}

extension HotKeyManager.Shortcut {
    /// Human-readable form like `⌃⌥⇧⌘P`.
    var displayString: String {
        var result = ""
        if carbonModifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + (HotKeyManager.keyName(for: keyCode) ?? "?")
    }

    /// True when no real modifier is present — bare letters are rejected as
    /// global shortcuts since they would break normal typing.
    var hasRequiredModifier: Bool {
        carbonModifiers & UInt32(cmdKey | optionKey | shiftKey | controlKey) != 0
    }
}

extension HotKeyManager {
    /// Resolves a virtual key code to its character via the current keyboard
    /// layout, falling back to a static ANSI table when the input source is
    /// unavailable (e.g. a headless test run).
    static func keyName(for keyCode: UInt32) -> String? {
        if let name = translatedKeyName(for: keyCode) { return name }
        return ansiKeyNames[keyCode]
    }

    /// ANSI key names used when the keyboard layout can't be queried.
    private static let ansiKeyNames: [UInt32: String] = {
        var map: [UInt32: String] = [
            0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G",
            0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q",
            0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T", 0x12: "1",
            0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=",
            0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]",
            0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P", 0x25: "L",
            0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";", 0x2A: "\\", 0x2B: ",",
            0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".", 0x32: "`",
            0x24: "↩", 0x30: "⇥", 0x31: "Space", 0x33: "⌫", 0x35: "⎋",
            0x75: "⌦", 0x73: "↖", 0x77: "↘", 0x74: "⇞", 0x79: "⇟",
            0x7B: "←", 0x7C: "→", 0x7E: "↑", 0x7D: "↓",
            0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5",
            0x61: "F6", 0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10",
            0x67: "F11", 0x6F: "F12", 0x69: "F13", 0x6B: "F14", 0x71: "F15",
            0x6A: "F16", 0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20"
        ]
        return map
    }()

    private static func translatedKeyName(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layout = unsafeBitCast(layoutData, to: CFData.self)
        let layoutBytes = unsafeBitCast(CFDataGetBytePtr(layout), to: UnsafePointer<UCKeyboardLayout>.self)
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            layoutBytes,
            UInt16(keyCode),
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}
