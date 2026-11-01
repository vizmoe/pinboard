import AppKit
import XCTest
@testable import PinboardKit

final class MenuBarControllerTests: XCTestCase {
    private var manager: PinWindowManager { .shared }
    private var controller: MenuBarController!
    private var panel: PinsPanelViewController { controller.pinsViewController }

    override func setUp() {
        super.setUp()
        manager.closeAll()
        controller = MenuBarController(manager: manager, onOpenSettings: {})
    }

    override func tearDown() {
        controller.popover.close()
        manager.closeAll()
        manager.historyStore = nil
        manager.onChange = nil
        controller = nil
        super.tearDown()
    }

    private func textPin(_ string: String, mode: TextContentMode = .plainText) -> PinWindowController {
        manager.createPin(content: .text(NSAttributedString(string: string)), textMode: mode)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func button(_ title: String) throws -> NSButton {
        try XCTUnwrap(descendants(panel.view).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == title })
    }

    private func bitmap(_ image: NSImage) throws -> NSBitmapImageRep {
        try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.pngData())))
    }

    func testEmptyStateDisablesBulkActionsWithoutRemovingUtilityButtons() throws {
        panel.reloadPins()
        XCTAssertTrue(panel.rows.isEmpty)
        XCTAssertFalse(descendants(panel.view).contains { $0 is NSTextField && !$0.isHiddenOrHasHiddenAncestor })
        for title in ["Show All", "Hide All", "Close All"] { XCTAssertFalse(try button(title).isEnabled) }
        for title in ["Pin Clipboard", "History", "Settings", "Quit"] { XCTAssertTrue(try button(title).isEnabled) }
    }

    func testActionsShareOneIconStripWithoutShortcutHints() throws {
        panel.reloadPins()
        panel.view.layoutSubtreeIfNeeded()
        let buttons = descendants(panel.view).compactMap { $0 as? NSButton }
        XCTAssertTrue(buttons.allSatisfy { $0.title.isEmpty && $0.keyEquivalent.isEmpty })
        let navigation = try button("Pins")
        let y = navigation.convert(navigation.bounds, to: panel.view).midY
        for title in ["Show All", "Hide All", "Close All", "Settings", "Quit"] {
            let control = try button(title)
            XCTAssertEqual(control.convert(control.bounds, to: panel.view).midY, y, accuracy: 1)
        }
    }

    func testPanelListsVisibleAndHiddenPinsWithImmediateImagePreviews() throws {
        let first = textPin("Meeting notes\n  ship the panel")
        let second = manager.createPin(content: .image(TestImage.make(width: 400, height: 200, color: .red)))
        second.hidePin()
        panel.reloadPins()
        XCTAssertEqual(panel.rows.map(\.pinID), [first.id, second.id])
        XCTAssertEqual(panel.rows[0].titleLabel.stringValue, "Meeting notes ship the panel")
        XCTAssertTrue(panel.rows[0].accessibilityLabel()?.contains("Visible") == true)
        XCTAssertTrue(panel.rows[1].accessibilityLabel()?.contains("Hidden") == true)
        XCTAssertTrue(panel.rows[0].hideButton.isEnabled)
        XCTAssertFalse(panel.rows[1].hideButton.isEnabled)
        let thumbnail = try bitmap(XCTUnwrap(panel.rows[1].previewView.image))
        let pixel = try XCTUnwrap(thumbnail.colorAt(x: thumbnail.pixelsWide / 2,
                                                  y: thumbnail.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(pixel.redComponent, 0.8)
        XCTAssertLessThan(pixel.greenComponent, 0.2)
        XCTAssertFalse(second.isPinVisible, "previewing must not show a hidden pin")
    }

    func testSingleShowAndHideOnlyChangeTheSelectedPin() throws {
        let first = textPin("first")
        let second = textPin("second")
        let frame = second.panel.frame
        manager.hideAll()
        panel.reloadPins()
        let row = panel.rows[1]
        row.showButton.performClick(nil)
        XCTAssertFalse(first.isPinVisible)
        XCTAssertTrue(second.isPinVisible)
        XCTAssertTrue(panel.rows[1].accessibilityLabel()?.contains("Visible") == true)
        XCTAssertTrue(panel.rows[1] === row)
        row.hideButton.performClick(nil)
        XCTAssertFalse(second.isPinVisible)
        XCTAssertFalse(row.hideButton.isEnabled)
        XCTAssertEqual(second.panel.frame, frame)
        XCTAssertEqual(manager.count, 2)
    }

    func testBulkShowHideCloseAndReturnToEmptyState() throws {
        let first = textPin("first")
        let second = textPin("second")
        second.hidePin()
        let identities = manager.pins.map(\.id)
        panel.reloadPins()
        try button("Show All").performClick(nil)
        XCTAssertEqual(manager.visibleCount, 2)
        try button("Hide All").performClick(nil)
        XCTAssertEqual(manager.visibleCount, 0)
        XCTAssertEqual(manager.pins.map(\.id), identities)
        XCTAssertFalse(try button("Hide All").isEnabled)
        XCTAssertTrue(try button("Show All").isEnabled)
        try button("Show All").performClick(nil)
        XCTAssertTrue(first.isPinVisible)
        XCTAssertTrue(second.isPinVisible)
        try button("Close All").performClick(nil)
        XCTAssertEqual(manager.count, 0)
        XCTAssertTrue(panel.rows.isEmpty)
        XCTAssertFalse(try button("Close All").isEnabled)
    }

    func testClosePreservesOtherPinsClipboardAndLatestHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory)
        manager.historyStore = store
        let first = textPin("keep")
        let second = textPin("old")
        let recordID = try XCTUnwrap(second.historyRecordID)
        panel.reloadPins()
        let row = panel.rows[1]
        let text = try XCTUnwrap(second.contentView as? TextPinView)
        text.beginEditing(at: nil)
        text.editableTextView.insertText("latest", replacementRange: NSRange(location: 0, length: 3))
        let clipboardRevision = NSPasteboard.general.changeCount
        row.closeButton.performClick(nil)
        XCTAssertEqual(manager.pins.map(\.id), [first.id])
        XCTAssertTrue(first.isPinVisible)
        XCTAssertEqual(NSPasteboard.general.changeCount, clipboardRevision)
        XCTAssertEqual(store.record(id: recordID)?.text, "latest")
        XCTAssertEqual(store.records.count, 2)
        XCTAssertEqual(panel.rows.map(\.pinID), [first.id])
    }

    func testRefreshUpdatesEditsVisibilityAndMembership() throws {
        let pin = textPin("before")
        panel.reloadPins()
        let row = panel.rows[0]
        let text = try XCTUnwrap(pin.contentView as? TextPinView)
        text.beginEditing(at: nil)
        text.editableTextView.insertText("after", replacementRange: NSRange(location: 0, length: 6))
        pin.hidePin()
        _ = textPin("new")
        panel.reloadPins()
        XCTAssertEqual(panel.rows.count, 2)
        XCTAssertTrue(panel.rows[0] === row)
        XCTAssertEqual(row.titleLabel.stringValue, "after")
        XCTAssertTrue(row.accessibilityLabel()?.contains("Hidden") == true)
        pin.closePin()
        panel.reloadPins()
        XCTAssertEqual(panel.rows.count, 1)
        XCTAssertEqual(panel.rows[0].titleLabel.stringValue, "new")
    }

    func testStaleRowButtonsCannotAffectAReplacementOrResurrectAClosedPin() {
        let pin = textPin("old")
        panel.reloadPins()
        let stale = panel.rows[0]
        pin.closePin()
        let replacement = textPin("new")
        stale.showButton.performClick(nil)
        stale.hideButton.performClick(nil)
        stale.closeButton.performClick(nil)
        XCTAssertEqual(manager.pins.map(\.id), [replacement.id])
        XCTAssertTrue(replacement.isPinVisible)
        XCTAssertFalse(pin.panel.isVisible)
    }

    func testManyPinsScrollWhileActionsStayFixedAndRefreshPreservesOffset() throws {
        for index in 0..<16 { _ = textPin("Pin \(index)") }
        panel.reloadPins()
        let document = try XCTUnwrap(panel.scrollView.documentView)
        XCTAssertEqual(panel.rows.count, 16)
        XCTAssertGreaterThan(document.frame.height, panel.scrollView.contentSize.height)
        XCTAssertLessThanOrEqual(panel.view.frame.height, 640)
        panel.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 240))
        panel.scrollView.reflectScrolledClipView(panel.scrollView.contentView)
        let bulk = try button("Close All")
        let before = bulk.convert(bulk.bounds, to: panel.view)
        panel.rows[4].hideButton.performClick(nil)
        XCTAssertEqual(panel.scrollView.contentView.bounds.origin.y, 240, accuracy: 1)
        XCTAssertEqual(bulk.convert(bulk.bounds, to: panel.view), before)
        XCTAssertTrue(panel.rows[4].accessibilityLabel()?.contains("Hidden") == true)
    }

    func testLongUnicodeAndEmptyTextHaveBoundedReadableTitles() {
        _ = textPin(String(repeating: "👩🏽‍💻中文 ", count: 100))
        _ = textPin(" \n\t ")
        panel.reloadPins()
        XCTAssertLessThan(panel.rows[0].titleLabel.stringValue.count, 100)
        XCTAssertTrue(panel.rows[0].titleLabel.stringValue.contains("…"))
        XCTAssertTrue(panel.rows[1].titleLabel.isHidden)
        XCTAssertTrue(panel.rows[1].showButton.accessibilityLabel()?.contains("Empty Text") == true)
    }

    func testTextPreviewReadsLiveEditsWithoutChangingTheEditor() throws {
        let pin = textPin("old", mode: .markdown)
        let text = try XCTUnwrap(pin.contentView as? TextPinView)
        text.beginEditing(at: nil)
        let editor = text.editableTextView
        editor.insertText("# Unsaved heading", replacementRange: NSRange(location: 0, length: 3))
        editor.setSelectedRange(NSRange(location: 2, length: 7))
        let original = NSAttributedString(attributedString: try XCTUnwrap(editor.textStorage))
        let selection = editor.selectedRange()
        let couldUndo = editor.undoManager?.canUndo
        panel.reloadPins()
        XCTAssertTrue(panel.rows[0].titleLabel.stringValue.contains("Unsaved heading"))
        XCTAssertNotNil(panel.rows[0].previewView.image)
        XCTAssertTrue(text.isEditing)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(editor.undoManager?.canUndo, couldUndo)
        XCTAssertEqual(editor.textStorage, original)
    }

    func testTextPreviewActuallyPaintsAndRefreshes() throws {
        let pin = textPin("Readable preview\n第二行文字")
        let text = try XCTUnwrap(pin.contentView as? TextPinView)
        panel.reloadPins()
        let original = try XCTUnwrap(panel.rows[0].previewView.image)
        let rep = try bitmap(original)
        let paper = try XCTUnwrap(rep.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
        var textPixels = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let color = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let difference = abs(color.redComponent - paper.redComponent)
                    + abs(color.greenComponent - paper.greenComponent) + abs(color.blueComponent - paper.blueComponent)
                if difference > 0.6 { textPixels += 1 }
            }
        }
        XCTAssertGreaterThan(textPixels, 100)
        text.beginEditing(at: nil)
        text.editableTextView.insertText("Updated", replacementRange: NSRange(location: 0, length: text.editableTextView.string.utf16.count))
        panel.reloadPins()
        XCTAssertNotEqual(original.pngData(), panel.rows[0].previewView.image?.pngData())
    }

    func testImagePreviewIncludesUncommittedTextWithoutSavingIt() throws {
        let pin = manager.createPin(content: .image(TestImage.make(width: 400, height: 300, color: .white)))
        let image = try XCTUnwrap(pin.contentView as? ImagePinView)
        image.beginAnnotating()
        let canvas = try XCTUnwrap(image.subviews.compactMap { $0 as? AnnotationCanvasView }.first)
        canvas.tool = .text
        canvas.style = AnnotationStyle(colorHex: "#000000", lineWidth: 3, fontSize: 40)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
            location: canvas.convert(NSPoint(x: 35, y: 80), to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: pin.panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: event)
        let field = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextField }.first)
        panel.reloadPins()
        let before = try XCTUnwrap(panel.rows[0].previewView.image?.pngData())
        field.stringValue = "Draft"
        panel.reloadPins()
        XCTAssertNotEqual(before, panel.rows[0].previewView.image?.pngData())
        XCTAssertTrue(image.annotationStore.annotations.isEmpty)
        XCTAssertFalse(image.annotationStore.undoManager.canUndo)
        XCTAssertTrue(field.superview === canvas)
        XCTAssertTrue(image.isAnnotating)
    }

    func testImagePreviewIncludesCropAndAnnotationsAtBoundedResolution() throws {
        let pin = manager.createPin(content: .image(TestImage.make(width: 1600, height: 1000, color: .white)))
        let image = try XCTUnwrap(pin.contentView as? ImagePinView)
        image.annotationStore.add(Annotation(tool: .highlight,
            points: [CGPoint(x: 600, y: 300), CGPoint(x: 1000, y: 500)],
            style: AnnotationStyle(colorHex: "#FF0000", lineWidth: 3, fontSize: 18)))
        image.annotationStore.setCrop(CGRect(x: 600, y: 300, width: 400, height: 200))
        pin.hidePin()
        panel.reloadPins()
        let preview = try XCTUnwrap(panel.rows[0].previewView.image)
        let rep = try bitmap(preview)
        XCTAssertLessThanOrEqual(rep.pixelsWide, 640)
        XCTAssertLessThanOrEqual(rep.pixelsHigh, 360)
        XCTAssertEqual(preview.size.width / preview.size.height, 2, accuracy: 0.02)
        let pixel = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(pixel.redComponent, pixel.greenComponent + 0.2)
        XCTAssertEqual(image.baseImage.pixelSize, CGSize(width: 1600, height: 1000))
        XCTAssertFalse(pin.isPinVisible)
        XCTAssertEqual(image.annotationStore.annotations.count, 1)
    }
}
