import AppKit
import XCTest
@testable import PinboardKit

final class ReviewRegressionTests: XCTestCase {
    override func tearDown() {
        PinWindowManager.shared.closeAll()
        Preferences.shared.markdownTheme = .standard
        super.tearDown()
    }

    func testExplicitOpaqueBackgroundTracksThemeAndMode() throws {
        let pin = PinWindowManager.shared.createPin(
            content: .text(NSAttributedString(string: "body")), textMode: .markdown
        )
        pin.setBackgroundVisible(true)
        Preferences.shared.markdownTheme = .everforestDarkHard
        XCTAssertEqual(pin.rootView.effectiveBackgroundColor.hexString, "#272E33")
        let text = try XCTUnwrap(pin.contentView as? TextPinView)
        text.setTextMode(.richText, explicit: true)
        XCTAssertTrue(pin.rootView.drawsBackground)
        XCTAssertNil(pin.rootView.themedBackground)
    }

    func testExportCommitsTheActiveTextAnnotation() throws {
        let pin = PinWindowManager.shared.createPin(content: .image(TestImage.make(width: 400, height: 300)))
        let image = try XCTUnwrap(pin.contentView as? ImagePinView)
        image.beginAnnotating()
        let canvas = try XCTUnwrap(image.subviews.compactMap { $0 as? AnnotationCanvasView }.first)
        canvas.tool = .text
        let location = canvas.convert(NSPoint(x: 40, y: 40), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
            modifierFlags: [], timestamp: 0, windowNumber: pin.panel.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: event)
        let field = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextField }.first)
        field.stringValue = "Latest draft"
        _ = image.renderedImage()
        XCTAssertEqual(image.annotationStore.annotations.first?.text, "Latest draft")
    }

    func testDeletingActiveTextDraftDoesNotBringItBackWhenEditingEnds() throws {
        let pin = PinWindowManager.shared.createPin(content: .image(TestImage.make(width: 400, height: 300)))
        let image = try XCTUnwrap(pin.contentView as? ImagePinView)
        image.beginAnnotating()
        let canvas = try XCTUnwrap(image.subviews.compactMap { $0 as? AnnotationCanvasView }.first)
        canvas.tool = .text
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 40, y: 40),
            modifierFlags: [], timestamp: 0, windowNumber: pin.panel.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: event)
        let field = try XCTUnwrap(canvas.subviews.compactMap { $0 as? NSTextField }.first)
        field.stringValue = "draft"
        canvas.deleteSelection()
        image.endEditing()
        XCTAssertTrue(image.annotationStore.annotations.isEmpty)
    }

    func testCorruptAnnotationsCannotSilentlyBecomeAnUnannotatedRepin() throws {
        let manager = PinWindowManager.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = HistoryStore(directory: directory)
        manager.historyStore = store
        defer {
            manager.historyStore = nil
            manager.onHistoryError = nil
            try? FileManager.default.removeItem(at: directory)
        }
        let id = try store.upsert(content: .image(TestImage.make(width: 100, height: 100)),
                                  annotationData: Data("{broken".utf8))
        var reported = false
        manager.onHistoryError = { _ in reported = true }
        XCTAssertNil(manager.repin(recordID: id))
        XCTAssertTrue(reported)
        XCTAssertEqual(manager.count, 0)
        XCTAssertThrowsError(try AnnotationStore.decode(Data("{}".utf8)))
    }

    func testFreehandSelectionHitsSegmentsBetweenSamples() {
        let stroke = Annotation(tool: .freehand, points: [.zero, CGPoint(x: 200, y: 0)], style: .current())
        XCTAssertTrue(stroke.hitTest(CGPoint(x: 100, y: 1), textSizer: AnnotationRenderer.textSize))
    }

    func testRetentionChangeToDays30PrunesExpiredRecordsAndFocusedPinResolvesFromToolbar() throws {
        let manager = PinWindowManager.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let originalRetention = Preferences.shared.historyRetention
        let originalCustomDays = Preferences.shared.historyCustomDays
        defer {
            manager.closeAll()
            manager.historyStore = nil
            Preferences.shared.historyRetention = originalRetention
            Preferences.shared.historyCustomDays = originalCustomDays
            try? FileManager.default.removeItem(at: directory)
        }

        // Simulate launching with Forever retention, then switching to 30 Days in Settings.
        Preferences.shared.historyRetention = .forever
        Preferences.shared.historyCustomDays = 30
        let delegate = AppDelegate()
        let store = HistoryStore(directory: directory)
        let expiredID = try store.upsert(content: .text(NSAttributedString(string: "Expired")))
        let recordURL = directory.appendingPathComponent(expiredID.uuidString).appendingPathComponent("record.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
        let oldDate = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-40 * 86_400))
        json["updatedAt"] = oldDate
        json["createdAt"] = oldDate
        try JSONSerialization.data(withJSONObject: json).write(to: recordURL)
        let reloaded = HistoryStore(directory: directory)
        manager.historyStore = reloaded

        Preferences.shared.historyRetention = .days30
        delegate.preferencesChanged()
        XCTAssertNil(reloaded.record(id: expiredID),
                     "switching retention from Forever to 30 Days must immediately prune expired records")

        let pin = manager.createPin(content: .text(NSAttributedString(string: "Rich")), textMode: .richText)
        let textView = try XCTUnwrap(pin.contentView as? TextPinView)
        textView.beginEditing(at: nil)
        let toolbarPanel = try XCTUnwrap(textView.formatToolbar?.panel)
        XCTAssertTrue(delegate.focusedPin(for: toolbarPanel) === pin,
                      "Close/Hide Pin shortcuts must resolve the owning pin when its attached toolbar is key")
    }

    func testDirectPinVisibilityChangesNotifyManager() {
        let manager = PinWindowManager.shared
        let pin = manager.createPin(content: .text(NSAttributedString(string: "Visible")))
        var notifications = 0
        manager.onChange = { notifications += 1 }
        defer { manager.onChange = nil }

        pin.hidePin()
        XCTAssertEqual(notifications, 1, "hiding a pin directly must notify the window manager")
        pin.showPin()
        XCTAssertEqual(notifications, 2, "showing a hidden pin directly must notify the window manager")
    }

    func testTextPinUndoIsScopedToEditingAndMarkdownThemeDoesNotDirtyHistory() throws {
        let manager = PinWindowManager.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = HistoryStore(directory: directory)
        manager.historyStore = store
        defer {
            manager.closeAll()
            manager.historyStore = nil
            try? FileManager.default.removeItem(at: directory)
        }

        let png = try XCTUnwrap(HTMLImageSourceTests.makePNG(width: 40, height: 20, color: .systemTeal))
        let source = "# Heading\n\n![chart](data:image/png;base64,\(png.base64EncodedString()))"
        let pin = manager.createPin(content: .text(NSAttributedString(string: source)), textMode: .markdown)
        let recordID = try XCTUnwrap(pin.historyRecordID)
        manager.flushHistorySync(for: pin)
        let initialUpdatedAt = try XCTUnwrap(store.record(id: recordID)?.updatedAt)

        Thread.sleep(forTimeInterval: 0.02)
        Preferences.shared.markdownTheme = .everforestDarkHard
        manager.flushHistorySync(for: pin)
        XCTAssertEqual(store.record(id: recordID)?.updatedAt, initialUpdatedAt,
                       "re-resolving Markdown display images for a theme change must not dirty or rewrite history")

        let view = try XCTUnwrap(pin.contentView as? TextPinView)
        XCTAssertNil(view.pinUndoManager, "idle text pins must not expose an undo manager to the window")
        view.beginEditing(at: nil)
        XCTAssertNotNil(view.pinUndoManager)
        view.editableTextView.insertText(" tail", replacementRange: NSRange(location: view.editableTextView.string.utf16.count, length: 0))
        XCTAssertTrue(view.pinUndoManager?.canUndo == true)

        view.endEditing()
        XCTAssertNil(view.pinUndoManager, "leaving edit mode must stop exposing undo to the window")
        XCTAssertFalse(view.editableTextView.undoManager?.canUndo ?? false,
                       "replacing the editor storage with rendered Markdown must clear stale source-range undo actions")
    }

    func testTextPinResizingAndRepinFitEmbeddedAttachmentBoundsToWrapWidth() throws {
        let manager = PinWindowManager.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = HistoryStore(directory: directory)
        manager.historyStore = store
        defer {
            manager.closeAll()
            manager.historyStore = nil
            try? FileManager.default.removeItem(at: directory)
        }

        let png = try XCTUnwrap(HTMLImageSourceTests.makePNG(width: 400, height: 200, color: .systemBlue))
        let source = "![chart](data:image/png;base64,\(png.base64EncodedString()))"
        let pin = manager.createPin(content: .text(NSAttributedString(string: source)), textMode: .markdown)
        let view = try XCTUnwrap(pin.contentView as? TextPinView)
        view.setTextMode(.richText, explicit: true)
        pin.setFrame(NSRect(x: 100, y: 100, width: 200, height: 180))

        func firstAttachment(in textPin: TextPinView) throws -> NSTextAttachment {
            let storage = try XCTUnwrap(textPin.editableTextView.textStorage)
            var found: NSTextAttachment?
            storage.enumerateAttribute(.attachment, in: storage.fullRange, options: []) { value, _, _ in
                if let attachment = value as? NSTextAttachment { found = attachment }
            }
            return try XCTUnwrap(found)
        }

        let resizedAttachment = try firstAttachment(in: view)
        XCTAssertLessThanOrEqual(resizedAttachment.bounds.width, view.textWrapWidth + 1,
                                 "resizing a text pin narrower must refit embedded image bounds to the new wrap width")
        XCTAssertGreaterThan(resizedAttachment.bounds.width, 100)

        manager.flushHistorySync(for: pin)
        let recordID = try XCTUnwrap(pin.historyRecordID)
        let reloaded = HistoryStore(directory: directory)
        manager.historyStore = reloaded
        let repinned = try XCTUnwrap(manager.repin(recordID: recordID))
        let repinnedView = try XCTUnwrap(repinned.contentView as? TextPinView)
        let restoredAttachment = try firstAttachment(in: repinnedView)
        XCTAssertNotNil(restoredAttachment.image, "RTFD attachments restored from history must hydrate their image")
        XCTAssertLessThanOrEqual(restoredAttachment.bounds.width, repinnedView.textWrapWidth + 1,
                                 "RTFD attachments restored from history must fit the pin's wrap width")
        XCTAssertGreaterThan(restoredAttachment.bounds.width, 100)
    }

    func testExplicitPinAndEditorStatesEnforceInvariants() throws {
        let manager = PinWindowManager.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = HistoryStore(directory: directory)
        manager.historyStore = store
        defer {
            manager.closeAll()
            manager.historyStore = nil
            try? FileManager.default.removeItem(at: directory)
        }

        // 1. PinWindowController.LifecycleState & HistoryState & BackgroundPolicy
        let pin = manager.createPin(content: .text(NSAttributedString(string: "State Machine Test")), textMode: .markdown)
        XCTAssertEqual(pin.lifecycleState, .visible)
        XCTAssertEqual(pin.backgroundPolicy, .automatic)
        let recordID = try XCTUnwrap(pin.historyRecordID)
        XCTAssertEqual(pin.historyState, .tracked(id: recordID, isDirty: false))

        let textView = try XCTUnwrap(pin.contentView as? TextPinView)
        XCTAssertEqual(textView.editingState, .idle)
        XCTAssertEqual(textView.modeBinding, .explicit(.markdown))

        textView.beginEditing(at: nil)
        XCTAssertEqual(textView.editingState, .editing)
        textView.editableTextView.insertText("!", replacementRange: NSRange(location: textView.editableTextView.string.utf16.count, length: 0))
        XCTAssertEqual(pin.historyState, .tracked(id: recordID, isDirty: true))
        manager.flushHistorySync(for: pin)
        XCTAssertEqual(pin.historyState, .tracked(id: recordID, isDirty: false))
        textView.endEditing()
        XCTAssertEqual(textView.editingState, .idle)

        // 2. Closed terminal state prevents resurrected windows
        pin.hidePin()
        XCTAssertEqual(pin.lifecycleState, .hidden)
        pin.closePin()
        XCTAssertEqual(pin.lifecycleState, .closed)
        pin.showPin()
        XCTAssertEqual(pin.lifecycleState, .closed, "closed is a terminal state; showPin() must be a no-op")
        XCTAssertFalse(pin.panel.isVisible)

        // 3. ImagePinView.CropGeometryState, AnnotationCanvasView.EditSession & PinRootView.ZoomBadgeState
        let imgPin = manager.createPin(content: .image(TestImage.make(width: 300, height: 200)))
        imgPin.setFrame(NSRect(x: -5000, y: -5000, width: 300, height: 200))
        XCTAssertFalse(imgPin.rootView.isPointerInside)
        XCTAssertEqual(imgPin.rootView.zoomBadgeState, .hidden)
        imgPin.zoom(by: 1.25)
        if case .transientFeedback = imgPin.rootView.zoomBadgeState {
            // Expected
        } else {
            XCTFail("Expected .transientFeedback after zoom(by:) when pointer is outside")
        }
        imgPin.refreshChrome()
        if case .transientFeedback = imgPin.rootView.zoomBadgeState {
            // Expected: refreshChrome must not cancel the transient hide timer and strand the badge visible
        } else {
            XCTFail("Expected .transientFeedback to survive refreshChrome while pointer is outside")
        }

        let imageView = try XCTUnwrap(imgPin.contentView as? ImagePinView)
        XCTAssertEqual(imageView.cropGeometryState, .uncropped(sourceSize: CGSize(width: 300, height: 200)))
        imageView.beginAnnotating()
        let canvas = try XCTUnwrap(imageView.subviews.compactMap { $0 as? AnnotationCanvasView }.first)
        canvas.cropDraft = CGRect(x: 20, y: 20, width: 100, height: 80)
        if case .cropping(let rect) = canvas.editSession {
            XCTAssertEqual(rect, CGRect(x: 20, y: 20, width: 100, height: 80))
        } else {
            XCTFail("Expected .cropping editSession when cropDraft is active")
        }
        XCTAssertTrue(canvas.hasUncommittedDraft)
        imageView.restoreOriginalImage()
        XCTAssertNil(canvas.cropDraft, "restoreOriginalImage must also clear an unconfirmed cropDraft")
    }

    func testHistoryEscapeStepsBackOneLevelBeforeDismissing() throws {
        let manager = PinWindowManager.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = HistoryStore(directory: directory)
        manager.historyStore = store
        defer {
            manager.closeAll()
            manager.historyStore = nil
            try? FileManager.default.removeItem(at: directory)
        }
        let pin = manager.createPin(content: .text(NSAttributedString(string: "History navigation")))
        let recordID = try XCTUnwrap(pin.historyRecordID)

        let viewModel = HistoryViewModel(store: store, manager: manager)
        let historyVC = HistoryPanelViewController(model: viewModel)
        var dismissed = false
        historyVC.onDismiss = { dismissed = true }
        _ = historyVC.view
        XCTAssertEqual(historyVC.viewState, .list)
        historyVC.requestClear()
        XCTAssertEqual(historyVC.viewState, .confirmingClear)
        historyVC.handleCancelOperation()
        XCTAssertEqual(historyVC.viewState, .list, "Esc in .confirmingClear must cancel confirmation without dismissing popover")
        XCTAssertFalse(dismissed)

        viewModel.selection = recordID
        historyVC.reloadHistory()
        if case .detail(let record, let isReadable) = historyVC.viewState {
            XCTAssertEqual(record.id, recordID)
            XCTAssertTrue(isReadable)
        } else {
            XCTFail("Expected .detail viewState when a record is selected")
        }
        historyVC.handleCancelOperation()
        XCTAssertEqual(historyVC.viewState, .list, "Esc in .detail must return to .list without dismissing popover")
        XCTAssertFalse(dismissed)

        historyVC.handleCancelOperation()
        XCTAssertTrue(dismissed, "Esc in .list must dismiss the popover")
    }

    func testNativeFeelConventions() throws {
        let manager = PinWindowManager.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PinboardNativeFeel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            manager.closeAll()
            manager.historyStore = nil
            try? FileManager.default.removeItem(at: dir)
        }
        let store = HistoryStore(directory: dir)
        manager.historyStore = store

        // 1. Popover root view preserves native NSPopover vibrancy (isOpaque == false)
        let rootView = MenuBarPanelRootView(frame: NSRect(x: 0, y: 0, width: 320, height: 100))
        XCTAssertFalse(rootView.isOpaque, "MenuBarPanelRootView must not paint an opaque background over NSPopover vibrancy")

        // 2. AppMenu includes standard ⌘, Settings item and SettingsWindowController persists frame
        AppMenu.install()
        let appSubmenu = try XCTUnwrap(NSApp.mainMenu?.items.first?.submenu)
        let settingsItem = appSubmenu.items.first { $0.keyEquivalent == "," }
        XCTAssertNotNil(settingsItem, "App menu must expose ⌘, for Settings…")
        let settingsWC = SettingsWindowController()
        settingsWC.show()
        XCTAssertEqual(settingsWC.window?.frameAutosaveName, "PinboardSettingsWindow")
        settingsWC.window?.close()

        // 3. Toast clamps its frame within the active screen's visibleFrame
        let screenBounds = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let clampedTopRight = Toast.clampedFrame(
            size: NSSize(width: 200, height: 36),
            around: NSPoint(x: 1435, y: 895),
            in: screenBounds
        )
        XCTAssertTrue(screenBounds.insetBy(dx: 8, dy: 8).contains(clampedTopRight),
                      "Toast frame near screen corner must be clamped inside the visibleFrame")

        // 4. Keyboard navigation in Pins & History panels (⌘F, Return, Delete) + direct row click
        let pinsVC = PinsPanelViewController(manager: manager)
        var switchedToHistory = false
        pinsVC.onUtilityAction = { if $0 == .history { switchedToHistory = true } }
        _ = pinsVC.view
        let cmdF = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: 0, context: nil, characters: "f", charactersIgnoringModifiers: "f",
            isARepeat: false, keyCode: 3
        ))
        XCTAssertTrue(pinsVC.view.performKeyEquivalent(with: cmdF))
        XCTAssertTrue(switchedToHistory, "⌘F in Pins panel must switch to History search")

        let hiddenPin = manager.createPin(content: .text(NSAttributedString(string: "Click row to present")))
        hiddenPin.hidePin()
        XCTAssertFalse(hiddenPin.isPinVisible)
        pinsVC.reloadPins()
        let rowView = try XCTUnwrap(pinsVC.rows.first)
        let rowClick = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 20, y: 20), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        rowView.mouseDown(with: rowClick)
        XCTAssertTrue(hiddenPin.isPinVisible, "Clicking a PinRowView body outside action buttons must present the pin")

        let recordID = try XCTUnwrap(hiddenPin.historyRecordID)
        let viewModel = HistoryViewModel(store: store, manager: manager)
        let historyVC = HistoryPanelViewController(model: viewModel)
        _ = historyVC.view
        viewModel.selection = recordID
        historyVC.reloadHistory()
        let returnKey = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36
        ))
        XCTAssertTrue(historyVC.handleKeyEquivalent(returnKey), "Return in History detail must re-pin the selected record")
        XCTAssertEqual(manager.count, 2)

        XCTAssertTrue(historyVC.handleKeyEquivalent(cmdF), "⌘F in History detail must return to list search")
        XCTAssertEqual(historyVC.viewState, .list)

        // 5. URLCommandRouter opens local Markdown and image file URLs as pins
        let mdFile = dir.appendingPathComponent("note.md")
        try "# Native File Open\nHello world".write(to: mdFile, atomically: true, encoding: .utf8)
        XCTAssertTrue(URLCommandRouter.handle(mdFile, manager: manager))
        XCTAssertEqual(manager.count, 3)
        XCTAssertEqual((manager.pins.last?.contentView as? TextPinView)?.textMode, .markdown)
    }
}
