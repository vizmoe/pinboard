import AppKit

/// Floating tool strip attached to an image pin while it is in edit mode.
/// Lives in a child panel so it never covers the image or shrinks with it.
final class AnnotationToolbar: AttachedToolbar, NSComboBoxDelegate {
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
    private let spotlightShapeControl = FirstMouseSegmentedControl()
    private let highlightModeControl = FirstMouseSegmentedControl()
    private let textStyleControl = FirstMouseSegmentedControl()
    private var preferredRedactionTool: AnnotationTool = .mosaic
    private var preferredRedactionStyle: AnnotationRedactionStyle = .mosaic
    private let familyPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizeCombo = FirstMouseComboBox()
    private let sizeStepper = FirstMouseStepper()
    private var isSyncing = false

    private static let presetFontSizes: [Int] = [10, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 64, 72, 96]

    private weak var canvas: AnnotationCanvasView?
    private weak var pin: ImagePinView?

    private static let tools: [AnnotationTool] = [
        .select, .rectangle, .ellipse, .arrow, .line, .freehand, .text, .counter, .highlight, .mosaic, .spotlight, .crop
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

    private func configureSegmented(
        _ control: NSSegmentedControl,
        segments: [(symbol: String, label: String, tooltip: String)],
        action: Selector
    ) {
        control.segmentCount = segments.count
        control.trackingMode = .selectOne
        control.controlSize = .small
        control.segmentStyle = .rounded
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        for (index, item) in segments.enumerated() {
            control.setImage(
                NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.label)?
                    .withSymbolConfiguration(iconConfig),
                forSegment: index
            )
            control.setToolTip(item.tooltip, forSegment: index)
            control.setWidth(28, forSegment: index)
        }
        control.selectedSegment = 0
        control.target = self
        control.action = action
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        control.widthAnchor.constraint(equalToConstant: control.fittingSize.width).isActive = true
        control.isHidden = true
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

        configureSegmented(
            redactionModeControl,
            segments: [
                (AnnotationTool.mosaic.symbol, "Mosaic", "Mosaic (M)"),
                ("aqi.medium", "Secure Blur", "Secure Blur"),
                (AnnotationTool.blur.symbol, "Solid Fill", "Solid Fill (B)")
            ],
            action: #selector(redactionModeChanged)
        )

        configureSegmented(
            spotlightShapeControl,
            segments: [
                ("rectangle", "Rectangle", "Rectangle Spotlight"),
                ("oval", "Ellipse", "Ellipse Spotlight")
            ],
            action: #selector(spotlightShapeChanged)
        )

        configureSegmented(
            highlightModeControl,
            segments: [
                ("rectangle", "Rectangle", "Rectangle Highlight"),
                ("scribble.variable", "Freehand", "Freehand Highlight")
            ],
            action: #selector(highlightModeChanged)
        )

        configureSegmented(
            textStyleControl,
            segments: [
                ("textformat", "Plain Text", "Plain Text"),
                ("a.square.fill", "Boxed Text", "Boxed Text"),
                ("a.square", "Outlined Text", "Outlined Text")
            ],
            action: #selector(textStyleChanged)
        )

        colorSwatch.color = Preferences.shared.annotationColor
        colorSwatch.onColorChange = { [weak self] color in
            guard let self, let canvas = self.canvas else { return }
            if canvas.selectedAnnotation == nil {
                Preferences.shared.annotationColor = color
            }
            canvas.updateSelectedStyle { $0.colorHex = color.hexString }
        }
        properties.orientation = .horizontal
        properties.alignment = .centerY
        properties.distribution = .fill
        properties.spacing = 6
        properties.setHuggingPriority(.required, for: .horizontal)
        properties.addArrangedSubview(redactionModeControl)
        properties.addArrangedSubview(spotlightShapeControl)
        properties.addArrangedSubview(highlightModeControl)
        properties.addArrangedSubview(colorSwatch)

        fontControls.orientation = .horizontal
        fontControls.alignment = .centerY
        fontControls.distribution = .fill
        fontControls.spacing = 4
        fontControls.setHuggingPriority(.required, for: .horizontal)
        fontControls.addArrangedSubview(textStyleControl)
        familyPopUp.addItems(withTitles: NSFontManager.shared.availableFontFamilies)
        familyPopUp.target = self
        familyPopUp.action = #selector(fontFamilyChanged)
        familyPopUp.controlSize = .small
        familyPopUp.font = .systemFont(ofSize: 11)
        familyPopUp.toolTip = "Text Font"
        familyPopUp.translatesAutoresizingMaskIntoConstraints = false
        familyPopUp.widthAnchor.constraint(equalToConstant: 120).isActive = true
        fontControls.addArrangedSubview(familyPopUp)

        sizeCombo.addItems(withObjectValues: Self.presetFontSizes)
        sizeCombo.isEditable = true
        sizeCombo.completes = false
        sizeCombo.delegate = self
        sizeCombo.target = self
        sizeCombo.action = #selector(fontSizeChanged)
        sizeCombo.controlSize = .small
        sizeCombo.font = .systemFont(ofSize: 11)
        sizeCombo.toolTip = "Text Size"
        sizeCombo.translatesAutoresizingMaskIntoConstraints = false
        sizeCombo.widthAnchor.constraint(equalToConstant: 54).isActive = true
        fontControls.addArrangedSubview(sizeCombo)

        sizeStepper.minValue = 6
        sizeStepper.maxValue = 400
        sizeStepper.increment = 2
        sizeStepper.valueWraps = false
        sizeStepper.controlSize = .small
        sizeStepper.target = self
        sizeStepper.action = #selector(fontSizeStepped)
        sizeStepper.toolTip = "Adjust Text Size"
        sizeStepper.translatesAutoresizingMaskIntoConstraints = false
        fontControls.addArrangedSubview(sizeStepper)
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
        isSyncing = true
        defer { isSyncing = false }

        if canvas.tool.isRedaction {
            preferredRedactionTool = canvas.tool
            if let explicit = canvas.style.redactionStyle {
                preferredRedactionStyle = explicit
            } else {
                preferredRedactionStyle = canvas.tool == .blur ? .solid : .mosaic
            }
        }
        for (tool, button) in toolButtons {
            let active = tool == canvas.tool || (tool == .mosaic && canvas.tool.isRedaction)
            button.contentTintColor = active ? .controlAccentColor : .labelColor
        }

        // Controls mirror the active/selected annotation's own style; falling back
        // to the pin's current style when nothing is selected.
        let selected = canvas.activeAnnotation
        let selectedText = selected?.tool == .text ? selected : nil
        let effectiveStyle = selected?.style ?? canvas.style
        colorSwatch.setColorSilently(effectiveStyle.color)
        widthSlider.doubleValue = Double(effectiveStyle.lineWidth)

        let effectiveTool = selected?.tool ?? canvas.tool
        properties.isHidden = effectiveTool == .select || effectiveTool == .crop

        let redactionStyle: AnnotationRedactionStyle = {
            if let selected, selected.tool.isRedaction {
                return selected.effectiveRedactionStyle
            }
            if let explicit = canvas.style.redactionStyle {
                return explicit
            }
            return effectiveTool == .blur ? .solid : .mosaic
        }()
        redactionModeControl.isHidden = !effectiveTool.isRedaction
        if effectiveTool.isRedaction {
            switch redactionStyle {
            case .mosaic: redactionModeControl.selectedSegment = 0
            case .blur: redactionModeControl.selectedSegment = 1
            case .solid: redactionModeControl.selectedSegment = 2
            }
        }

        spotlightShapeControl.isHidden = effectiveTool != .spotlight
        if effectiveTool == .spotlight {
            let shape = selected?.effectiveSpotlightShape ?? canvas.style.spotlightShape ?? .rectangle
            spotlightShapeControl.selectedSegment = shape == .ellipse ? 1 : 0
        }

        highlightModeControl.isHidden = effectiveTool != .highlight
        let highlightMode = selected?.effectiveHighlightMode ?? canvas.style.highlightMode ?? .rectangle
        if effectiveTool == .highlight {
            highlightModeControl.selectedSegment = highlightMode == .freehand ? 1 : 0
        }

        let isText = effectiveTool == .text || selectedText != nil
        textStyleControl.isHidden = !isText
        if isText {
            let textStyle = selected?.effectiveTextStyle ?? canvas.style.textStyle ?? .standard
            switch textStyle {
            case .standard: textStyleControl.selectedSegment = 0
            case .box: textStyleControl.selectedSegment = 1
            case .outline: textStyleControl.selectedSegment = 2
            }
        }

        colorSwatch.isHidden = effectiveTool == .spotlight
            || (effectiveTool.isRedaction && redactionStyle != .solid)
        fontControls.isHidden = !isText && effectiveTool != .counter
        familyPopUp.isHidden = effectiveTool == .counter

        let hidesSlider = effectiveTool == .text
            || effectiveTool == .counter
            || (effectiveTool.isRedaction && redactionStyle == .solid)
            || (effectiveTool == .highlight && highlightMode == .rectangle)
        widthSlider.isHidden = hidesSlider
        if effectiveTool.isRedaction {
            widthSlider.toolTip = redactionStyle == .blur ? "Blur Intensity" : "Mosaic Size"
        } else if effectiveTool == .spotlight {
            widthSlider.toolTip = "Spotlight Dimming"
        } else {
            widthSlider.toolTip = "Line Width"
        }

        let family = effectiveStyle.fontName ?? TextDefaults.font.familyName ?? "Helvetica"
        familyPopUp.selectItem(withTitle: family)
        if familyPopUp.selectedItem == nil { familyPopUp.setTitle(family) }
        let fontSize = effectiveStyle.fontSize
        sizeCombo.stringValue = fontSize == fontSize.rounded()
            ? String(Int(fontSize))
            : String(format: "%.1f", fontSize)
        sizeStepper.doubleValue = Double(fontSize)
        undoButton.isEnabled = canvas.store.undoManager.canUndo
        redoButton.isEnabled = canvas.store.undoManager.canRedo
        deleteButton.isEnabled = canvas.selectedAnnotation != nil
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
        reposition()
    }

