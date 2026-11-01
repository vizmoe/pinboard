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

            Section("Pins") {
                Toggle("Place new pins at the pointer", isOn: $preferences.placeNewWindowAtMouse)
                Text("Double-click a pin to copy and close it. Use the pencil or context menu to edit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Text") {
                Picker("Text mode", selection: $preferences.textMode) {
                    ForEach(TextContentMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text("Rich Text Format preserves fonts and colours. GitHub Flavored Markdown renders tables, task lists, links and images; use the pencil to edit its source. Plain Text uses the default font.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Markdown theme", selection: $preferences.markdownTheme) {
                    ForEach(MarkdownTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                MarkdownThemePreview(theme: preferences.markdownTheme)
                Text("The theme colours Markdown pins and their paper. A pin switched to a transparent background keeps it.")
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

/// A small sample of how a theme paints a Markdown pin.
private struct MarkdownThemePreview: View {
    let theme: MarkdownTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Heading")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(nsColor: theme.text))
            HStack(spacing: 0) {
                Text("Body text with a ")
                Text("link").foregroundColor(Color(nsColor: theme.link))
                Text(" and ")
                Text("code")
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: theme.codeBackground)))
            }
            .font(.system(size: 12))
            .foregroundColor(Color(nsColor: theme.text))
            Text("Muted text")
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: theme.secondaryText))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: theme.background ?? .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
    }
}
