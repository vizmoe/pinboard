import AppKit
import XCTest
@testable import PinboardKit

final class MenuBarControllerTests: XCTestCase {
    private var manager: PinWindowManager { .shared }
    private var controller: MenuBarController!

    override func setUp() {
        super.setUp()
        manager.closeAll()
        controller = MenuBarController(manager: manager, onOpenSettings: {})
    }

    override func tearDown() {
        manager.closeAll()
        manager.historyStore = nil
        manager.onChange = nil
        controller = nil
        super.tearDown()
    }

    private func textPin(_ string: String, mode: TextContentMode = .plainText) -> PinWindowController {
        manager.createPin(content: .text(NSAttributedString(string: string)), textMode: mode)
    }

    private func pinList() throws -> NSMenu {
        controller.menu.delegate?.menuWillOpen?(controller.menu)
        let list = try XCTUnwrap(controller.menu.items.first { $0.title == "Current Pins" }?.submenu)
        XCTAssertNotNil(list.delegate)
        list.delegate?.menuWillOpen?(list)
        return list
    }

    private func actions(for row: NSMenuItem) throws -> NSMenu {
        let actions = try XCTUnwrap(row.submenu)
        XCTAssertNotNil(actions.delegate)
        actions.delegate?.menuWillOpen?(actions)
        return actions
    }

    private func perform(_ title: String, in menu: NSMenu) throws {
        let item = try XCTUnwrap(menu.items.first { $0.title == title })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
    }

    private func imageViews(in view: NSView) -> [NSImageView] {
        (view as? NSImageView).map { [$0] } ?? view.subviews.flatMap { imageViews(in: $0) }
    }

    private func previewImage(in menu: NSMenu) throws -> NSImage {
        let images = menu.items.compactMap(\.view).flatMap { imageViews(in: $0) }
        return try XCTUnwrap(images.first?.image)
    }

