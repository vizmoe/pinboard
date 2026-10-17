import AppKit

/// Colour control for pin toolbars.
///
/// Shows a compact `NSPopover` palette instead of the system `NSColorPanel`:
/// the shared panel is unusable here anyway (pin panels are non-activating,
/// so the well never activates), and an orphaned colour panel with a nil
/// target forwards `changeColor:` up the responder chain, letting one swatch
/// silently overwrite another attribute — e.g. a background pick rewriting
/// the text colour. The popover only reports through `onColorChange` /
/// `onClear`, so nothing can touch attributes the swatch does not own.
final class ColorSwatchButton: FirstMouseButton, NSPopoverDelegate {
    var color: NSColor = .labelColor {
        didSet { needsDisplay = true }
    }

    /// Called for every colour the user picks, live.
    var onColorChange: ((NSColor) -> Void)?
    /// Called when the popover's clear row is used (shown only when
    /// `clearTitle` is set, e.g. "None" / "Default").
    var onClear: (() -> Void)?
    /// Title of the optional clear row in the popover.
    var clearTitle: String?

    private var pickerPopover: NSPopover?
    private var pickerView: ColorPickerView?

    /// True while this swatch's popover is open.
    var isPicking: Bool { pickerPopover?.isShown ?? false }

    init(tooltip: String, size: NSSize = NSSize(width: 26, height: 22)) {
        super.init(frame: NSRect(origin: .zero, size: size))
        self.toolTip = tooltip
        isBordered = false
        title = ""
        imagePosition = .noImage
        target = self
        action = #selector(togglePicker)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width),
            heightAnchor.constraint(equalToConstant: size.height)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 3, dy: 4)
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        if color.alphaComponent < 0.01 {
            NSColor.textBackgroundColor.setFill()
            path.fill()
            NSColor.systemRed.withAlphaComponent(0.8).setStroke()
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: rect.minX + 2, y: rect.minY + 2))
            slash.line(to: NSPoint(x: rect.maxX - 2, y: rect.maxY - 2))
            slash.lineWidth = 1.5
            slash.stroke()
        } else {
            color.setFill()
            path.fill()
        }
        (isPicking ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isPicking ? 2 : 1
        path.stroke()
    }

    @objc private func togglePicker() {
        if isPicking { stopPicking() } else { showPicker() }
    }

    /// Opens the palette anchored to this swatch. Re-clicking the swatch or
    /// clicking anywhere outside closes it (transient popover).
    func showPicker() {
        let popover = NSPopover()
        let picker = ColorPickerView(clearTitle: clearTitle)
        picker.selectedColor = color
        picker.onPick = { [weak self] color in self?.applyPickedColor(color) }
        picker.onClear = { [weak self] in self?.applyClear() }
        let controller = NSViewController()
        controller.view = picker
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        pickerPopover = popover
        pickerView = picker
        // Needed so the popover window can take key status for the HEX field.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: bounds, of: self, preferredEdge: .minY)
        needsDisplay = true
    }

    /// Applies a colour reported by the palette.
    func applyPickedColor(_ newColor: NSColor) {
        color = newColor
        onColorChange?(newColor)
    }

    /// Applies the palette's clear row.
    func applyClear() {
        color = .clear
        onClear?()
    }

    /// Closes the popover, e.g. when the toolbar hides.
    func stopPicking() {
        pickerPopover?.close()
    }

    func popoverDidClose(_ notification: Notification) {
        pickerView = nil
        needsDisplay = true
    }

    /// Updates the swatch without reporting a change. A no-op while the
    /// popover is open, so state sync can't push a stale colour back over
    /// what the user is picking.
    func setColorSilently(_ newColor: NSColor) {
        guard !isPicking else { return }
        color = newColor
    }
}
