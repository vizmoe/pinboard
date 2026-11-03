import AppKit

/// Floating tool strip attached to an image pin while it is in edit mode.
/// Lives in a child panel so it never covers the image or shrinks with it.
final class AnnotationToolbar: AttachedToolbar {
    private var toolButtons: [AnnotationTool: NSButton] = [:]
    private let colorSwatch = ColorSwatchButton(tooltip: "Color")
    private let widthSlider = AnnotationWidthSlider()
    private var undoButton: NSButton!
    private var redoButton: NSButton!
    private var deleteButton: NSButton!
    /// Font controls shown only while the text tool is armed or a text
    /// annotation is selected — text style is a per-annotation property.
    private let fontControls = NSStackView()
    private let properties = NSStackView()
    private let redactionModeControl = FirstMouseSegmentedControl()
    private var preferredRedactionTool: AnnotationTool = .mosaic
    private let familyPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizeField = NSTextField()

    private weak var canvas: AnnotationCanvasView?
    private weak var pin: ImagePinView?

    private static let tools: [AnnotationTool] = [
        .select, .rectangle, .ellipse, .arrow, .line, .freehand, .text, .counter, .highlight, .mosaic, .crop
    ]

    init(canvas: AnnotationCanvasView, pin: ImagePinView) {
        self.canvas = canvas
        self.pin = pin
        super.init()
        canvas.onSelectionChange = { [weak self] in self?.syncSelection() }
        buildItems()
        finalizeLayout()
        NotificationCenter.default.addObserver(self, selector: #selector(undoGroupClosed),
            name: .NSUndoManagerDidCloseUndoGroup, object: canvas.store.undoManager)
    }

