import AppKit
import XCTest
@testable import PinboardKit

final class URLCommandRouterTests: XCTestCase {
    func testParsesHostAndPathForms() {
        XCTAssertEqual(PinboardCommand(rawValue: "paste"), .paste)
        XCTAssertFalse(URLCommandRouter.handle(URL(string: "pinboard://unknown")!))
        XCTAssertFalse(URLCommandRouter.handle(URL(string: "other://paste")!))
    }
}

final class PinWindowManagerTests: XCTestCase {
    private var manager: PinWindowManager { PinWindowManager.shared }

    override func tearDown() {
        manager.closeAll()
        super.tearDown()
    }

    private func textContent(_ string: String = "pin") -> PinContent {
        .text(NSAttributedString(string: string, attributes: ClipboardReader.defaultTextAttributes()))
    }

    func testCreateHideShowKeepsWindowsAlive() {
        let first = manager.createPin(content: textContent("第一个"))
        let second = manager.createPin(content: textContent("第二个"))
        XCTAssertEqual(manager.count, 2)
        XCTAssertEqual(manager.visibleCount, 2)

        let frame = first.panel.frame
        manager.hideAll()
        XCTAssertEqual(manager.count, 2, "hiding must not destroy pins")
        XCTAssertEqual(manager.visibleCount, 0)

        manager.showAll()
        XCTAssertEqual(manager.visibleCount, 2)
        XCTAssertEqual(first.panel.frame, frame, "frames survive hide/show")
        XCTAssertEqual(second.contentView.currentContent().kind, .text)
    }

    func testToggleSemantics() {
        manager.closeAll()
        manager.toggleAll()
        XCTAssertEqual(manager.count, 0, "toggle with no pins must not create one")

        manager.createPin(content: textContent())
        manager.toggleAll()
        XCTAssertEqual(manager.visibleCount, 0)
        manager.toggleAll()
        XCTAssertEqual(manager.visibleCount, 1)

        manager.hideAll()
        manager.hideAll()
        XCTAssertEqual(manager.visibleCount, 0, "repeated hide is stable")
        manager.showAll()
        manager.showAll()
        XCTAssertEqual(manager.visibleCount, 1, "repeated show is stable")
    }

    func testPinsAreIndependent() {
        let first = manager.createPin(content: textContent("A"))
        let second = manager.createPin(content: textContent("B"))
        first.hidePin()
        XCTAssertFalse(first.isPinVisible)
        XCTAssertTrue(second.isPinVisible)
        XCTAssertNotEqual(first.id, second.id)
        second.setFrame(NSRect(x: first.panel.frame.minX + 30, y: first.panel.frame.minY,
                               width: second.panel.frame.width, height: second.panel.frame.height))
        XCTAssertNotEqual(first.panel.frame.origin, second.panel.frame.origin, "pins move independently")

        first.closePin()
        XCTAssertEqual(manager.count, 1)
        XCTAssertTrue(second.isPinVisible)
    }

    func testTextPinUsesOpaqueBackgroundByDefaultWithoutToggleMenuItem() throws {
        let pin = manager.createPin(content: textContent("不透明背景"))
        let view = try XCTUnwrap(pin.contentView as? TextPinView)
        XCTAssertTrue(pin.rootView.drawsBackground)
        XCTAssertTrue(pin.rootView.drawsBorder)
        XCTAssertEqual(pin.panel.hasShadow, Preferences.shared.showShadow)
        XCTAssertTrue(view.isFullyTransparent, "text view stack lets rootView paint the paper")

        let titles = pin.makeContextMenu().items.map(\.title)
        XCTAssertFalse(titles.contains("Use Transparent Background"))
        XCTAssertFalse(titles.contains("Use Opaque Background"))
    }

    func testImagePinKeepsItsShadow() {
        let pin = manager.createPin(content: .image(TestImage.make(width: 100, height: 80)))
        XCTAssertEqual(pin.panel.hasShadow, Preferences.shared.showShadow)
    }