    // MARK: - Actions

    @objc private func selectTool(_ sender: NSButton) {
        guard AnnotationToolbar.tools.indices.contains(sender.tag), let canvas else { return }
        let chosen = AnnotationToolbar.tools[sender.tag]
        if chosen == .mosaic {
            canvas.style.redactionStyle = preferredRedactionStyle
            canvas.tool = preferredRedactionTool
        } else {
            canvas.tool = chosen
        }
        syncSelection()
    }

    @objc private func redactionModeChanged() {
        guard let canvas else { return }
        canvas.commitTextEditor()
        let styleChoice: AnnotationRedactionStyle
        let toolChoice: AnnotationTool
        switch redactionModeControl.selectedSegment {
        case 1:
            styleChoice = .blur
            toolChoice = .mosaic
        case 2:
            styleChoice = .solid
            toolChoice = .blur
        default:
            styleChoice = .mosaic
            toolChoice = .mosaic
        }
        preferredRedactionStyle = styleChoice
        preferredRedactionTool = toolChoice
        canvas.style.redactionStyle = styleChoice
        if var selected = canvas.selectedAnnotation, selected.tool.isRedaction {
            selected.tool = toolChoice
            selected.style.redactionStyle = styleChoice
            canvas.store.update(selected, actionName: "Change Redaction Style")
        } else {
            canvas.tool = toolChoice
        }
        syncSelection()
    }

