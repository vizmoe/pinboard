import AppKit
import Combine

/// User defaults backed settings. Changes are published for SwiftUI and
/// broadcast through `Preferences.didChange` for AppKit observers.
final class Preferences: ObservableObject {
    static let shared = Preferences()
    static let didChange = Notification.Name("PinboardPreferencesDidChange")

    private enum Key {
        static let shadow = "window.shadow"
        static let placeAtMouse = "window.placeAtMouse"
        static let topLevel = "window.topLevel"
        static let allSpaces = "window.allSpaces"
        static let textPadding = "text.padding"
        static let textMode = "text.mode"
        static let markdownTheme = "markdown.theme"
        static let annotationColor = "annotation.color"
        static let annotationLineWidth = "annotation.lineWidth"
        static let annotationFontSize = "annotation.fontSize"
        static let historyRetention = "history.retention"
        static let historyCustomDays = "history.customDays"
        static let hotkeyEnabled = "hotkey.enabled"
        static let hotkeyKeyCode = "hotkey.keyCode"
        static let hotkeyModifiers = "hotkey.modifiers"
    }

    enum TopLevel: String, CaseIterable, Identifiable {
        case floating
        case highest

        var id: String { rawValue }
        var windowLevel: NSWindow.Level {
            switch self {
            case .floating: return .floating
            case .highest: return NSWindow.Level(Int(CGWindowLevelForKey(.maximumWindow)) - 1)
            }
        }

        var localizedName: String {
            switch self {
            case .floating: return "Floating"
            case .highest: return "Topmost"
            }
        }
    }

    enum HistoryRetention: String, CaseIterable, Identifiable {
        case days7, days30, days90, forever, custom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .days7: return "7 Days"
            case .days30: return "30 Days"
            case .days90: return "90 Days"
            case .forever: return "Forever"
            case .custom: return "Custom"
            }
        }
    }

    private let defaults: UserDefaults
    private var isLoading = false

    @Published var showShadow: Bool = true { didSet { persist(showShadow, Key.shadow) } }
    @Published var placeNewWindowAtMouse: Bool = true { didSet { persist(placeNewWindowAtMouse, Key.placeAtMouse) } }
    @Published var topLevel: TopLevel = .floating { didSet { persist(topLevel.rawValue, Key.topLevel) } }
    @Published var showOnAllSpaces: Bool = true { didSet { persist(showOnAllSpaces, Key.allSpaces) } }
    @Published var textPadding: Double = 12 { didSet { persist(textPadding, Key.textPadding) } }
    /// Global default for text pins. New pins and pins that were never
    /// switched individually follow it; a per-window switch overrides it.
    @Published var textMode: TextContentMode = .richText { didSet { persist(textMode.rawValue, Key.textMode) } }
    /// Colour palette for rendered Markdown pins. Display-only: the pins'
    /// canonical content is always the Markdown source.
    @Published var markdownTheme: MarkdownTheme = .standard { didSet { persist(markdownTheme.rawValue, Key.markdownTheme) } }
    @Published var annotationColorHex: String = "#FF3B30" { didSet { persist(annotationColorHex, Key.annotationColor) } }
    @Published var annotationLineWidth: Double = 3 { didSet { persist(annotationLineWidth, Key.annotationLineWidth) } }
    @Published var annotationFontSize: Double = 18 { didSet { persist(annotationFontSize, Key.annotationFontSize) } }

    // History
    @Published var historyRetention: HistoryRetention = .days30 { didSet { persist(historyRetention.rawValue, Key.historyRetention) } }
    @Published var historyCustomDays: Double = 30 { didSet { persist(historyCustomDays, Key.historyCustomDays) } }

    // Global hotkey (Carbon modifiers: cmdKey|shiftKey|optionKey|controlKey)
    static let defaultHotkeyKeyCode: UInt32 = 35 // kVK_ANSI_P
    static let defaultHotkeyModifiers: UInt32 = 0x0100 | 0x0200 | 0x0800 | 0x1000
    @Published var hotkeyEnabled: Bool = true { didSet { persist(hotkeyEnabled, Key.hotkeyEnabled) } }
    @Published var hotkeyKeyCode: UInt32 = Preferences.defaultHotkeyKeyCode { didSet { persist(Int(hotkeyKeyCode), Key.hotkeyKeyCode) } }
    @Published var hotkeyModifiers: UInt32 = Preferences.defaultHotkeyModifiers { didSet { persist(Int(hotkeyModifiers), Key.hotkeyModifiers) } }

    /// The cutoff date for pruning, or nil when history is kept forever.
    var historyRetentionCutoff: Date? {
        let days: Double
        switch historyRetention {
        case .days7: days = 7
        case .days30: days = 30
        case .days90: days = 90
        case .forever: return nil
        case .custom: days = max(historyCustomDays, 1)
        }
        return Date().addingTimeInterval(-days * 86_400)
    }

    var annotationColor: NSColor {
        get { NSColor(hex: annotationColorHex) ?? .systemRed }
        set { annotationColorHex = newValue.hexString }
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isLoading = true
        if let value = defaults.object(forKey: Key.shadow) as? Bool { showShadow = value }
        if let value = defaults.object(forKey: Key.placeAtMouse) as? Bool { placeNewWindowAtMouse = value }
        if let raw = defaults.string(forKey: Key.topLevel), let value = TopLevel(rawValue: raw) { topLevel = value }
        if let value = defaults.object(forKey: Key.allSpaces) as? Bool { showOnAllSpaces = value }
        if let value = defaults.object(forKey: Key.textPadding) as? Double { textPadding = value }
        if let raw = defaults.string(forKey: Key.textMode), let value = TextContentMode(rawValue: raw) { textMode = value }
        if let raw = defaults.string(forKey: Key.markdownTheme), let value = MarkdownTheme(rawValue: raw) { markdownTheme = value }
        if let value = defaults.string(forKey: Key.annotationColor) { annotationColorHex = value }
        if let value = defaults.object(forKey: Key.annotationLineWidth) as? Double { annotationLineWidth = value }
        if let value = defaults.object(forKey: Key.annotationFontSize) as? Double { annotationFontSize = value }
        if let raw = defaults.string(forKey: Key.historyRetention), let value = HistoryRetention(rawValue: raw) { historyRetention = value }
        if let value = defaults.object(forKey: Key.historyCustomDays) as? Double { historyCustomDays = value }
        if defaults.object(forKey: Key.hotkeyEnabled) != nil { hotkeyEnabled = defaults.bool(forKey: Key.hotkeyEnabled) }
        if let value = defaults.object(forKey: Key.hotkeyKeyCode) as? Int { hotkeyKeyCode = UInt32(value) }
        if let value = defaults.object(forKey: Key.hotkeyModifiers) as? Int { hotkeyModifiers = UInt32(value) }
        isLoading = false
    }

    private func persist(_ value: Any, _ key: String) {
        guard !isLoading else { return }
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Preferences.didChange, object: self)
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        let hasAlpha = text.count == 8
        let r = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    var hexString: String {
        let color = usingColorSpace(.sRGB) ?? self
        let r = Int((color.redComponent * 255).rounded())
        let g = Int((color.greenComponent * 255).rounded())
        let b = Int((color.blueComponent * 255).rounded())
        let a = Int((color.alphaComponent * 255).rounded())
        return a == 255 ? String(format: "#%02X%02X%02X", r, g, b) : String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }
}