    func testExplicitTextBackgroundAttributesSurvive() throws {
        let highlighted = NSAttributedString(string: "高亮文字", attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .backgroundColor: NSColor.systemYellow
        ])
        let pin = manager.createPin(content: .text(highlighted))
        guard case .text(let stored) = pin.contentView.currentContent() else {
            return XCTFail("expected text content")
        }
        let background = stored.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertNotNil(background, "window transparency must not strip text attributes")
    }

    func testOpacityIsPerPinAndSnapshotted() throws {
        let first = manager.createPin(content: textContent("one"))
        let second = manager.createPin(content: textContent("two"))
        XCTAssertEqual(first.panel.alphaValue, 1.0, accuracy: 0.001, "new pins start fully opaque")

        first.opacity = 0.4
        XCTAssertEqual(first.panel.alphaValue, 0.4, accuracy: 0.001)
        XCTAssertEqual(second.panel.alphaValue, 1.0, accuracy: 0.001,
                       "one pin's opacity must not affect another")

        let snapshot = first.snapshot()
        XCTAssertEqual(snapshot.opacity, 0.4, accuracy: 0.001)

        // Preference changes must not stomp the per-pin value.
        first.applyPreferences()
        XCTAssertEqual(first.panel.alphaValue, 0.4, accuracy: 0.001)
    }

    func testTextPinKeepsRichTextThroughSnapshot() throws {
        let attributed = NSMutableAttributedString(string: "粗体", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 22),
            .foregroundColor: NSColor.systemGreen
        ])
        attributed.append(NSAttributedString(string: "普通", attributes: [.font: NSFont.systemFont(ofSize: 12)]))

        let pin = manager.createPin(content: .text(attributed))
        let snapshot = pin.snapshot()
        XCTAssertEqual(snapshot.kind, .text)
        XCTAssertNotNil(snapshot.rtfData)

        guard case .text(let restored)? = snapshot.makeContent() else {
            return XCTFail("snapshot must restore rich text")
        }
        XCTAssertEqual(restored.string, "粗体普通")
        let font = restored.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, 22)
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
    }

    func testImagePinSizesForRetinaAndExportsFullResolution() throws {
        let pixels = CGSize(width: 1200, height: 800)
        let data = try XCTUnwrap(TestImage.make(width: 1200, height: 800).pngData())
        let fromPasteboard = try XCTUnwrap(NSImage(data: data))
        XCTAssertEqual(fromPasteboard.pixelSize.width, pixels.width, accuracy: 0.5)

        let pin = manager.createPin(content: .image(fromPasteboard))
        let view = try XCTUnwrap(pin.contentView as? ImagePinView)
        let scale = (pin.panel.screen ?? NSScreen.underMouse)?.backingScaleFactor ?? 2
        XCTAssertEqual(view.naturalPointSize.width, pixels.width / scale, accuracy: 1)

        pin.setFrame(NSRect(x: 100, y: 100, width: 320, height: 90))
        let exported = view.renderedImage()
        XCTAssertEqual(exported.pixelSize.width, pixels.width, accuracy: 1, "export keeps original pixels")
        XCTAssertEqual(exported.pixelSize.height, pixels.height, accuracy: 1)
    }

    func testFreeResizeIsNotConstrainedByImageRatio() throws {
        let pin = manager.createPin(content: .image(TestImage.make(width: 400, height: 400)))
        XCTAssertFalse(pin.isAspectLocked, "aspect lock is opt-in")
        pin.setFrame(NSRect(x: 0, y: 0, width: 500, height: 120))
        XCTAssertEqual(pin.panel.frame.width, 500)
        XCTAssertEqual(pin.panel.frame.height, 120)
    }

    func testZoomScalesUniformlyAroundCentre() {
        let pin = manager.createPin(content: .image(TestImage.make(width: 600, height: 400)))
        pin.setFrame(NSRect(x: 200, y: 200, width: 300, height: 200))
        let centre = CGPoint(x: pin.panel.frame.midX, y: pin.panel.frame.midY)
        pin.zoom(by: 1.5)
        XCTAssertEqual(pin.panel.frame.width / pin.panel.frame.height, 1.5, accuracy: 0.02)
        XCTAssertEqual(pin.panel.frame.midX, centre.x, accuracy: 1)
        XCTAssertEqual(pin.panel.frame.midY, centre.y, accuracy: 1)

        pin.zoom(by: 0.0001)
        XCTAssertGreaterThanOrEqual(pin.panel.frame.width, pin.contentView.minimumPinSize.width - 1)

        // Text pins have no zoom concept: zoom gestures and the zoom badge are disabled.
        let textPin = manager.createPin(content: textContent("no zoom"))
        textPin.setFrame(NSRect(x: 200, y: 200, width: 300, height: 200))
        XCTAssertFalse(textPin.supportsZoom)
        XCTAssertTrue(textPin.rootView.zoomBadge.isHidden)
        textPin.zoom(by: 1.5)
        XCTAssertEqual(textPin.panel.frame.size, CGSize(width: 300, height: 200))
        XCTAssertEqual(textPin.rootView.zoomBadge.alphaValue, 0, accuracy: 0.01)
    }

    func testSmoothIncrementalZoomPreservesExactCentreAndUpdatesZoomBadgeAndReset() {
        let pin = manager.createPin(content: .image(TestImage.make(width: 600, height: 400)))
        pin.setFrame(NSRect(x: 200, y: 200, width: 300, height: 200))
        let centre = CGPoint(x: pin.panel.frame.midX, y: pin.panel.frame.midY)
        XCTAssertEqual(pin.zoomPercentage, 100)
        XCTAssertEqual(pin.rootView.zoomBadge.percentage, 100)

        // Simulate 80 high-frequency trackpad steps with a small 0.5% delta per frame.
        // Without unrounded floating-point state, 300 * 1.005 = 301.5 would round
        // independently on each step and drift the centre and aspect ratio.
        for _ in 0..<80 {
            pin.zoom(by: 1.005, isContinuousGesture: true)
        }
        let expectedScale = pow(1.005, 80.0)
        XCTAssertEqual(pin.panel.frame.width, 300 * expectedScale, accuracy: 2)
        XCTAssertEqual(pin.panel.frame.width / pin.panel.frame.height, 1.5, accuracy: 0.01)
        XCTAssertEqual(pin.panel.frame.midX, centre.x, accuracy: 0.5, "incremental zoom must not walk the window centre")
        XCTAssertEqual(pin.panel.frame.midY, centre.y, accuracy: 0.5)
        XCTAssertEqual(pin.rootView.zoomBadge.percentage, Int((expectedScale * 100).rounded()))

        pin.resetZoom()
        XCTAssertEqual(pin.panel.frame.size, CGSize(width: 300, height: 200))
        XCTAssertEqual(pin.panel.frame.midX, centre.x, accuracy: 1)
        XCTAssertEqual(pin.panel.frame.midY, centre.y, accuracy: 1)
        XCTAssertEqual(pin.zoomPercentage, 100)
        XCTAssertEqual(pin.rootView.zoomBadge.percentage, 100)
    }

    func testCleanShotChromeLayoutAndContinuousRoundedWindowCorners() {
        let pin = manager.createPin(content: .image(TestImage.make(width: 400, height: 300)))
        pin.setFrame(NSRect(x: 100, y: 100, width: 300, height: 200))
        let root = pin.rootView
        root.layoutSubtreeIfNeeded()
        root.updateLayer()

        XCTAssertEqual(root.cornerRadius, 12)
        XCTAssertEqual(root.layer?.cornerCurve, .continuous)

        // Top-left Close, top-center Zoom badge, top-right Hide, bottom-left Annotate/Edit, bottom-right Save, center Copy.
        XCTAssertLessThan(root.closeChrome.frame.minX, 20)
        XCTAssertGreaterThan(root.closeChrome.frame.maxY, root.bounds.height - 40)
        XCTAssertEqual(root.zoomBadge.frame.midX, root.bounds.midX, accuracy: 1)
        XCTAssertGreaterThan(root.zoomBadge.frame.maxY, root.bounds.height - 40)
        XCTAssertGreaterThan(root.hideChrome.frame.maxX, root.bounds.width - 20)
        XCTAssertGreaterThan(root.hideChrome.frame.maxY, root.bounds.height - 40)
        XCTAssertLessThan(root.editChrome.frame.minX, 20)
        XCTAssertLessThan(root.editChrome.frame.minY, 20)
        XCTAssertGreaterThan(root.saveChrome.frame.maxX, root.bounds.width - 20)
        XCTAssertLessThan(root.saveChrome.frame.minY, 20)
        XCTAssertEqual(root.chrome.frame.midX, root.bounds.midX, accuracy: 1)
        XCTAssertEqual(root.chrome.frame.midY, root.bounds.midY, accuracy: 1)

        // Corner buttons (28x28) and center Copy button (38x38).
        XCTAssertEqual(root.closeChrome.frame.size, CGSize(width: 28, height: 28))
        XCTAssertEqual(root.hideChrome.frame.size, CGSize(width: 28, height: 28))
        XCTAssertEqual(root.editChrome.frame.size, CGSize(width: 28, height: 28))
        XCTAssertEqual(root.saveChrome.frame.size, CGSize(width: 28, height: 28))
        XCTAssertEqual(root.chrome.frame.size, CGSize(width: 38, height: 38))

        // Default 100% hides the zoom badge on hover; zooming reveals it, and
        // resetting back to 100% hides it again.
        root.setChromeVisible(true, animated: false)
        XCTAssertEqual(root.closeChrome.alphaValue, 1, accuracy: 0.01)
        XCTAssertEqual(root.hideChrome.alphaValue, 1, accuracy: 0.01)
        XCTAssertEqual(root.editChrome.alphaValue, 1, accuracy: 0.01)
        XCTAssertEqual(root.saveChrome.alphaValue, 1, accuracy: 0.01)
        XCTAssertEqual(root.chrome.alphaValue, 1, accuracy: 0.01)
        XCTAssertEqual(root.zoomBadge.alphaValue, 0, accuracy: 0.01, "100% zoom badge stays hidden by default")

        // Text pins also expose a bottom-right Save as Markdown button.
        let textPin = manager.createPin(content: textContent("# Markdown Title\nBody"), textMode: .markdown)
        let textRoot = textPin.rootView
        textRoot.layoutSubtreeIfNeeded()
        textRoot.setChromeVisible(true, animated: false)
        XCTAssertEqual(textRoot.saveChrome.alphaValue, 1, accuracy: 0.01)
        let textView = try? XCTUnwrap(textPin.contentView as? TextPinView)
        XCTAssertEqual(String(data: textView?.markdownData() ?? Data(), encoding: .utf8), "# Markdown Title\nBody")

        pin.zoom(by: 1.25)
        XCTAssertEqual(root.zoomBadge.percentage, 125)
        XCTAssertEqual(root.zoomBadge.alphaValue, 1, accuracy: 0.01, "zooming away from 100% reveals the badge")

        root.setChromeVisible(false, animated: false)
        XCTAssertEqual(root.zoomBadge.alphaValue, 0, accuracy: 0.01)
        root.setChromeVisible(true, animated: false)
        XCTAssertEqual(root.zoomBadge.alphaValue, 1, accuracy: 0.01, "hovering a zoomed pin shows the zoom badge")

        pin.resetZoom()
        XCTAssertEqual(root.zoomBadge.percentage, 100)
        root.setChromeVisible(true, animated: false)
        XCTAssertEqual(root.zoomBadge.alphaValue, 0, accuracy: 0.01, "returning to 100% hides the zoom badge")
    }

    func testImagePinContextMenuStructureLabelsIconsAndState() throws {
        let pin = manager.createPin(content: .image(TestImage.make(width: 400, height: 300)))
        let view = try XCTUnwrap(pin.contentView as? ImagePinView)

        let idleMenu = pin.makeContextMenu()
        idleMenu.update()
        let idleTitles = idleMenu.items.map { $0.isSeparatorItem ? "---" : ($0.view != nil ? "[Opacity]" : $0.title) }
        XCTAssertEqual(idleTitles, [
            "Annotate Image",
            "Restore Original Image",
            "---",
            "Copy",
            "Copy and Close",
            "Save as PNG…",
            "---",
            "Default Size",
            "Actual Pixel Size",
            "Lock Aspect Ratio",
            "[Opacity]",
            "---",
            "Hide Pin",
            "Close Pin"
        ])

        for item in idleMenu.items where !item.isSeparatorItem {
            if let customView = item.view {
                let hasIcon = customView.subviews.contains { ($0 as? NSImageView)?.image != nil }
                XCTAssertTrue(hasIcon, "Custom opacity menu row must include a leading icon")
            } else {
                XCTAssertNotNil(item.image, "Menu item '\(item.title)' must have an icon")
            }
        }

        let restoreItem = try XCTUnwrap(idleMenu.item(withTitle: "Restore Original Image"))
        XCTAssertFalse(restoreItem.isEnabled, "Restore Original Image is disabled when unmodified")

        view.beginAnnotating()
        pin.isAspectLocked = true
        view.annotationStore.add(Annotation(
            tool: .rectangle,
            points: [CGPoint(x: 10, y: 10), CGPoint(x: 80, y: 80)],
            style: .current()
        ))

        let activeMenu = pin.makeContextMenu()
        activeMenu.update()
        XCTAssertNotNil(activeMenu.item(withTitle: "Done Editing"))
        XCTAssertNotNil(activeMenu.item(withTitle: "Unlock Aspect Ratio"))
        let activeRestore = try XCTUnwrap(activeMenu.item(withTitle: "Restore Original Image"))
        XCTAssertTrue(activeRestore.isEnabled, "Restore Original Image enables once annotations exist")
    }

    func testTextPinContextMenuStructureSubmenuAndIdleRightClick() throws {
        let pin = manager.createPin(content: textContent("# Heading"), textMode: .markdown)
        let view = try XCTUnwrap(pin.contentView as? TextPinView)

        let menu = pin.makeContextMenu()
        menu.update()
        let titles = menu.items.map { $0.isSeparatorItem ? "---" : ($0.view != nil ? "[Opacity]" : $0.title) }
        XCTAssertEqual(titles, [
            "Edit Markdown Source",
            "---",
            "Copy",
            "Copy and Close",
            "Save as Markdown…",
            "---",
            "Text Mode",
            "[Opacity]",
            "---",
            "Hide Pin",
            "Close Pin"
        ])

        for item in menu.items where !item.isSeparatorItem {
            if let customView = item.view {
                let hasIcon = customView.subviews.contains { ($0 as? NSImageView)?.image != nil }
                XCTAssertTrue(hasIcon)
            } else {
                XCTAssertNotNil(item.image, "Menu item '\(item.title)' must have an icon")
            }
        }

        let textModeItem = try XCTUnwrap(menu.item(withTitle: "Text Mode"))
        let submenu = try XCTUnwrap(textModeItem.submenu)
        XCTAssertEqual(submenu.items.map(\.title), ["Rich Text", "Markdown", "Plain Text"])
        for subItem in submenu.items {
            XCTAssertNotNil(subItem.image, "Text Mode submenu item '\(subItem.title)' must have an icon")
        }
        XCTAssertEqual(submenu.item(withTitle: "Markdown")?.state, .on)

        // Right-clicking the read-only text view while idle returns the pin context menu.
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: CGPoint(x: 20, y: 20),
            modifierFlags: [], timestamp: 0, windowNumber: pin.panel.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let idleEditorMenu = try XCTUnwrap(view.editableTextView.menu(for: event))
        XCTAssertNotNil(idleEditorMenu.item(withTitle: "Copy"))
        XCTAssertNotNil(idleEditorMenu.item(withTitle: "Copy and Close"))

        // Switching to rich text updates the edit item title.
        view.setTextMode(.richText, explicit: true)
        XCTAssertNotNil(pin.makeContextMenu().item(withTitle: "Edit Text"))
    }

    func testTextPinWindowSizeScalesWithTextVolume() {
        let shortPin = manager.createPin(content: textContent("Short note"))
        let twoLinePin = manager.createPin(content: textContent(
            "A brief two-sentence thought that wraps onto a second line cleanly without stretching across the screen."
        ))
        let mediumPin = manager.createPin(content: textContent(
            String(repeating: "Medium paragraph with several sentences of reading content. ", count: 5)
        ))
        let longPin = manager.createPin(content: textContent(
            String(repeating: "Long article paragraph with detailed analysis and multiple lines of prose. ", count: 16)
        ))

        XCTAssertLessThan(shortPin.panel.frame.width, twoLinePin.panel.frame.width)
        XCTAssertLessThan(twoLinePin.panel.frame.width, mediumPin.panel.frame.width)
        XCTAssertLessThan(mediumPin.panel.frame.width, longPin.panel.frame.width)
    }
}

