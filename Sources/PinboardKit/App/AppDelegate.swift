import AppKit

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let manager = PinWindowManager.shared
    private var menuBarController: MenuBarController?
    private lazy var settingsWindowController = SettingsWindowController()

    private var lastRetention: (mode: Preferences.HistoryRetention, days: Double)

    public override init() {
        lastRetention = (
            mode: Preferences.shared.historyRetention,
            days: Preferences.shared.historyCustomDays
        )
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        AppMenu.install()
        manager.onHistoryError = { error in
            NSLog("Pinboard history update failed: %@", error.localizedDescription)
            Toast.show("Couldn't update pin history", duration: 3)
        }
        manager.historyStore = .shared
        lastRetention = (
            mode: Preferences.shared.historyRetention,
            days: Preferences.shared.historyCustomDays
        )
        manager.pruneHistoryIfDue(force: true)
        HotKeyManager.shared.applyFromPreferences()
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: Preferences.didChange, object: nil
        )
        menuBarController = MenuBarController(manager: manager) { [weak self] in
            self?.showSettings()
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        manager.flushAllHistorySyncs()
        HotKeyManager.shared.unregister()
    }

    @objc func preferencesChanged() {
        HotKeyManager.shared.applyFromPreferences()
        // Retention changes take effect on existing records immediately;
        // other preference edits must not trigger a directory scan.
        let retention = (mode: Preferences.shared.historyRetention, days: Preferences.shared.historyCustomDays)
        if retention != lastRetention {
            lastRetention = retention
            manager.pruneHistoryIfDue(force: true)
        }
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { URLCommandRouter.handle($0, manager: manager) }
    }

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController.show()
    }

    // MARK: - Menu actions

    @objc func openSettings(_ sender: Any?) {
        showSettings()
    }

    @objc func hideAllPins(_ sender: Any?) {
        manager.hideAll()
    }

    @objc func closeFocusedPin(_ sender: Any?) {
        if let pin = focusedPin() {
            pin.closePin()
        } else {
            NSApp.keyWindow?.performClose(sender)
        }
    }

    @objc func hideFocusedPin(_ sender: Any?) {
        focusedPin()?.hidePin()
    }

    func focusedPin(for window: NSWindow? = NSApp.keyWindow) -> PinWindowController? {
        ((window as? PinPanel) ?? (window?.parent as? PinPanel))?.pinController
    }
}
