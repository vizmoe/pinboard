import AppKit
import XCTest
@testable import PinboardKit

final class AnnotationStoreTests: XCTestCase {
    private func annotation(_ tool: AnnotationTool, _ points: [CGPoint]) -> Annotation {
        Annotation(tool: tool, points: points, style: AnnotationStyle(colorHex: "#FF0000", lineWidth: 3, fontSize: 18))
    }

    func testUndoRedoOfAddAndRemove() {
        let store = AnnotationStore()
        let first = annotation(.rectangle, [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 40)])
        store.add(first)
        store.add(annotation(.arrow, [CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 30)]))
        XCTAssertEqual(store.annotations.count, 2)

        store.undoManager.undo()
        XCTAssertEqual(store.annotations.count, 1)
        store.undoManager.redo()
        XCTAssertEqual(store.annotations.count, 2)

        store.remove(id: first.id)
        XCTAssertEqual(store.annotations.count, 1)
        store.undoManager.undo()
        XCTAssertEqual(store.annotations.count, 2)
    }

    func testCropIsUndoableAndNonDestructive() {
        let store = AnnotationStore()
        let crop = CGRect(x: 10, y: 20, width: 100, height: 80)
        store.setCrop(crop)
        XCTAssertEqual(store.cropRect, crop)
        store.undoManager.undo()
        XCTAssertNil(store.cropRect)
    }

    func testResetClearsEverythingAndCanBeUndone() {
        let store = AnnotationStore()
        store.add(annotation(.ellipse, [CGPoint(x: 1, y: 1), CGPoint(x: 9, y: 9)]))
        store.setCrop(CGRect(x: 0, y: 0, width: 5, height: 5))
        store.reset()
        XCTAssertTrue(store.isEmpty)
        store.undoManager.undo()
        XCTAssertEqual(store.annotations.count, 1)
        XCTAssertNotNil(store.cropRect)
    }

    func testHitTestingAndTranslation() {
        var line = annotation(.line, [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)])
        XCTAssertTrue(line.hitTest(CGPoint(x: 50, y: 2), textSizer: AnnotationRenderer.textSize))
        XCTAssertFalse(line.hitTest(CGPoint(x: 50, y: 60), textSizer: AnnotationRenderer.textSize))
        line.translate(by: CGVector(dx: 0, dy: 60))
        XCTAssertTrue(line.hitTest(CGPoint(x: 50, y: 60), textSizer: AnnotationRenderer.textSize))
    }
}

