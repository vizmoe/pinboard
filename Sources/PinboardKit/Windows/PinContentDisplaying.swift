import AppKit

/// Everything a pin window needs from the view that renders its payload.
/// Keeps window chrome, dragging and resizing independent from text/image logic.
protocol PinContentDisplaying: NSView {
    var pinController: PinWindowController? { get set }

    /// Non-nil locks window resizing to this ratio.
    var contentAspectRatio: CGSize? { get }
    var minimumPinSize: CGSize { get }

    /// Read-only menu presentation; must not commit edits or encode payloads.
    var previewTitle: String { get }
    /// Actual text only; semantic fallback names belong in accessibility/help.
    var menuPreviewText: String? { get }
    func menuPreview(fitting maxSize: CGSize) -> NSImage?

    func idealSize(fitting maxSize: CGSize) -> CGSize
    func currentContent() -> PinContent
    func captureState() -> PinContentState
    @discardableResult func copy(to pasteboard: NSPasteboard) -> Bool
    func endEditing()

    /// Cursor for a point inside the content area. The window owns all cursor
    /// state (cursor rects are disabled) so feedback always matches behaviour.
    func cursor(at point: NSPoint) -> NSCursor

    /// Undo stack to expose to the Edit menu, if the content manages its own.
    var pinUndoManager: UndoManager? { get }

    /// Called when the panel stops being key; text pins leave edit mode,
    /// image pins keep annotating (colour panel, save sheet, ...).
    func handleResignKey()

    /// Corner control shown at the bottom-left of the pin (e.g. Annotate / Edit).
    func editChromeItem() -> ChromeItem?
    /// Corner control shown at the bottom-right of the pin (e.g. Save as PNG / Save as Markdown).
    func saveChromeItem() -> ChromeItem?
    /// Action items merged into the center hover chrome alongside Copy.
    func chromeItems() -> [ChromeItem]
    /// Content-editing actions shown at the top of the pin's context menu.
    func contextMenuItems() -> [NSMenuItem]
    /// Export/save action grouped with Copy in the pin's context menu.
    func saveContextMenuItem() -> NSMenuItem?
    /// Content-specific display or sizing options in the pin's context menu.
    func viewContextMenuItems() -> [NSMenuItem]
}

extension PinContentDisplaying {
    func copyToPasteboard() {
        if !copy(to: .general) { Toast.show("Couldn't copy pin", duration: 3) }
    }

    func captureState() -> PinContentState { PinContentState(content: currentContent()) }
    var contentAspectRatio: CGSize? { nil }
    var minimumPinSize: CGSize { CGSize(width: 120, height: 60) }
    var menuPreviewText: String? { nil }
    func endEditing() {}
    func cursor(at point: NSPoint) -> NSCursor { .openHand }
    var pinUndoManager: UndoManager? { nil }
    func handleResignKey() { endEditing() }
    func editChromeItem() -> ChromeItem? { nil }
    func saveChromeItem() -> ChromeItem? { nil }
    func chromeItems() -> [ChromeItem] { [] }
    func contextMenuItems() -> [NSMenuItem] { [] }
    func saveContextMenuItem() -> NSMenuItem? { nil }
    func viewContextMenuItems() -> [NSMenuItem] { [] }
}