final class PinRootViewTests: XCTestCase {
    func testResizeHotZonesMatchCursorFeedback() {
        let view = PinRootView()
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 200)

        XCTAssertEqual(view.resizeEdge(at: NSPoint(x: 150, y: 100)), [])
        XCTAssertEqual(view.resizeEdge(at: NSPoint(x: 1, y: 100)), [.left])
        XCTAssertEqual(view.resizeEdge(at: NSPoint(x: 299, y: 100)), [.right])
        XCTAssertEqual(view.resizeEdge(at: NSPoint(x: 150, y: 1)), [.bottom])
        XCTAssertEqual(view.resizeEdge(at: NSPoint(x: 150, y: 199)), [.top])
        XCTAssertEqual(view.resizeEdge(at: NSPoint(x: 2, y: 2)), [.left, .bottom])
        XCTAssertEqual(view.resizeEdge(at: NSPoint(x: 298, y: 198)), [.right, .top])

        // Body reports the drag cursor, edges report resize cursors.
        XCTAssertEqual(view.cursor(at: NSPoint(x: 150, y: 100)), NSCursor.arrow)
        XCTAssertEqual(view.cursor(at: NSPoint(x: 1, y: 100)), ResizeEdge.left.cursor)
        XCTAssertEqual(view.cursor(at: NSPoint(x: 299, y: 100)), ResizeEdge.right.cursor)
        XCTAssertEqual(view.cursor(at: NSPoint(x: 150, y: 1)), ResizeEdge.bottom.cursor)
        XCTAssertEqual(view.cursor(at: NSPoint(x: 150, y: 199)), ResizeEdge.top.cursor)
        XCTAssertEqual(view.cursor(at: NSPoint(x: 12, y: 12)), ResizeEdge([.left, .bottom]).cursor)
        XCTAssertEqual(view.cursor(at: NSPoint(x: 12, y: 188)), ResizeEdge([.left, .top]).cursor)
        XCTAssertEqual(view.cursor(at: NSPoint(x: 288, y: 12)), ResizeEdge([.right, .bottom]).cursor)
        XCTAssertEqual(view.cursor(at: NSPoint(x: 288, y: 188)), ResizeEdge([.right, .top]).cursor)

