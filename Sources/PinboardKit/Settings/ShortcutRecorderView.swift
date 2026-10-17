import AppKit
import Carbon
import SwiftUI

/// Click-to-record shortcut field for Settings. Captures the next key press
/// (modifiers + key) and reports it; Esc cancels, Delete/Backspace clears.
final class ShortcutRecorderView: NSView {
    var shortcut: HotKeyManager.Shortcut? {
        didSet { needsDisplay = true }
    }
    /// nil means the user cleared the shortcut.
    var onRecord: ((HotKeyManager.Shortcut?) -> Void)?

    private(set) var isRecording = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 150, height: 24))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }

    override func mouseDown(with event: NSEvent) {
        isRecording = true
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        if event.keyCode == 53 /* Esc */ {
            isRecording = false
            needsDisplay = true
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 /* Delete */ {
            isRecording = false
            onRecord?(nil)
            needsDisplay = true
            return
        }
        var carbon: UInt32 = 0
        if event.modifierFlags.contains(.command) { carbon |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.option) { carbon |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { carbon |= UInt32(controlKey) }
        let candidate = HotKeyManager.Shortcut(keyCode: UInt32(event.keyCode), carbonModifiers: carbon)
        guard candidate.hasRequiredModifier else {
            NSSound.beep() // a bare key would break normal typing in every app
            return
        }
        isRecording = false
        onRecord?(candidate)
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let text = isRecording ? "Type shortcut…" : (shortcut?.displayString ?? "Not Set")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: shortcut == nil && !isRecording ? NSColor.secondaryLabelColor : NSColor.labelColor
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                  withAttributes: attributes)
    }
}

/// SwiftUI shell for `ShortcutRecorderView`.
struct ShortcutRecorder: NSViewRepresentable {
    var shortcut: HotKeyManager.Shortcut?
    var onRecord: (HotKeyManager.Shortcut?) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.onRecord = onRecord
        return view
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.shortcut = shortcut
        view.onRecord = onRecord
    }
}
