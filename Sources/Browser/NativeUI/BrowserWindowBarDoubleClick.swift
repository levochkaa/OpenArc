// BrowserWindowBarDoubleClick.swift

import AppKit

extension NSWindow {
    /// A double click on the window's bar area does what System Settings ›
    /// Desktop & Dock asks of a title bar: zoom (the default), minimize or nothing.
    /// A second double click zooms back.
    func performBarDoubleClickAction(defaults: UserDefaults = .standard) {
        switch defaults.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize":
            miniaturize(nil)
        case "None":
            break
        default:
            zoom(nil)
        }
    }

    /// Drags the window from its bar, or acts on a double click there.
    func dragOrActOnBarClick(with event: NSEvent) {
        if event.clickCount == 2 {
            performBarDoubleClickAction()
        } else {
            performDrag(with: event)
        }
    }
}
