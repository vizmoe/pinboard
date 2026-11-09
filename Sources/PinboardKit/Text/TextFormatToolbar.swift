import AppKit

/// Rich text controls shown under a text pin while it is being edited.
/// Hidden otherwise, so an idle pin is just its glyphs.
final class TextFormatToolbar: AttachedToolbar, NSComboBoxDelegate {
    private weak var pin: TextPinView?

    private let familyPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizeCombo = NSComboBox()
    private let textColorSwatch = ColorSwatchButton(tooltip: "Text Color")
    private let backgroundColorSwatch = ColorSwatchButton(tooltip: "Background Color")
    // "Default" restores the standard text colour; "None" removes the text
    // background. Neither touches the other attribute.
    private func configureSwatches() {
        textColorSwatch.clearTitle = "Default"
        backgroundColorSwatch.clearTitle = "None"
    }
    private var styleButtons: [(trait: NSFontDescriptor.SymbolicTraits, button: NSButton)] = []
    private var attributeButtons: [(key: NSAttributedString.Key, button: NSButton)] = []
    private var isSyncing = false

    private var formatter: TextFormatter? {
        pin.map { TextFormatter(textView: $0.editableTextView) }
    }

    init(pin: TextPinView) {
        self.pin = pin
        super.init()
        buildItems()
        finalizeLayout()
    }

    override func show(attachedTo parent: NSWindow) {
        super.show(attachedTo: parent)
        syncFromSelection()
    }

    /// Hands the shared colour panel back when editing finishes.
    override func hide() {
        textColorSwatch.stopPicking()
        backgroundColorSwatch.stopPicking()
        super.hide()
    }

