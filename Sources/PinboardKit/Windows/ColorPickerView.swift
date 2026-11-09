import AppKit

/// Compact colour palette presented by `ColorSwatchButton` in an `NSPopover`.
///
/// Presets, the optional clear row ("None" / "Default") and HEX input all
/// funnel into `onPick` / `onClear`, so foreground and background colours go
/// through the same path. All colours are handled in sRGB.
final class ColorPickerView: NSView, NSTextFieldDelegate {
    static let presets: [(name: String, color: NSColor)] = [
        ("Black", .black), ("White", .white), ("Gray", .systemGray),
        ("Red", .systemRed), ("Orange", .systemOrange), ("Yellow", .systemYellow),
        ("Green", .systemGreen), ("Cyan", .systemCyan), ("Blue", .systemBlue),
        ("Purple", .systemPurple), ("Pink", .systemPink)
    ]
    static let columns = 4
    static let swatchSize = NSSize(width: 26, height: 22)

    /// Live callback for every chosen colour (preset or valid HEX).
    var onPick: ((NSColor) -> Void)?
    /// Fired by the optional clear row; only shown when `clearTitle` was given.
    var onClear: (() -> Void)?

    /// Highlights the matching preset; updated after every pick.
    var selectedColor: NSColor? {
        didSet { syncSelection() }
    }

    private(set) var presetSwatches: [PresetSwatch] = []
    private(set) var clearButton: NSButton?
    private(set) var hexField: NSTextField!
    private let hexPreview = ColorPreviewView()

    init(clearTitle: String?) {
        super.init(frame: .zero)
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        var presets = ColorPickerView.presets
        while !presets.isEmpty {
            let chunk = Array(presets.prefix(ColorPickerView.columns))
            presets.removeFirst(min(ColorPickerView.columns, presets.count))
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 5
            for preset in chunk {
                let swatch = PresetSwatch(color: preset.color)
                swatch.toolTip = preset.name
                swatch.target = self
                swatch.action = #selector(presetClicked(_:))
                presetSwatches.append(swatch)
                row.addArrangedSubview(swatch)
            }
            root.addArrangedSubview(row)
        }

        if let clearTitle {
            let button = NSButton(title: clearTitle, target: self, action: #selector(clearClicked))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            clearButton = button
            root.addArrangedSubview(button)
        }

        let hexRow = NSStackView()
        hexRow.orientation = .horizontal
        hexRow.spacing = 6
        hexRow.alignment = .centerY

        hexField = NSTextField()
        hexField.placeholderString = "#RRGGBB"
        hexField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        hexField.controlSize = .small
        hexField.delegate = self
        hexField.toolTip = "HEX colour (#RRGGBB or #RRGGBBAA)"
        hexField.translatesAutoresizingMaskIntoConstraints = false
        hexField.widthAnchor.constraint(equalToConstant: 96).isActive = true
        hexRow.addArrangedSubview(hexField)

        hexPreview.toolTip = "Preview"
        hexRow.addArrangedSubview(hexPreview)
        root.addArrangedSubview(hexRow)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    @objc private func presetClicked(_ sender: PresetSwatch) {
        selectedColor = sender.fill
        hexField.stringValue = sender.fill.hexString
        hexField.textColor = .labelColor
        hexPreview.fill = sender.fill
        onPick?(sender.fill)
    }

    @objc private func clearClicked() {
        selectedColor = nil
        onClear?()
    }

    // MARK: - HEX input

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSTextField === hexField else { return }
        applyHexField()
    }

    /// Parses the HEX field. Valid input applies immediately; invalid input is
    /// flagged without reporting a colour.
    @discardableResult
    func applyHexField() -> Bool {
        guard let parsed = NSColor(hex: hexField.stringValue) else {
            hexField.textColor = .systemRed
            hexField.toolTip = "Invalid HEX colour (use #RRGGBB or #RRGGBBAA)"
            return false
        }
        hexField.textColor = .labelColor
        hexField.toolTip = "HEX colour (#RRGGBB or #RRGGBBAA)"
        hexPreview.fill = parsed
        selectedColor = parsed
        onPick?(parsed)
        return true
    }

    // MARK: - Selection state

    private func syncSelection() {
        let selected = selectedColor?.usingColorSpace(.sRGB)
        for swatch in presetSwatches {
            swatch.isChosen = swatch.matches(selected)
        }
        if let selected {
            hexField.stringValue = selected.hexString
            hexField.textColor = .labelColor
            hexPreview.fill = selected
        }
    }
}

/// One preset swatch in the grid; draws a rounded colour tile with a ring
/// around the currently selected colour.
final class PresetSwatch: NSButton {
    let fill: NSColor
    var isChosen = false { didSet { needsDisplay = true } }

    init(color: NSColor, size: NSSize = ColorPickerView.swatchSize) {
        self.fill = color
        super.init(frame: NSRect(origin: .zero, size: size))
        isBordered = false
        title = ""
        imagePosition = .noImage
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width),
            heightAnchor.constraint(equalToConstant: size.height)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func matches(_ other: NSColor?) -> Bool {
        guard let mine = fill.usingColorSpace(.sRGB), let other else { return false }
        return abs(mine.redComponent - other.redComponent) < 0.01
            && abs(mine.greenComponent - other.greenComponent) < 0.01
            && abs(mine.blueComponent - other.blueComponent) < 0.01
            && abs(mine.alphaComponent - other.alphaComponent) < 0.01
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        (fill.usingColorSpace(.sRGB) ?? fill).setFill()
        path.fill()
        if isChosen {
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 2
        } else {
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
        }
        path.stroke()
    }
}

/// Small read-only colour preview next to the HEX field.
final class ColorPreviewView: NSView {
    var fill: NSColor = .clear { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        if fill.alphaComponent < 0.01 {
            NSColor.textBackgroundColor.setFill()
            path.fill()
            NSColor.systemRed.withAlphaComponent(0.8).setStroke()
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: rect.minX + 2, y: rect.minY + 2))
            slash.line(to: NSPoint(x: rect.maxX - 2, y: rect.maxY - 2))
            slash.lineWidth = 1.5
            slash.stroke()
        } else {
            fill.setFill()
            path.fill()
        }
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
