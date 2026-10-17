import AppKit
import SwiftUI

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(preferences: .shared))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Pinboard Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
    }
}