        // Visible corner buttons must not block the 14x14 corner resize zones.
        view.setEditChromeItem(ChromeItem(symbol: "pencil", tooltip: "Edit") {})
        view.setSaveChromeItem(ChromeItem(symbol: "square.and.arrow.down", tooltip: "Save") {})
        view.layoutSubtreeIfNeeded()
        view.setChromeVisible(true, animated: false)
        XCTAssertEqual(view.cursor(at: NSPoint(x: 12, y: 12)), ResizeEdge([.left, .bottom]).cursor)
        XCTAssertEqual(view.cursor(at: NSPoint(x: 12, y: 188)), ResizeEdge([.left, .top]).cursor)
        XCTAssertEqual(view.cursor(at: NSPoint(x: 288, y: 12)), ResizeEdge([.right, .bottom]).cursor)
        XCTAssertEqual(view.cursor(at: NSPoint(x: 288, y: 188)), ResizeEdge([.right, .top]).cursor)
        XCTAssertTrue(view.hitTest(NSPoint(x: 12, y: 12)) === view)
        // Inner area of corner buttons still shows arrow and routes clicks to the button.
        XCTAssertEqual(view.cursor(at: NSPoint(x: 24, y: 24)), NSCursor.arrow)

        // PinPanel omits `.resizable` so NSNextStepFrame does not intercept edge
        // clicks or reset the resize cursor, and applyCursor updates the system cursor.
        let panel = PinPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200))
        XCTAssertFalse(panel.styleMask.contains(.resizable))
        WindowInteraction.applyCursor(ResizeEdge.left.cursor)
        XCTAssertEqual(NSCursor.current, ResizeEdge.left.cursor)
        if let system = NSCursor.currentSystem {
            XCTAssertEqual(system.image.size, ResizeEdge.left.cursor.image.size)
        }
        WindowInteraction.applyCursor(.arrow)
    }
}
