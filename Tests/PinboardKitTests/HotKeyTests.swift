import AppKit
import Carbon
import XCTest
@testable import PinboardKit

final class HotKeyTests: XCTestCase {
    override func tearDown() {
        HotKeyManager.shared.unregister()
        super.tearDown()
    }

    func testDefaultIsHyperP() {
        let shortcut = HotKeyManager.defaultShortcut
        XCTAssertEqual(shortcut.keyCode, UInt32(kVK_ANSI_P))
        XCTAssertEqual(shortcut.carbonModifiers,
                       UInt32(cmdKey | optionKey | shiftKey | controlKey))
    }

    func testDisplayString() {
        let display = HotKeyManager.defaultShortcut.displayString
        XCTAssertTrue(display.hasPrefix("⌃⌥⇧⌘"), "got \(display)")
        XCTAssertTrue(display.hasSuffix("P"), "got \(display)")
    }

    func testBareKeyIsRejected() {
        let shortcut = HotKeyManager.Shortcut(keyCode: UInt32(kVK_ANSI_P), carbonModifiers: 0)
        XCTAssertFalse(shortcut.hasRequiredModifier)
    }

    func testRegisterUnregister() {
        // Obscure combination, extremely unlikely to be held by anything else.
        let shortcut = HotKeyManager.Shortcut(keyCode: UInt32(kVK_F17),
                                            carbonModifiers: UInt32(cmdKey | optionKey | shiftKey | controlKey))
        XCTAssertTrue(HotKeyManager.shared.register(shortcut), "registration should succeed")
        XCTAssertEqual(HotKeyManager.shared.current, shortcut)
        HotKeyManager.shared.unregister()
        XCTAssertNil(HotKeyManager.shared.current)
    }

    func testReregisterReplacesOldShortcut() {
        let first = HotKeyManager.Shortcut(keyCode: UInt32(kVK_F17),
                                         carbonModifiers: UInt32(cmdKey | optionKey | shiftKey | controlKey))
        let second = HotKeyManager.Shortcut(keyCode: UInt32(kVK_F18),
                                          carbonModifiers: UInt32(cmdKey | optionKey | shiftKey | controlKey))
        XCTAssertTrue(HotKeyManager.shared.register(first))
        XCTAssertTrue(HotKeyManager.shared.register(second),
                      "re-registering must drop the old binding instead of stacking")
        XCTAssertEqual(HotKeyManager.shared.current, second)
    }

    func testPreferencesRoundTrip() {
        let preferences = Preferences.shared
        let previous = (preferences.hotkeyKeyCode, preferences.hotkeyModifiers, preferences.hotkeyEnabled)
        preferences.hotkeyKeyCode = 40 // kVK_ANSI_K
        preferences.hotkeyModifiers = UInt32(cmdKey | shiftKey)
        XCTAssertEqual(preferences.hotkeyKeyCode, 40)
        XCTAssertEqual(preferences.hotkeyModifiers, UInt32(cmdKey | shiftKey))
        preferences.hotkeyKeyCode = previous.0
        preferences.hotkeyModifiers = previous.1
        preferences.hotkeyEnabled = previous.2
    }

    func testDisableUnregisters() {
        let preferences = Preferences.shared
        let wasEnabled = preferences.hotkeyEnabled
        preferences.hotkeyKeyCode = UInt32(kVK_F17)
        preferences.hotkeyModifiers = UInt32(cmdKey | optionKey | shiftKey | controlKey)
        preferences.hotkeyEnabled = true
        XCTAssertTrue(HotKeyManager.shared.applyFromPreferences())
        XCTAssertNotNil(HotKeyManager.shared.current)
        preferences.hotkeyEnabled = false
        XCTAssertTrue(HotKeyManager.shared.applyFromPreferences())
        XCTAssertNil(HotKeyManager.shared.current)
        preferences.hotkeyEnabled = wasEnabled
        preferences.hotkeyKeyCode = Preferences.defaultHotkeyKeyCode
        preferences.hotkeyModifiers = Preferences.defaultHotkeyModifiers
    }
}
