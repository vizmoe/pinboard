import AppKit

/// Everything a pin window needs from the view that renders its payload.
/// Keeps window chrome, dragging and resizing independent from text/image logic.
protocol PinContentDisplaying: NSView {
    var pinController: PinWindowController? { get set }

    /// Non-nil locks window resizing to this ratio.
    var contentAspectRatio: CGSize? { get }
    var minimumPinSize: CGSize { get }

    func idealSize(fitting maxSize: CGSize) -> CGSize
    func currentContent() -> PinContent
    func copyToPasteboard()
    func endEditing()

    /// Cursor for a point inside the content area. The window owns all cursor
    /// state (cursor rects are disabled) so feedback always matches behaviour.
    func cursor(at point: NSPoint) -> NSCursor

    /// Undo stack to expose to the Edit menu, if the content manages its own.
    var pinUndoManager: UndoManager? { get }

    /// Called when the panel stops being key; text pins leave edit mode,
    /// image pins keep annotating (colour panel, save sheet, ...).
    func handleResignKey()

    /// Items merged into the hover chrome, left of the close button.
    func chromeItems() -> [ChromeItem]
    func contextMenuItems() -> [NSMenuItem]
}

extension PinContentDisplaying {
    var contentAspectRatio: CGSize? { nil }
    var minimumPinSize: CGSize { CGSize(width: 120, height: 60) }
    func endEditing() {}
    func cursor(at point: NSPoint) -> NSCursor { .openHand }
    var pinUndoManager: UndoManager? { nil }
    func handleResignKey() { endEditing() }
    func chromeItems() -> [ChromeItem] { [] }
    func contextMenuItems() -> [NSMenuItem] { [] }
}
