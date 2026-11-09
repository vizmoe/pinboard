import AppKit

/// Borderless floating panel used for every pin.
///
/// `nonactivatingPanel` + `becomesKeyOnlyIfNeeded` keep the user's current app
/// in front; the panel only takes keyboard focus when a pin explicitly asks for
/// it (entering text edit mode, annotating, ...).
final class PinPanel: NSPanel {
    weak var pinController: PinWindowController?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        tabbingMode = .disallowed
        acceptsMouseMovedEvents = true
        // Pin views manage the pointer explicitly, so AppKit cursor rects
        // (text view I-beam, scrollers, ...) must not compete with them.
        disableCursorRects()
        level = .floating
        collectionBehavior = [.fullScreenAuxiliary]
    }

    override func cancelOperation(_ sender: Any?) {
        pinController?.endEditing()
    }
}