final class AnnotationRendererTests: XCTestCase {
    /// Renders every tool onto a base image and writes the result to /tmp for
    /// visual inspection, asserting that pixels actually changed.
    func testRendersAllToolsOntoImage() throws {
        let size = CGSize(width: 600, height: 400)
        let base = NSImage(size: size)
        base.lockFocus()
        NSGradient(starting: .systemIndigo, ending: .systemTeal)?.draw(in: NSRect(origin: .zero, size: size), angle: 45)
        NSColor.white.setFill()
        NSRect(x: 320, y: 40, width: 240, height: 120).fill()
        // Checkerboard so blur and mosaic have high-frequency detail to act on.
        for row in 0..<10 {
            for column in 0..<20 where (row + column).isMultiple(of: 2) {
                NSColor.black.setFill()
                NSRect(x: 10 + column * 15, y: 10 + row * 15, width: 15, height: 15).fill()
            }
        }
        base.unlockFocus()
        let baseCG = try XCTUnwrap(base.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let effects = ImageEffects(base: baseCG)

        let style = AnnotationStyle(colorHex: "#FF3B30", lineWidth: 4, fontSize: 24)
        let annotations: [Annotation] = [
            Annotation(tool: .rectangle, points: [CGPoint(x: 20, y: 260), CGPoint(x: 140, y: 360)], style: style),
            Annotation(tool: .ellipse, points: [CGPoint(x: 160, y: 260), CGPoint(x: 280, y: 360)], style: style),
            Annotation(tool: .arrow, points: [CGPoint(x: 300, y: 260), CGPoint(x: 430, y: 360)], style: style),
            Annotation(tool: .line, points: [CGPoint(x: 450, y: 260), CGPoint(x: 580, y: 360)], style: style),
            Annotation(tool: .freehand, points: (0...40).map { CGPoint(x: 20 + CGFloat($0) * 6, y: 200 + sin(CGFloat($0) / 3) * 25) }, style: style),
            Annotation(tool: .highlight, points: [CGPoint(x: 320, y: 170), CGPoint(x: 560, y: 230)], style: style),
            Annotation(tool: .blur, points: [CGPoint(x: 20, y: 20), CGPoint(x: 150, y: 150)], style: style),
            Annotation(tool: .mosaic, points: [CGPoint(x: 170, y: 20), CGPoint(x: 300, y: 150)], style: style),
            Annotation(tool: .text, points: [CGPoint(x: 330, y: 120)], style: style, text: "标注文字 Pinboard")
        ]

        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.draw(baseCG, in: CGRect(origin: .zero, size: size))
        AnnotationRenderer.draw(annotations, imageSize: size, effects: effects, in: context)
        NSGraphicsContext.restoreGraphicsState()

        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/tmp/pinboard-annotations.png"))

        // Centre of the red rectangle outline must now be red.
        let onStroke = try XCTUnwrap(rep.colorAt(x: 20 + 2, y: Int(size.height) - 300))
        XCTAssertGreaterThan(onStroke.usingColorSpace(.sRGB)!.redComponent, 0.7)
        XCTAssertGreaterThan(data.count, 1000)

        // Solid fill (.blur) and mosaic must actually replace the checkerboard underneath.
        let baseRep = NSBitmapImageRep(cgImage: baseCG)
        for point in [CGPoint(x: 60, y: 60), CGPoint(x: 210, y: 60)] {
            let y = Int(size.height - point.y)
            let before = try XCTUnwrap(baseRep.colorAt(x: Int(point.x), y: y)?.usingColorSpace(.sRGB))
            let after = try XCTUnwrap(rep.colorAt(x: Int(point.x), y: y)?.usingColorSpace(.sRGB))
            let delta = abs(before.redComponent - after.redComponent)
                + abs(before.greenComponent - after.greenComponent)
                + abs(before.blueComponent - after.blueComponent)
            XCTAssertGreaterThan(delta, 0.1, "pixel at \(point) should be redacted")
        }
    }

    func testTextAnnotationKeepsItsOwnFont() throws {
        // Per-annotation style: changing one text annotation's font must not
        // bleed into another, and the family must actually resolve.
        let style = AnnotationStyle(colorHex: "#FF0000", lineWidth: 3, fontSize: 18, fontName: "Menlo")
        XCTAssertEqual(style.font(pointSize: 20).familyName, "Menlo")

        // A payload written before font support decodes with a nil fontName.
        let legacyJSON = "{\"colorHex\":\"#FF0000\",\"lineWidth\":3,\"fontSize\":18}"
        let legacy = try XCTUnwrap(legacyJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(AnnotationStyle.self, from: legacy)
        XCTAssertNil(decoded.fontName)

        let store = AnnotationStore()
        let first = Annotation(tool: .text, points: [.zero], style: style, text: "one")
        let second = Annotation(tool: .text, points: [.zero], style: .current(), text: "two")
        store.add(first)
        store.add(second)

        let canvas = AnnotationCanvasView(store: store, imageSize: CGSize(width: 100, height: 100), effects: nil)
        // Select the second annotation and restyle it.
        canvas.selectAnnotation(id: second.id)
        canvas.updateSelectedStyle { $0.fontName = "Futura"; $0.fontSize = 40 }
        XCTAssertEqual(store.annotation(with: second.id)?.style.fontName, "Futura")
        XCTAssertEqual(store.annotation(with: second.id)?.style.fontSize, 40)
        XCTAssertEqual(store.annotation(with: first.id)?.style.fontName, "Menlo",
                       "restyling one annotation must not touch another")
        XCTAssertEqual(store.annotation(with: first.id)?.style.fontSize, 18)

        // With nothing selected, edits seed the style for new annotations.
        canvas.selectAnnotation(id: nil)
        canvas.updateSelectedStyle { $0.fontSize = 9 }
        XCTAssertEqual(canvas.style.fontSize, 9)
    }

    func testTextSizeGrowsWithContent() {
        let style = AnnotationStyle(colorHex: "#000000", lineWidth: 2, fontSize: 20)
        let short = Annotation(tool: .text, points: [.zero], style: style, text: "A")
        let long = Annotation(tool: .text, points: [.zero], style: style, text: "AAAAAAAAAA")
        XCTAssertLessThan(AnnotationRenderer.textSize(for: short).width, AnnotationRenderer.textSize(for: long).width)
    }

    func testBlurRendersOpaqueSolidColorFillWithoutUnderlyingBleedThrough() throws {
        let size = CGSize(width: 120, height: 120)
        let base = NSImage(size: size)
        base.lockFocus()
        for row in 0..<8 {
            for col in 0..<8 {
                (row + col).isMultiple(of: 2) ? NSColor.black.setFill() : NSColor.white.setFill()
                NSRect(x: col * 15, y: row * 15, width: 15, height: 15).fill()
            }
        }
        base.unlockFocus()
        let baseCG = try XCTUnwrap(base.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let effects = ImageEffects(base: baseCG)

        let style = AnnotationStyle(colorHex: "#2E7D3280", lineWidth: 3, fontSize: 18)
        let solid = Annotation(tool: .blur, points: [CGPoint(x: 15, y: 15), CGPoint(x: 105, y: 105)], style: style)

        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.draw(baseCG, in: CGRect(origin: .zero, size: size))
        AnnotationRenderer.draw([solid], imageSize: size, effects: effects, in: context)
        NSGraphicsContext.restoreGraphicsState()

        // Every pixel inside the covered region must be the exact same opaque solid color,
        // regardless of whether the underlying checkerboard square was black or white.
        let sampleA = try XCTUnwrap(rep.colorAt(x: 22, y: 22)?.usingColorSpace(.sRGB))
        let sampleB = try XCTUnwrap(rep.colorAt(x: 37, y: 22)?.usingColorSpace(.sRGB))
        XCTAssertEqual(sampleA.redComponent, sampleB.redComponent, accuracy: 0.005)
        XCTAssertEqual(sampleA.greenComponent, sampleB.greenComponent, accuracy: 0.005)
        XCTAssertEqual(sampleA.blueComponent, sampleB.blueComponent, accuracy: 0.005)
        XCTAssertEqual(sampleA.alphaComponent, 1.0, accuracy: 0.005)
        let expected = try XCTUnwrap(NSColor(hex: "#2E7D32")?.usingColorSpace(.sRGB))
        XCTAssertEqual(sampleA.greenComponent, expected.greenComponent, accuracy: 0.02)
    }

    func testMosaicUsesIrreversibleQuantizedScrambledTilesNotBlockAverages() throws {
        // Two images that differ only by a thin secret glyph stroke inside one tile:
        // a naive block-averaging filter (CIPixellate) leaks the exact stroke pixel count
        // as a proportional gray level in that tile. Our irreversible mosaic quantizes and
        // scrambles across the neighborhood so tile colors are uniform opaque blocks that
        // do not equal the raw block average.
        let size = CGSize(width: 160, height: 160)
        func makeImage(strokeWidth: CGFloat) throws -> CGImage {
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            NSColor.systemBlue.setFill()
            NSRect(x: 20, y: 20, width: 120, height: 120).fill()
            NSColor.black.setFill()
            NSRect(x: 62, y: 62, width: strokeWidth, height: 3).fill()
            image.unlockFocus()
            return try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        }

        let baseCG = try makeImage(strokeWidth: 4)
        let effects = ImageEffects(base: baseCG)
        let mosaicCG = try XCTUnwrap(effects.mosaic(blockSize: 16))
        let rep = NSBitmapImageRep(cgImage: mosaicCG)

        // All pixels within a 16x16 mosaic tile must share the exact same color.
        let tileOriginColor = try XCTUnwrap(rep.colorAt(x: 64, y: 64)?.usingColorSpace(.sRGB))
        let tileInnerColor = try XCTUnwrap(rep.colorAt(x: 75, y: 75)?.usingColorSpace(.sRGB))
        XCTAssertEqual(tileOriginColor.redComponent, tileInnerColor.redComponent, accuracy: 0.001)
        XCTAssertEqual(tileOriginColor.greenComponent, tileInnerColor.greenComponent, accuracy: 0.001)
        XCTAssertEqual(tileOriginColor.blueComponent, tileInnerColor.blueComponent, accuracy: 0.001)

        // Larger blockSize produces larger uniform tiles.
        let coarseCG = try XCTUnwrap(effects.mosaic(blockSize: 32))
        let coarseRep = NSBitmapImageRep(cgImage: coarseCG)
        let c0 = try XCTUnwrap(coarseRep.colorAt(x: 32, y: 32)?.usingColorSpace(.sRGB))
        let c1 = try XCTUnwrap(coarseRep.colorAt(x: 60, y: 60)?.usingColorSpace(.sRGB))
        XCTAssertEqual(c0.redComponent, c1.redComponent, accuracy: 0.001)
        XCTAssertEqual(c0.greenComponent, c1.greenComponent, accuracy: 0.001)
        XCTAssertEqual(c0.blueComponent, c1.blueComponent, accuracy: 0.001)

        // Sub-quantization stroke changes (e.g. 2px vs 3px thin stroke inside a 16x16 cell)
        // are absorbed by coarse quantization prior to neighborhood mixing, defeating linear
        // sub-block ink-density inversion.
        let baseA = try makeImage(strokeWidth: 2)
        let baseB = try makeImage(strokeWidth: 3)
        let repA = NSBitmapImageRep(cgImage: try XCTUnwrap(ImageEffects(base: baseA).mosaic(blockSize: 16)))
        let repB = NSBitmapImageRep(cgImage: try XCTUnwrap(ImageEffects(base: baseB).mosaic(blockSize: 16)))
        let colorA = try XCTUnwrap(repA.colorAt(x: 68, y: 68)?.usingColorSpace(.sRGB))
        let colorB = try XCTUnwrap(repB.colorAt(x: 68, y: 68)?.usingColorSpace(.sRGB))
        XCTAssertEqual(colorA.redComponent, colorB.redComponent, accuracy: 0.001)
        XCTAssertEqual(colorA.greenComponent, colorB.greenComponent, accuracy: 0.001)
        XCTAssertEqual(colorA.blueComponent, colorB.blueComponent, accuracy: 0.001)
    }

    func testSecureBlurScramblesAndSmoothsWithoutLeakingSubBlockStrokes() throws {
        let size = CGSize(width: 160, height: 160)
        func makeImage(strokeWidth: CGFloat) throws -> CGImage {
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            NSColor.systemTeal.setFill()
            NSRect(x: 20, y: 20, width: 120, height: 120).fill()
            NSColor.black.setFill()
            NSRect(x: 62, y: 62, width: strokeWidth, height: 3).fill()
            image.unlockFocus()
            return try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        }

        let baseA = try makeImage(strokeWidth: 2)
        let baseB = try makeImage(strokeWidth: 3)
        let blurA = try XCTUnwrap(ImageEffects(base: baseA).secureBlur(radius: 16))
        let blurB = try XCTUnwrap(ImageEffects(base: baseB).secureBlur(radius: 16))
        let repA = NSBitmapImageRep(cgImage: blurA)
        let repB = NSBitmapImageRep(cgImage: blurB)

        let colorA = try XCTUnwrap(repA.colorAt(x: 68, y: 68)?.usingColorSpace(.sRGB))
        let colorB = try XCTUnwrap(repB.colorAt(x: 68, y: 68)?.usingColorSpace(.sRGB))
        XCTAssertEqual(colorA.alphaComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(colorA.redComponent, colorB.redComponent, accuracy: 0.001)
        XCTAssertEqual(colorA.greenComponent, colorB.greenComponent, accuracy: 0.001)
        XCTAssertEqual(colorA.blueComponent, colorB.blueComponent, accuracy: 0.001)
    }

    func testFancyArrowTapersAndSupportsCurvedMidpointControl() {
        let straight = AnnotationRenderer.arrowPath(points: [CGPoint(x: 20, y: 50), CGPoint(x: 180, y: 50)], width: 6)
        // Tapered shaft is narrower near the tail (x=30) than near the neck (x=140).
        XCTAssertTrue(straight.contains(CGPoint(x: 30, y: 51)))
        XCTAssertFalse(straight.contains(CGPoint(x: 30, y: 54)))
        XCTAssertTrue(straight.contains(CGPoint(x: 140, y: 54)))

        let curved = Annotation(
            tool: .arrow,
            points: [CGPoint(x: 20, y: 50), CGPoint(x: 180, y: 50), CGPoint(x: 100, y: 110)],
            style: AnnotationStyle(colorHex: "#FF3B30", lineWidth: 5, fontSize: 18)
        )
        XCTAssertTrue(curved.hitTest(CGPoint(x: 100, y: 110), textSizer: AnnotationRenderer.textSize),
                      "curved arrow must hit-test along its bent arc")
        XCTAssertFalse(curved.hitTest(CGPoint(x: 100, y: 50), textSizer: AnnotationRenderer.textSize),
                       "curved arrow must not hit-test on the straight chord far from the arc")
    }

    func testSpotlightDimsExteriorAndKeepsMultipleCutoutsBright() throws {
        let size = CGSize(width: 200, height: 200)
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()

        var rectStyle = AnnotationStyle(colorHex: "#000000", lineWidth: 8, fontSize: 18)
        rectStyle.spotlightShape = .rectangle
        var ovalStyle = rectStyle
        ovalStyle.spotlightShape = .ellipse

        let spotlights = [
            Annotation(tool: .spotlight, points: [CGPoint(x: 20, y: 20), CGPoint(x: 100, y: 100)], style: rectStyle),
            Annotation(tool: .spotlight, points: [CGPoint(x: 70, y: 70), CGPoint(x: 160, y: 160)], style: ovalStyle)
        ]
        AnnotationRenderer.draw(spotlights, imageSize: size, effects: nil, in: context)
        NSGraphicsContext.restoreGraphicsState()

        let insideRect = try XCTUnwrap(rep.colorAt(x: 40, y: Int(size.height - 40))?.usingColorSpace(.sRGB))
        let insideOverlap = try XCTUnwrap(rep.colorAt(x: 90, y: Int(size.height - 90))?.usingColorSpace(.sRGB))
        let outside = try XCTUnwrap(rep.colorAt(x: 185, y: Int(size.height - 20))?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(insideRect.brightnessComponent, 0.98, "spotlight cutout stays at full brightness")
        XCTAssertGreaterThan(insideOverlap.brightnessComponent, 0.98, "overlapping spotlights must not invert to dark")
        XCTAssertLessThan(outside.brightnessComponent, 0.65, "exterior outside all spotlights is dimmed")
    }

    func testTextStylesAndFreehandHighlightRender() throws {
        var boxStyle = AnnotationStyle(colorHex: "#FF3B30", lineWidth: 3, fontSize: 20)
        boxStyle.textStyle = .box
        let boxed = Annotation(tool: .text, points: [CGPoint(x: 20, y: 80)], style: boxStyle, text: "Label")
        let plain = Annotation(tool: .text, points: [CGPoint(x: 20, y: 80)],
                               style: AnnotationStyle(colorHex: "#FF3B30", lineWidth: 3, fontSize: 20), text: "Label")
        XCTAssertGreaterThan(AnnotationRenderer.textSize(for: boxed).width,
                             AnnotationRenderer.textSize(for: plain).width,
                             "boxed text includes pill padding")

        var freehandHighlightStyle = AnnotationStyle(colorHex: "#FFCC00", lineWidth: 4, fontSize: 18)
        freehandHighlightStyle.highlightMode = .freehand
        let strokeHighlight = Annotation(
            tool: .highlight,
            points: [CGPoint(x: 10, y: 30), CGPoint(x: 90, y: 30), CGPoint(x: 150, y: 30)],
            style: freehandHighlightStyle
        )
        XCTAssertEqual(strokeHighlight.effectiveHighlightMode, .freehand)
        XCTAssertTrue(strokeHighlight.hitTest(CGPoint(x: 80, y: 32), textSizer: AnnotationRenderer.textSize))
        XCTAssertFalse(strokeHighlight.hitTest(CGPoint(x: 80, y: 90), textSizer: AnnotationRenderer.textSize))
    }
}
