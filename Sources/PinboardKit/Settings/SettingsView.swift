import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @State private var hotkeyError: String?

    /// nil means "Not Set" — a cleared shortcut is simply a disabled one.
    private var currentShortcut: HotKeyManager.Shortcut? {
        guard preferences.hotkeyEnabled else { return nil }
        return HotKeyManager.Shortcut(keyCode: preferences.hotkeyKeyCode,
                                      carbonModifiers: preferences.hotkeyModifiers)
    }

    var body: some View {
        Form {
            Section("Keyboard Shortcuts") {
                HStack {
                    Text("Pin clipboard")
                    Spacer()
                    ShortcutRecorder(shortcut: currentShortcut) { apply($0) }
                        .frame(width: 150, height: 24)
                    Button("Reset to Default") { apply(HotKeyManager.defaultShortcut) }
                        .controlSize(.small)
                }
                if let hotkeyError {
                    Text(hotkeyError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Text") {
                Picker("Text mode", selection: $preferences.textMode) {
                    ForEach(TextContentMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text("Rich Text preserves fonts and colours. Plain Text drops formatting and uses the default font. Markdown renders headings, lists, quotes and code; click a pin to edit its source.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("History") {
                Picker("Keep history for", selection: $preferences.historyRetention) {
                    ForEach(Preferences.HistoryRetention.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                if preferences.historyRetention == .custom {
                    Stepper(value: $preferences.historyCustomDays, in: 1...365, step: 1) {
                        Text("\(Int(preferences.historyCustomDays)) days")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Registers the shortcut first; preferences only update on success so a
    /// conflict can never leave Settings claiming the shortcut is active.
    /// `nil` clears the binding (and unregisters it) — that's the disable path.
    private func apply(_ shortcut: HotKeyManager.Shortcut?) {
        guard let shortcut else {
            preferences.hotkeyEnabled = false
            hotkeyError = nil
            return
        }
        if HotKeyManager.shared.register(shortcut) {
            preferences.hotkeyKeyCode = shortcut.keyCode
            preferences.hotkeyModifiers = shortcut.carbonModifiers
            preferences.hotkeyEnabled = true
            hotkeyError = nil
        } else {
            hotkeyError = "\"\(shortcut.displayString)\" is already in use. Pick another combination."
        }
    }
}