    private func buildItems() {
        familyPopUp.addItems(withTitles: NSFontManager.shared.availableFontFamilies)
        familyPopUp.target = self
        familyPopUp.action = #selector(familyChanged)
        familyPopUp.controlSize = .small
        familyPopUp.font = .systemFont(ofSize: 11)
        familyPopUp.toolTip = "Font"
        familyPopUp.translatesAutoresizingMaskIntoConstraints = false
        familyPopUp.widthAnchor.constraint(equalToConstant: 150).isActive = true
        stack.addArrangedSubview(familyPopUp)

        sizeCombo.addItems(withObjectValues: TextFormatter.commonFontSizes.map { Int($0) })
        sizeCombo.isEditable = true
        sizeCombo.completes = false
        sizeCombo.delegate = self
        sizeCombo.target = self
        sizeCombo.action = #selector(sizeChanged)
        sizeCombo.controlSize = .small
        sizeCombo.font = .systemFont(ofSize: 11)
        sizeCombo.toolTip = "Font Size"
        sizeCombo.translatesAutoresizingMaskIntoConstraints = false
        sizeCombo.widthAnchor.constraint(equalToConstant: 58).isActive = true
        stack.addArrangedSubview(sizeCombo)

        stack.addArrangedSubview(makeSeparator())

        addStyleButton(symbol: "bold", tooltip: "Bold", trait: .bold, action: #selector(toggleBold))
        addStyleButton(symbol: "italic", tooltip: "Italic", trait: .italic, action: #selector(toggleItalic))
        addAttributeButton(symbol: "underline", tooltip: "Underline", key: .underlineStyle,
                           action: #selector(toggleUnderline))
        addAttributeButton(symbol: "strikethrough", tooltip: "Strikethrough", key: .strikethroughStyle,
                           action: #selector(toggleStrikethrough))

        stack.addArrangedSubview(makeSeparator())

        configureSwatches()
        textColorSwatch.onColorChange = { [weak self] color in
            self?.formatter?.setAttribute(.foregroundColor, value: color)
        }
        textColorSwatch.onClear = { [weak self] in
            self?.formatter?.setAttribute(.foregroundColor, value: NSColor.labelColor)
            self?.textColorSwatch.color = .labelColor
        }
        stack.addArrangedSubview(textColorSwatch)

        backgroundColorSwatch.onColorChange = { [weak self] color in
            self?.formatter?.setAttribute(.backgroundColor, value: color.alphaComponent < 0.01 ? nil : color)
        }
        backgroundColorSwatch.onClear = { [weak self] in
            self?.formatter?.setAttribute(.backgroundColor, value: nil)
            self?.backgroundColorSwatch.color = .clear
        }
        stack.addArrangedSubview(backgroundColorSwatch)
        stack.addArrangedSubview(makeButton(symbol: "xmark.circle", tooltip: "Remove Background",
                                            action: #selector(removeBackground)))

        stack.addArrangedSubview(makeSeparator())
        stack.addArrangedSubview(makeButton(symbol: "eraser", tooltip: "Clear Formatting",
                                            action: #selector(clearFormatting)))
    }

    private func addStyleButton(symbol: String, tooltip: String, trait: NSFontDescriptor.SymbolicTraits, action: Selector) {
        let button = makeButton(symbol: symbol, tooltip: tooltip, action: action)
        styleButtons.append((trait, button))
        stack.addArrangedSubview(button)
    }

    private func addAttributeButton(symbol: String, tooltip: String, key: NSAttributedString.Key, action: Selector) {
        let button = makeButton(symbol: symbol, tooltip: tooltip, action: action)
        attributeButtons.append((key, button))
        stack.addArrangedSubview(button)
    }

    // MARK: - State sync

    /// Reflects the font and attributes at the caret or selection start.
    var selectedFontFamilyTitle: String? { familyPopUp.titleOfSelectedItem }

    func syncFromSelection() {
        guard let formatter, panel.isVisible else { return }
        isSyncing = true
        defer { isSyncing = false }

        let font = formatter.currentFont
        let family = TextDefaults.displayFontFamily(for: font)
        familyPopUp.selectItem(withTitle: family)
        if familyPopUp.selectedItem == nil {
            familyPopUp.selectItem(withTitle: TextDefaults.font.familyName ?? "PingFang SC")
        }

        sizeCombo.stringValue = font.pointSize == font.pointSize.rounded()
            ? String(Int(font.pointSize))
            : String(format: "%.1f", font.pointSize)

        for entry in styleButtons {
            entry.button.contentTintColor = formatter.isTraitActive(entry.trait) ? .controlAccentColor : .labelColor
        }
        for entry in attributeButtons {
            entry.button.contentTintColor = formatter.isAttributeActive(entry.key) ? .controlAccentColor : .labelColor
        }

        // `setColorSilently` is a no-op while that swatch is the active picker,
        // so syncing can never push a stale colour back over the user's choice.
        textColorSwatch.setColorSilently(formatter.currentColor(.foregroundColor) ?? .labelColor)
        backgroundColorSwatch.setColorSilently(formatter.currentColor(.backgroundColor) ?? .clear)
    }

    /// Formatting controls must not keep the caret.
    private func restoreFocus() {
        pin?.resumeEditingFocus()
        syncFromSelection()
    }

    // MARK: - Actions

    @objc private func familyChanged() {
        guard !isSyncing, let family = familyPopUp.titleOfSelectedItem else { return }
        formatter?.setFontFamily(family)
        restoreFocus()
    }

    @objc private func sizeChanged() {
        guard !isSyncing else { return }
        let value = CGFloat(sizeCombo.doubleValue)
        guard value >= 4, value <= 400 else { return syncFromSelection() }
        formatter?.setFontSize(value)
        restoreFocus()
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard !isSyncing else { return }
        DispatchQueue.main.async { [weak self] in self?.sizeChanged() }
    }

    @objc private func toggleBold() {
        formatter?.toggleTrait(.bold)
        restoreFocus()
    }

    @objc private func toggleItalic() {
        formatter?.toggleTrait(.italic)
        restoreFocus()
    }

    @objc private func toggleUnderline() {
        formatter?.toggleAttribute(.underlineStyle)
        restoreFocus()
    }

    @objc private func toggleStrikethrough() {
        formatter?.toggleAttribute(.strikethroughStyle)
        restoreFocus()
    }

    @objc private func removeBackground() {
        formatter?.setAttribute(.backgroundColor, value: nil)
        backgroundColorSwatch.setColorSilently(.clear)
        restoreFocus()
    }

    @objc private func clearFormatting() {
        formatter?.clearFormatting()
        restoreFocus()
    }
}
