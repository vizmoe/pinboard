import AppKit

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let manager = PinWindowManager.shared
    private var menuBarController: MenuBarController?
    private lazy var settingsWindowController = SettingsWindowController()
    private lazy var historyWindowController = HistoryWindowController()

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        AppMenu.install()
        manager.onHistoryError = { error in
            NSLog("Pinboard history update failed: %@", error.localizedDescription)
            Toast.show("Couldn't update pin history", duration: 3)
        }
        manager.historyStore = .shared
        manager.pruneHistoryIfDue(force: true)
        HotKeyManager.shared.applyFromPreferences()
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: Preferences.didChange, object: nil
        )
        menuBarController = MenuBarController(manager: manager) { [weak self] in
            self?.showSettings()
        }
        menuBarController?.onOpenHistory = { [weak self] in self?.showHistory() }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        manager.flushAllHistorySyncs()
        HotKeyManager.shared.unregister()
    }

    private var lastRetention: (mode: Preferences.HistoryRetention, days: Double) = (.days30, 30)

    @objc private func preferencesChanged() {
        HotKeyManager.shared.applyFromPreferences()
        // Retention changes take effect on existing records immediately;
        // other preference edits must not trigger a directory scan.
        let retention = (mode: Preferences.shared.historyRetention, days: Preferences.shared.historyCustomDays)
        if retention != lastRetention {
            lastRetention = retention
            manager.pruneHistoryIfDue(force: true)
        }
    }

    func showHistory() {
        NSApp.activate(ignoringOtherApps: true)
        historyWindowController.show()
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

    @objc func hideAllPins(_ sender: Any?) {
        manager.hideAll()
    }

    @objc func closeFocusedPin(_ sender: Any?) {
        focusedPin()?.closePin()
    }

    @objc func hideFocusedPin(_ sender: Any?) {
        focusedPin()?.hidePin()
        manager.notifyChange()
    }

    private func focusedPin() -> PinWindowController? {
        (NSApp.keyWindow as? PinPanel)?.pinController
    }
}
