import AppKit
import SwiftUI
import XCTest
@testable import PinboardKit

/// Markdown themes: the published palette, how a themed pin paints itself and
/// its source editor, and how a Settings change reaches open pins.
final class MarkdownThemeTests: XCTestCase {
    private var manager: PinWindowManager { PinWindowManager.shared }

    override func tearDown() {
        manager.closeAll()
        manager.historyStore = nil
        Preferences.shared.markdownTheme = .standard
        Preferences.shared.textMode = .richText
        super.tearDown()
    }

    private func makeMarkdownPin(_ source: String) throws -> (PinWindowController, TextPinView) {
        let pin = manager.createPin(content: .text(NSAttributedString(string: source)), textMode: .markdown)
        let view = try XCTUnwrap(pin.contentView as? TextPinView)
        return (pin, view)
    }

    private func colors(in attributed: NSAttributedString, _ key: NSAttributedString.Key) -> Set<String> {
        var result: Set<String> = []
        attributed.enumerateAttribute(key, in: attributed.fullRange) { value, _, _ in
            if let color = value as? NSColor { result.insert(color.hexString) }
        }
        return result
    }

    private func bodyColor(of view: TextPinView) throws -> String {
        let rendered = view.renderedAttributedString
        let color = rendered.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        return try XCTUnwrap(color).hexString
    }

    // MARK: - Palette

    func testStandardThemeMatchesTheUnthemedRenderer() {
        let standard = MarkdownRenderer.Style(theme: .standard)
        let plain = MarkdownRenderer.Style.default

        XCTAssertEqual(standard.textColor.hexString, plain.textColor.hexString)
        XCTAssertEqual(standard.secondaryTextColor.hexString, plain.secondaryTextColor.hexString)
        XCTAssertEqual(standard.linkColor.hexString, plain.linkColor.hexString)
        XCTAssertEqual(standard.codeBackgroundColor.hexString, plain.codeBackgroundColor.hexString)
    }

    func testEverforestDarkHardUsesThePublishedPalette() {
        let theme = MarkdownTheme.everforestDarkHard

        XCTAssertEqual(theme.background?.hexString, "#272E33", "background 0")
        XCTAssertEqual(theme.text.hexString, "#D3C6AA", "foreground")
        XCTAssertEqual(theme.secondaryText.hexString, "#9DA9A0", "grey 2")
        XCTAssertEqual(theme.link.hexString, "#7FBBB3", "blue")
        XCTAssertEqual(theme.codeBackground.hexString, "#2E383C", "background 1")
        XCTAssertEqual(theme.selection?.hexString, "#4C3743", "background visual")
    }

    func testThemedRendererPaintsThePaletteColours() {
        let theme = MarkdownTheme.everforestDarkHard
        let rendered = MarkdownRenderer.render(
            "# Title\n\nBody with [a link](https://example.com) and `code`.\n\n> quoted\n\n```\nblock\n```",
            style: .init(theme: theme)
        )

        let foregrounds = colors(in: rendered, .foregroundColor)
        XCTAssertTrue(foregrounds.contains(theme.text.hexString), "body text")
        XCTAssertTrue(foregrounds.contains(theme.link.hexString), "links")
        XCTAssertTrue(foregrounds.contains(theme.secondaryText.hexString), "quote bar and rule")
        XCTAssertTrue(colors(in: rendered, .backgroundColor).contains(theme.codeBackground.hexString),
                      "code blocks")
    }

    // MARK: - Pins

    func testMarkdownPinPaintsTheThemePaper() throws {
        Preferences.shared.markdownTheme = .everforestDarkHard
        let (pin, view) = try makeMarkdownPin("# Chart\n\nBody text")

        XCTAssertTrue(pin.rootView.drawsBackground, "a theme with paper draws it")
        XCTAssertEqual(pin.rootView.themedBackground?.hexString, "#272E33")
        XCTAssertEqual(pin.rootView.effectiveBackgroundColor.hexString, "#272E33")
        XCTAssertEqual(try bodyColor(of: view), "#D3C6AA")

        guard case .text(let canonical) = view.currentContent() else { return XCTFail("expected text") }
        XCTAssertEqual(canonical.string, "# Chart\n\nBody text", "the theme never enters the content")
    }

    func testStandardMarkdownPinUsesOpaqueSystemPaper() throws {
        let (pin, _) = try makeMarkdownPin("# Title")

        XCTAssertTrue(pin.rootView.drawsBackground, "text pins use an opaque background by default")
        XCTAssertNil(pin.rootView.themedBackground)
        XCTAssertEqual(pin.rootView.effectiveBackgroundColor, .textBackgroundColor)
    }

    func testThemeChangeRepaintsOpenMarkdownPins() throws {
        let (pin, view) = try makeMarkdownPin("# Title\n\nBody")
        XCTAssertTrue(pin.rootView.drawsBackground)
        XCTAssertNotEqual(try bodyColor(of: view), "#D3C6AA")

        Preferences.shared.markdownTheme = .everforestDarkHard

        XCTAssertTrue(pin.rootView.drawsBackground, "an open pin adopts the theme")
        XCTAssertEqual(pin.rootView.effectiveBackgroundColor.hexString, "#272E33")
        XCTAssertEqual(try bodyColor(of: view), "#D3C6AA")
    }