    private func bitmap(_ image: NSImage) throws -> NSBitmapImageRep {
        try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.pngData())))
    }

    func testEmptyMenuHasAnExplicitDisabledState() throws {
        let list = try pinList()
        XCTAssertEqual(list.items.map(\.title), ["No Pins"])
        XCTAssertFalse(list.items[0].isEnabled)
        XCTAssertFalse(try XCTUnwrap(controller.menu.items.first { $0.title == "Current Pins" }).isEnabled)
        XCTAssertFalse(try XCTUnwrap(controller.menu.items.first { $0.title == "Close All Pins" }).isEnabled)
    }

    func testListsTextAndImagePinsIncludingHiddenPins() throws {
        let first = textPin("Meeting notes\n  ship the menu")
        let second = manager.createPin(content: .image(TestImage.make(width: 400, height: 200, color: .red)))
        second.hidePin()
        let list = try pinList()
        XCTAssertEqual(list.items.count, 2)
        XCTAssertTrue(list.items[0].title.contains("Meeting notes ship the menu"))
        XCTAssertEqual(list.items[0].representedObject as? UUID, first.id)
        XCTAssertEqual(list.items[1].representedObject as? UUID, second.id)
        XCTAssertTrue(list.items[1].title.contains("Hidden"))
        XCTAssertEqual(list.items[0].state, .on)
        XCTAssertEqual(list.items[1].state, .off)
        let thumbnail = try bitmap(XCTUnwrap(list.items[1].image))
        let pixel = try XCTUnwrap(thumbnail.colorAt(x: thumbnail.pixelsWide / 2,
                                                  y: thumbnail.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(pixel.redComponent, 0.8)
        XCTAssertLessThan(pixel.greenComponent, 0.2)
        XCTAssertFalse(second.isPinVisible, "previewing a hidden pin must not show it")
        _ = try previewImage(in: actions(for: list.items[1]))
        XCTAssertFalse(second.isPinVisible)
    }

    func testShowRestoresOnlyTheSelectedHiddenPin() throws {
        let first = textPin("first")
        let second = textPin("second")
        manager.hideAll()
        let list = try pinList()
        try perform("Show Pin", in: actions(for: list.items[1]))
        XCTAssertFalse(first.isPinVisible)
        XCTAssertTrue(second.isPinVisible)
        XCTAssertEqual(manager.count, 2)
    }

    func testClosePreservesOtherPinsClipboardAndLatestHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory)
        manager.historyStore = store
        let first = textPin("keep")
        let second = textPin("old")
        let recordID = try XCTUnwrap(second.historyRecordID)
        let list = try pinList()
        let actions = try actions(for: list.items[1])
        let view = try XCTUnwrap(second.contentView as? TextPinView)
        view.beginEditing(at: nil)
        view.editableTextView.insertText("latest", replacementRange: NSRange(location: 0, length: 3))
        let clipboardRevision = NSPasteboard.general.changeCount
        try perform("Close Pin", in: actions)
        XCTAssertEqual(manager.pins.map(\.id), [first.id])
        XCTAssertTrue(first.isPinVisible)
        XCTAssertEqual(NSPasteboard.general.changeCount, clipboardRevision)
        XCTAssertEqual(store.record(id: recordID)?.text, "latest")
        XCTAssertEqual(store.records.count, 2)
        XCTAssertEqual(try pinList().items.count, 1)
    }

    func testReopeningRefreshesEditsVisibilityAndMembership() throws {
        let first = textPin("before")
        let list = try pinList()
        XCTAssertTrue(list.items[0].title.contains("before"))
        let view = try XCTUnwrap(first.contentView as? TextPinView)
        view.beginEditing(at: nil)
        view.editableTextView.insertText("after", replacementRange: NSRange(location: 0, length: 6))
        first.hidePin()
        _ = textPin("new")
        controller.menuWillOpen(list)
        XCTAssertEqual(list.items.count, 2)
        XCTAssertTrue(list.items[0].title.contains("after"))
        XCTAssertTrue(list.items[0].title.contains("Hidden"))
        first.closePin()
        controller.menuWillOpen(list)
        XCTAssertEqual(list.items.count, 1)
        XCTAssertTrue(list.items[0].title.contains("new"))
    }

    func testStaleActionsCannotAffectAReplacementPinOrResurrectAClosedPin() throws {
        let pin = textPin("old")
        let stale = try actions(for: pinList().items[0])
        pin.closePin()
        let replacement = textPin("new")
        try perform("Show Pin", in: stale)
        try perform("Close Pin", in: stale)
        XCTAssertEqual(manager.pins.map(\.id), [replacement.id])
        XCTAssertFalse(pin.panel.isVisible)
        controller.menuWillOpen(stale)
        XCTAssertNil(stale.items.first { $0.title == "Close Pin" })
    }

    func testLongUnicodeAndEmptyTextHaveBoundedReadableTitles() throws {
        _ = textPin(String(repeating: "👩🏽‍💻中文 ", count: 100))
        _ = textPin("  \n\t ")
        let list = try pinList()
        XCTAssertLessThan(list.items[0].title.count, 100)
        XCTAssertTrue(list.items[0].title.contains("…"))
        XCTAssertFalse(list.items[0].title.contains("\n"))
        XCTAssertTrue(list.items[1].title.contains("Empty Text"))
    }

    func testTextPreviewReadsLiveEditsWithoutChangingTheEditor() throws {
        let pin = textPin("old", mode: .markdown)
        let view = try XCTUnwrap(pin.contentView as? TextPinView)
        view.beginEditing(at: nil)
        let editor = view.editableTextView
        editor.insertText("# Unsaved heading", replacementRange: NSRange(location: 0, length: 3))
        editor.setSelectedRange(NSRange(location: 2, length: 7))
        let original = NSAttributedString(attributedString: try XCTUnwrap(editor.textStorage))
        let selection = editor.selectedRange()
        let couldUndo = editor.undoManager?.canUndo
        let list = try pinList()
        XCTAssertTrue(list.items[0].title.contains("Unsaved heading"))
        let image = try previewImage(in: actions(for: list.items[0]))
        XCTAssertGreaterThan(image.size.width, 100)
        XCTAssertGreaterThan(image.size.height, 50)
        XCTAssertTrue(view.isEditing)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(editor.undoManager?.canUndo, couldUndo)
        XCTAssertEqual(editor.textStorage, original)
    }

    func testTextPreviewActuallyPaintsTextAndRefreshesAfterEditing() throws {
        let pin = textPin("Readable preview\n第二行文字")
        let view = try XCTUnwrap(pin.contentView as? TextPinView)
        let list = try pinList()
        let menu = try actions(for: list.items[0])
        let original = try previewImage(in: menu)
        let rep = try bitmap(original)
        let paper = try XCTUnwrap(rep.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
        var textPixels = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let color = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let difference = abs(color.redComponent - paper.redComponent)
                    + abs(color.greenComponent - paper.greenComponent)
                    + abs(color.blueComponent - paper.blueComponent)
                if difference > 0.6 { textPixels += 1 }
            }
        }
        XCTAssertGreaterThan(textPixels, 100, "a non-nil but blank bitmap is not a text preview")
        view.beginEditing(at: nil)
        view.editableTextView.insertText("Updated", replacementRange: NSRange(location: 0, length: view.editableTextView.string.utf16.count))
        menu.delegate?.menuWillOpen?(menu)
        XCTAssertNotEqual(try XCTUnwrap(original.pngData()), try XCTUnwrap(previewImage(in: menu).pngData()))
        if let path = ProcessInfo.processInfo.environment["PINBOARD_TEST_ARTIFACTS"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(original.pngData()).write(to: directory.appendingPathComponent("menu-text-preview.png"))
        }
    }

    func testImagePreviewIncludesUncommittedTextWithoutSavingIt() throws {
        let pin = manager.createPin(content: .image(TestImage.make(width: 400, height: 300, color: .white)))
        let view = try XCTUnwrap(pin.contentView as? ImagePinView)
        view.beginAnnotating()
        let canvas = try XCTUnwrap(view.subviews.compactMap { $0 as? AnnotationCanvasView }.first)
        canvas.tool = .text
        canvas.style = AnnotationStyle(colorHex: "#000000", lineWidth: 3, fontSize: 40)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
            location: canvas.convert(NSPoint(x: 35, y: 80), to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: pin.panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: event)
        let field = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextField }.first)
        let list = try pinList()
        let menu = try actions(for: list.items[0])
        let before = try XCTUnwrap(previewImage(in: menu).pngData())
        field.stringValue = "Draft"
        menu.delegate?.menuWillOpen?(menu)
        let after = try XCTUnwrap(previewImage(in: menu).pngData())
        XCTAssertNotEqual(before, after, "the preview must include the draft visible in the pin")
        XCTAssertTrue(view.annotationStore.annotations.isEmpty, "preview must not commit a draft")
        XCTAssertFalse(view.annotationStore.undoManager.canUndo)
        XCTAssertTrue(field.superview === canvas)
        XCTAssertTrue(view.isAnnotating)
    }

    func testImagePreviewIncludesCropAndAnnotationsAtBoundedResolution() throws {
        let pin = manager.createPin(content: .image(TestImage.make(width: 1600, height: 1000, color: .white)))
        let view = try XCTUnwrap(pin.contentView as? ImagePinView)
        view.annotationStore.add(Annotation(tool: .highlight,
            points: [CGPoint(x: 600, y: 300), CGPoint(x: 1000, y: 500)],
            style: AnnotationStyle(colorHex: "#FF0000", lineWidth: 3, fontSize: 18)))
        view.annotationStore.setCrop(CGRect(x: 600, y: 300, width: 400, height: 200))
        pin.hidePin()
        let list = try pinList()
        let image = try previewImage(in: actions(for: list.items[0]))
        let rep = try bitmap(image)
        XCTAssertLessThanOrEqual(rep.pixelsWide, 640)
        XCTAssertLessThanOrEqual(rep.pixelsHigh, 360)
        XCTAssertEqual(image.size.width / image.size.height, 2, accuracy: 0.02)
        let pixel = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2,
                                            y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(pixel.redComponent, pixel.greenComponent + 0.2)
        XCTAssertEqual(view.baseImage.pixelSize, CGSize(width: 1600, height: 1000))
        XCTAssertFalse(pin.isPinVisible)
        XCTAssertEqual(view.annotationStore.annotations.count, 1)
        XCTAssertEqual(view.annotationStore.cropRect, CGRect(x: 600, y: 300, width: 400, height: 200))
    }
}
