import AppKit
import SwiftUI

final class HistoryWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: HistoryViewModel?

    func show() {
        if window == nil {
            let model = HistoryViewModel()
            self.model = model
            let hosting = NSHostingController(rootView: HistoryView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Pinboard History"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
    }
}