    func testEditingPaintsTheSourceWithTheTheme() throws {
        Preferences.shared.markdownTheme = .everforestDarkHard
        let (_, view) = try makeMarkdownPin("**bold** source")
        view.beginEditing(at: nil)

        let editor = view.editableTextView
        XCTAssertEqual(editor.string, "**bold** source")
        let color = editor.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color?.hexString, "#D3C6AA", "the source stays readable on the dark paper")
        XCTAssertEqual(editor.insertionPointColor.hexString, "#D3C6AA", "the caret would vanish on black")
        XCTAssertEqual((editor.selectedTextAttributes[.backgroundColor] as? NSColor)?.hexString, "#4C3743")
    }

    func testSwitchingAThemedPinToRichTextDropsTheDarkPaper() throws {
        Preferences.shared.markdownTheme = .everforestDarkHard
        let (pin, view) = try makeMarkdownPin("# Title\n\nBody")

        view.setTextMode(.richText, explicit: true)

        XCTAssertEqual(view.textMode, .richText)
        XCTAssertTrue(pin.rootView.drawsBackground, "rich text keeps the standard opaque paper")
        XCTAssertNil(pin.rootView.themedBackground, "the theme paper belongs to Markdown")
        let converted = view.attributedString
        XCTAssertFalse(colors(in: converted, .foregroundColor).contains("#D3C6AA"),
                       "rich text keeps the standard colours")
        XCTAssertEqual(view.editableTextView.insertionPointColor.hexString, NSColor.textColor.hexString)
    }

    func testPerPinTransparentChoiceSurvivesThemeChanges() throws {
        Preferences.shared.markdownTheme = .everforestDarkHard
        let (pin, _) = try makeMarkdownPin("# Title")

        pin.setBackgroundVisible(false)
        XCTAssertFalse(pin.rootView.drawsBackground)

        Preferences.shared.markdownTheme = .standard
        Preferences.shared.markdownTheme = .everforestDarkHard

        XCTAssertFalse(pin.rootView.drawsBackground, "the user's transparent choice wins")
        pin.setBackgroundVisible(true)
        XCTAssertEqual(pin.rootView.effectiveBackgroundColor.hexString, "#272E33",
                       "an opaque themed pin shows the theme's paper, not the system one")
    }

    func testRepinnedMarkdownRecordRendersWithTheCurrentTheme() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        manager.historyStore = HistoryStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        Preferences.shared.markdownTheme = .everforestDarkHard
        let (pin, _) = try makeMarkdownPin("# Chart\n\nBody text")

        let recordID = try XCTUnwrap(pin.historyRecordID)
        XCTAssertEqual(manager.historyStore?.record(id: recordID)?.text, "# Chart\n\nBody text",
                       "the record holds the source, never the palette")

        let repinned = try XCTUnwrap(manager.repin(recordID: recordID))
        let view = try XCTUnwrap(repinned.contentView as? TextPinView)
        XCTAssertEqual(view.textMode, .markdown)
        XCTAssertEqual(try bodyColor(of: view), "#D3C6AA")
        XCTAssertEqual(repinned.rootView.effectiveBackgroundColor.hexString, "#272E33")
    }

    // MARK: - Settings

    /// The Settings window hosts the picker and the preview; rendering them
    /// must not trip over the theme cases or a tag/selection type mismatch.
    func testSettingsHostsTheThemePicker() throws {
        let hosting = NSHostingView(rootView: SettingsView(preferences: Preferences.shared))
        hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 700)
        hosting.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hosting.fittingSize.height, 200, "the form lays out")
    }

    // MARK: - Rendering

    /// What the pin actually paints: paper, text and links in the palette's
    /// colours. Also writes the PNG when `PINBOARD_THEME_ARTIFACT` names a
    /// path, so the result can be reviewed as an image.
    func testThemedPinDrawsWithThePaletteColours() throws {
        Preferences.shared.markdownTheme = .everforestDarkHard
        let theme = MarkdownTheme.everforestDarkHard
        let (pin, _) = try makeMarkdownPin(
            "# Weekly Chart\n\nSome **bold** text with [a link](https://example.com) and `code`.\n\n> quoted line\n\n```\nlet x = 1\n```"
        )

        pin.rootView.updateLayer()
        let painted = try XCTUnwrap(pin.rootView.layer?.backgroundColor)
        XCTAssertEqual(NSColor(cgColor: painted)?.hexString, "#272E33")

        // Force the display pass a live pin gets; `cacheDisplay` then walks
        // the real drawing path.
        pin.rootView.display()
        let image = try render(pin.rootView)
        let paper = try XCTUnwrap(theme.background)
        XCTAssertGreaterThan(pixelShare(of: paper, in: image), 0.5, "the paper")
        XCTAssertGreaterThan(pixelShare(of: theme.text, in: image), 0.01, "the body text")
        XCTAssertGreaterThan(pixelShare(of: theme.link, in: image), 0.0002, "the link")
        XCTAssertLessThan(pixelShare(of: .linkColor, in: image, tolerance: 0.06), 0.0001,
                          "links are drawn in the theme's blue, not the system accent")

        guard let path = ProcessInfo.processInfo.environment["PINBOARD_THEME_ARTIFACT"] else { return }
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    /// Rasterises the pin through its real drawing path.
    private func render(_ view: NSView) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Share of pixels whose channels are all within `tolerance` of `colour`.
    private func pixelShare(of colour: NSColor, in image: NSBitmapImageRep,
                           tolerance: CGFloat = 0.08) -> Double {
        let target = colour.usingColorSpace(.sRGB) ?? colour
        var hits = 0
        for x in 0..<image.pixelsWide {
            for y in 0..<image.pixelsHigh {
                guard let pixel = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let close = abs(pixel.redComponent - target.redComponent) <= tolerance
                    && abs(pixel.greenComponent - target.greenComponent) <= tolerance
                    && abs(pixel.blueComponent - target.blueComponent) <= tolerance
                if close { hits += 1 }
            }
        }
        return Double(hits) / Double(image.pixelsWide * image.pixelsHigh)
    }
}