    private func buildItems() {
        for tool in AnnotationToolbar.tools {
            let tooltip = tool == .mosaic
                ? "Redact / Mosaic (M / B)"
                : "\(tool.localizedName) (\(tool.shortcut.uppercased()))"
            let button = makeButton(symbol: tool.symbol, tooltip: tooltip, action: #selector(selectTool(_:)))
            button.tag = AnnotationToolbar.tools.firstIndex(of: tool) ?? 0
            toolButtons[tool] = button
            stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(makeSeparator())

        redactionModeControl.segmentCount = 2
        redactionModeControl.trackingMode = .selectOne
        redactionModeControl.controlSize = .small
        redactionModeControl.segmentStyle = .rounded
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        redactionModeControl.setImage(
            NSImage(systemSymbolName: AnnotationTool.mosaic.symbol, accessibilityDescription: "Mosaic")?
                .withSymbolConfiguration(iconConfig),
            forSegment: 0
        )
        redactionModeControl.setToolTip("Mosaic (M)", forSegment: 0)
        redactionModeControl.setWidth(28, forSegment: 0)
        redactionModeControl.setImage(
            NSImage(systemSymbolName: AnnotationTool.blur.symbol, accessibilityDescription: "Solid Fill")?
                .withSymbolConfiguration(iconConfig),
            forSegment: 1
        )
        redactionModeControl.setToolTip("Solid Fill (B)", forSegment: 1)
        redactionModeControl.setWidth(28, forSegment: 1)
        redactionModeControl.selectedSegment = 0
        redactionModeControl.target = self
        redactionModeControl.action = #selector(redactionModeChanged)
        redactionModeControl.isHidden = true

        colorSwatch.color = Preferences.shared.annotationColor
        colorSwatch.onColorChange = { [weak self] color in
            guard let self, let canvas = self.canvas else { return }
            canvas.commitTextEditor()
            if canvas.selectedAnnotation != nil {
                canvas.updateSelectedStyle { $0.colorHex = color.hexString }
            } else {
                Preferences.shared.annotationColor = color
                canvas.style.colorHex = color.hexString
            }
        }
        properties.orientation = .horizontal
        properties.spacing = 6
        properties.addArrangedSubview(redactionModeControl)
        properties.addArrangedSubview(colorSwatch)

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
        properties.addArrangedSubview(fontControls)

        widthSlider.undoManagerForGesture = { [weak canvas] in
            canvas?.commitTextEditor()
            return canvas?.store.undoManager
        }
        widthSlider.minValue = 1
        widthSlider.maxValue = 16
        widthSlider.doubleValue = Preferences.shared.annotationLineWidth
        widthSlider.target = self
        widthSlider.action = #selector(widthChanged)
        widthSlider.isContinuous = true
        widthSlider.toolTip = "Line Width"
        widthSlider.translatesAutoresizingMaskIntoConstraints = false
        widthSlider.widthAnchor.constraint(equalToConstant: 70).isActive = true
        properties.addArrangedSubview(widthSlider)

        stack.addArrangedSubview(makeSeparator())
        undoButton = makeButton(symbol: "arrow.uturn.backward", tooltip: "Undo (⌘Z)", action: #selector(undo))
        redoButton = makeButton(symbol: "arrow.uturn.forward", tooltip: "Redo (⇧⌘Z)", action: #selector(redo))
        deleteButton = makeButton(symbol: "trash", tooltip: "Delete Selection", action: #selector(deleteSelection))
        [undoButton, redoButton, deleteButton].forEach { stack.addArrangedSubview($0!) }
        stack.addArrangedSubview(makeButton(symbol: "plus.square.on.square", tooltip: "Duplicate Selection (⌘D)", action: #selector(duplicate)))
        stack.addArrangedSubview(makeButton(symbol: "arrow.counterclockwise", tooltip: "Restore Original Image", action: #selector(resetAll)))
        stack.addArrangedSubview(makeSeparator())
        stack.addArrangedSubview(makeButton(symbol: "checkmark.circle", tooltip: "Done Editing", action: #selector(finish)))

        // Keep tools and contextual properties on separate rows so font controls
        // never push the strip beyond the screen at ordinary display sizes.
        let toolsRow = NSStackView()
        toolsRow.orientation = .horizontal
        toolsRow.spacing = 3
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
            toolsRow.addArrangedSubview(view)
        }
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.addArrangedSubview(toolsRow)
        stack.addArrangedSubview(properties)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func undoGroupClosed() { syncSelection() }

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
        if canvas.tool.isRedaction { preferredRedactionTool = canvas.tool }
        for (tool, button) in toolButtons {
            let active = tool == canvas.tool || (tool == .mosaic && canvas.tool.isRedaction)
            button.contentTintColor = active ? .controlAccentColor : .labelColor
        }

        // Controls mirror the selected annotation's own style; falling back
        // to the pin's current style when nothing is selected.
        let selectedText = canvas.selectedAnnotation?.tool == .text ? canvas.selectedAnnotation : nil
        let effectiveStyle = canvas.selectedAnnotation?.style ?? canvas.style
        colorSwatch.setColorSilently(effectiveStyle.color)
        widthSlider.doubleValue = Double(effectiveStyle.lineWidth)

        let effectiveTool = canvas.selectedAnnotation?.tool ?? canvas.tool
        properties.isHidden = effectiveTool == .select || effectiveTool == .crop
        redactionModeControl.isHidden = !effectiveTool.isRedaction
        if effectiveTool.isRedaction {
            redactionModeControl.selectedSegment = effectiveTool == .blur ? 1 : 0
        }
        colorSwatch.isHidden = effectiveTool == .mosaic
        fontControls.isHidden = effectiveTool != .text && effectiveTool != .counter && selectedText == nil
        familyPopUp.isHidden = effectiveTool == .counter
        widthSlider.isHidden = effectiveTool == .text || effectiveTool == .counter || effectiveTool == .blur
        widthSlider.toolTip = effectiveTool == .mosaic ? "Mosaic Size" : "Line Width"
        let family = effectiveStyle.fontName ?? NSFont.systemFont(ofSize: 1).familyName ?? "Helvetica"
        familyPopUp.selectItem(withTitle: family)
        if familyPopUp.selectedItem == nil { familyPopUp.setTitle(family) }
        sizeField.stringValue = String(Int(effectiveStyle.fontSize))
        undoButton.isEnabled = canvas.store.undoManager.canUndo
        redoButton.isEnabled = canvas.store.undoManager.canRedo
        deleteButton.isEnabled = canvas.selectedAnnotation != nil
        panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
        reposition()
    }

    // MARK: - Actions

    @objc private func selectTool(_ sender: NSButton) {
        guard AnnotationToolbar.tools.indices.contains(sender.tag) else { return }
        let chosen = AnnotationToolbar.tools[sender.tag]
        canvas?.tool = chosen == .mosaic ? preferredRedactionTool : chosen
        syncSelection()
    }

    @objc private func redactionModeChanged() {
        guard let canvas else { return }
        canvas.commitTextEditor()
        let mode: AnnotationTool = redactionModeControl.selectedSegment == 1 ? .blur : .mosaic
        preferredRedactionTool = mode
        if var selected = canvas.selectedAnnotation, selected.tool.isRedaction {
            selected.tool = mode
            canvas.store.update(selected, actionName: "Change Redaction Style")
        } else {
            canvas.tool = mode
        }
        syncSelection()
    }

    @objc private func widthChanged() {
        guard let canvas else { return }
        let width = widthSlider.doubleValue
        canvas.commitTextEditor()
        if canvas.selectedAnnotation == nil { Preferences.shared.annotationLineWidth = width }
        canvas.updateSelectedStyle { $0.lineWidth = CGFloat(width) }
    }

    @objc private func fontFamilyChanged() {
        guard let family = familyPopUp.titleOfSelectedItem else { return }
        canvas?.updateSelectedStyle { $0.fontName = family }
    }

    @objc private func fontSizeChanged() {
        guard let canvas else { return }
        let value = CGFloat(sizeField.doubleValue)
        guard value >= 6, value <= 400 else { return syncSelection() }
        canvas.commitTextEditor()
        if canvas.selectedAnnotation == nil { Preferences.shared.annotationFontSize = Double(value) }
        canvas.updateSelectedStyle { $0.fontSize = value }
    }

    @objc private func undo() { canvas?.commitTextEditor(); canvas?.store.undoManager.undo(); syncSelection() }
    @objc private func redo() { canvas?.store.undoManager.redo(); syncSelection() }
    @objc private func duplicate() { canvas?.duplicateSelection() }
    @objc private func deleteSelection() { canvas?.deleteSelection() }
    @objc private func resetAll() {
        canvas?.commitTextEditor()
        canvas?.store.reset()
        pin?.refreshAfterStoreChange()
    }
    @objc private func finish() { pin?.endEditing() }
}

/// AppKit tracks a slider within mouseDown; bracket that entire gesture so
/// continuous style updates undo together, just like canvas drags.
private final class AnnotationWidthSlider: NSSlider {
    var undoManagerForGesture: (() -> UndoManager?)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let manager = undoManagerForGesture?()
        manager?.beginUndoGrouping()
        defer { manager?.endUndoGrouping() }
        super.mouseDown(with: event)
    }
}

private final class FirstMouseSegmentedControl: NSSegmentedControl {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
