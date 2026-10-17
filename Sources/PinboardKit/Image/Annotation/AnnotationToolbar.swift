import AppKit

/// Floating tool strip attached to an image pin while it is in edit mode.
/// Lives in a child panel so it never covers the image or shrinks with it.
final class AnnotationToolbar: AttachedToolbar {
    private var toolButtons: [AnnotationTool: NSButton] = [:]
    private let colorSwatch = ColorSwatchButton(tooltip: "Color")
    private let widthSlider = FirstMouseSlider()
    /// Font controls shown only while the text tool is armed or a text
    /// annotation is selected — text style is a per-annotation property.
    private let fontControls = NSStackView()
    private let familyPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizeField = NSTextField()

    private weak var canvas: AnnotationCanvasView?
    private weak var pin: ImagePinView?

    private static let tools: [AnnotationTool] = [
        .select, .rectangle, .ellipse, .arrow, .line, .freehand, .text, .highlight, .blur, .mosaic, .crop
    ]

    init(canvas: AnnotationCanvasView, pin: ImagePinView) {
        self.canvas = canvas
        self.pin = pin
        super.init()
        canvas.onSelectionChange = { [weak self] in self?.syncSelection() }
        buildItems()
        finalizeLayout()
    }

    private func buildItems() {
        for tool in AnnotationToolbar.tools {
            let button = makeButton(symbol: tool.symbol, tooltip: tool.localizedName, action: #selector(selectTool(_:)))
            button.tag = AnnotationToolbar.tools.firstIndex(of: tool) ?? 0
            toolButtons[tool] = button
            stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(makeSeparator())

        colorSwatch.color = Preferences.shared.annotationColor
        colorSwatch.onColorChange = { [weak self] color in
            guard let self, let canvas = self.canvas else { return }
            if canvas.selectedAnnotation != nil {
                canvas.updateSelectedStyle { $0.colorHex = color.hexString }
            } else {
                Preferences.shared.annotationColor = color
                canvas.style.colorHex = color.hexString
            }
        }
        stack.addArrangedSubview(colorSwatch)

        fontControls.orientation = .horizontal
        fontControls.spacing = 4
        familyPopUp.addItems(withTitles: NSFontManager.shared.availableFontFamilies)
        familyPopUp.target = self
        familyPopUp.action = #selector(fontFamilyChanged)
        familyPopUp.controlSize = .small
        familyPopUp.font = .systemFont(ofSize: 11)
        familyPopUp.toolTip = "Text Font"
        familyPopUp.translatesAutoresizingMaskIntoConstraints = false
        familyPopUp.widthAnchor.constraint(equalToConstant: 120).isActive = true
        fontControls.addArrangedSubview(familyPopUp)

        sizeField.formatter = {
            let formatter = NumberFormatter()
            formatter.minimum = 6
            formatter.maximum = 400
            return formatter
        }()
        sizeField.target = self
        sizeField.action = #selector(fontSizeChanged)
        sizeField.controlSize = .small
        sizeField.font = .systemFont(ofSize: 11)
        sizeField.toolTip = "Text Size"
        sizeField.translatesAutoresizingMaskIntoConstraints = false
        sizeField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        fontControls.addArrangedSubview(sizeField)
        fontControls.isHidden = true
        stack.addArrangedSubview(fontControls)

        widthSlider.minValue = 1
        widthSlider.maxValue = 16
        widthSlider.doubleValue = Preferences.shared.annotationLineWidth
        widthSlider.target = self
        widthSlider.action = #selector(widthChanged)
        widthSlider.isContinuous = true
        widthSlider.toolTip = "Line Width"
        widthSlider.translatesAutoresizingMaskIntoConstraints = false
        widthSlider.widthAnchor.constraint(equalToConstant: 70).isActive = true
        stack.addArrangedSubview(widthSlider)

        stack.addArrangedSubview(makeSeparator())
        stack.addArrangedSubview(makeButton(symbol: "arrow.uturn.backward", tooltip: "Undo", action: #selector(undo)))
        stack.addArrangedSubview(makeButton(symbol: "arrow.uturn.forward", tooltip: "Redo", action: #selector(redo)))
        stack.addArrangedSubview(makeButton(symbol: "trash", tooltip: "Delete Selection", action: #selector(deleteSelection)))
        stack.addArrangedSubview(makeButton(symbol: "arrow.counterclockwise", tooltip: "Restore Original Image", action: #selector(resetAll)))
        stack.addArrangedSubview(makeSeparator())
        stack.addArrangedSubview(makeButton(symbol: "checkmark.circle", tooltip: "Done Editing", action: #selector(finish)))
    }

    override func show(attachedTo parent: NSWindow) {
        super.show(attachedTo: parent)
        syncSelection()
    }

    override func hide() {
        colorSwatch.stopPicking()
        super.hide()
    }

    func syncSelection() {
        guard let canvas else { return }
        for (tool, button) in toolButtons {
            button.contentTintColor = tool == canvas.tool ? .controlAccentColor : .labelColor
        }

        // Controls mirror the selected annotation's own style; falling back
        // to the pin's current style when nothing is selected.
        let selectedText = canvas.selectedAnnotation?.tool == .text ? canvas.selectedAnnotation : nil
        let effectiveStyle = canvas.selectedAnnotation?.style ?? canvas.style
        colorSwatch.setColorSilently(effectiveStyle.color)

        fontControls.isHidden = canvas.tool != .text && selectedText == nil
        let family = effectiveStyle.fontName ?? NSFont.systemFont(ofSize: 1).familyName ?? "Helvetica"
        familyPopUp.selectItem(withTitle: family)
        if familyPopUp.selectedItem == nil { familyPopUp.setTitle(family) }
        sizeField.stringValue = String(Int(effectiveStyle.fontSize))
        panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
    }

    // MARK: - Actions

    @objc private func selectTool(_ sender: NSButton) {
        guard AnnotationToolbar.tools.indices.contains(sender.tag) else { return }
        canvas?.tool = AnnotationToolbar.tools[sender.tag]
        syncSelection()
    }

    @objc private func widthChanged() {
        Preferences.shared.annotationLineWidth = widthSlider.doubleValue
        canvas?.updateSelectedStyle { $0.lineWidth = CGFloat(widthSlider.doubleValue) }
    }

    @objc private func fontFamilyChanged() {
        guard let family = familyPopUp.titleOfSelectedItem else { return }
        canvas?.updateSelectedStyle { $0.fontName = family }
    }

    @objc private func fontSizeChanged() {
        let value = CGFloat(sizeField.doubleValue)
        guard value >= 6, value <= 400 else { return syncSelection() }
        canvas?.updateSelectedStyle { $0.fontSize = value }
    }

    @objc private func undo() { canvas?.store.undoManager.undo(); canvas?.needsDisplay = true }
    @objc private func redo() { canvas?.store.undoManager.redo(); canvas?.needsDisplay = true }
    @objc private func deleteSelection() { canvas?.deleteSelection() }
    @objc private func resetAll() {
        canvas?.store.reset()
        pin?.refreshAfterStoreChange()
    }
    @objc private func finish() { pin?.endEditing() }
}
