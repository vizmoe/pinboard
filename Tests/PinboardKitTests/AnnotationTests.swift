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

        // Blur and mosaic must actually change the checkerboard underneath.
        let baseRep = NSBitmapImageRep(cgImage: baseCG)
        for point in [CGPoint(x: 60, y: 60), CGPoint(x: 210, y: 60)] {
            let y = Int(size.height - point.y)
            let before = try XCTUnwrap(baseRep.colorAt(x: Int(point.x), y: y)?.usingColorSpace(.sRGB))
            let after = try XCTUnwrap(rep.colorAt(x: Int(point.x), y: y)?.usingColorSpace(.sRGB))
            let delta = abs(before.brightnessComponent - after.brightnessComponent)
            XCTAssertGreaterThan(delta, 0.05, "pixel at \(point) should be filtered")
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
}