    @objc private func spotlightShapeChanged() {
        let shape: AnnotationSpotlightShape = spotlightShapeControl.selectedSegment == 1 ? .ellipse : .rectangle
        canvas?.updateSelectedStyle { $0.spotlightShape = shape }
        syncSelection()
    }

    @objc private func highlightModeChanged() {
        let mode: AnnotationHighlightMode = highlightModeControl.selectedSegment == 1 ? .freehand : .rectangle
        canvas?.style.highlightMode = mode
        syncSelection()
    }

    @objc private func textStyleChanged() {
        let styleChoice: AnnotationTextStyle
        switch textStyleControl.selectedSegment {
        case 1: styleChoice = .box
        case 2: styleChoice = .outline
        default: styleChoice = .standard
        }
        canvas?.updateSelectedStyle { $0.textStyle = styleChoice }
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
        guard !isSyncing, let family = familyPopUp.titleOfSelectedItem, let canvas else { return }
        canvas.updateSelectedStyle { $0.fontName = family }
        syncSelection()
        canvas.restoreKeyboardFocus()
    }

    private func applyFontSize(_ value: CGFloat) {
        guard let canvas, value >= 6, value <= 400 else { return syncSelection() }
        if canvas.selectedAnnotation == nil {
            Preferences.shared.annotationFontSize = Double(value)
        }
        canvas.updateSelectedStyle { $0.fontSize = value }
        syncSelection()
        canvas.restoreKeyboardFocus()
    }

    @objc private func fontSizeChanged() {
        guard !isSyncing else { return }
        let raw = sizeCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = Double(raw) ?? sizeCombo.doubleValue
        applyFontSize(CGFloat(parsed))
    }

    @objc private func fontSizeStepped() {
        guard !isSyncing else { return }
        applyFontSize(CGFloat(sizeStepper.doubleValue.rounded()))
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard !isSyncing else { return }
        if let selectedObject = sizeCombo.objectValueOfSelectedItem,
           let number = selectedObject as? NSNumber {
            applyFontSize(CGFloat(number.doubleValue))
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.fontSizeChanged()
        }
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

private final class FirstMouseComboBox: NSComboBox {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class FirstMouseStepper: NSStepper {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
