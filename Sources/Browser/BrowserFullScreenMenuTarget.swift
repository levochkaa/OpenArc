// BrowserFullScreenMenuTarget.swift

import AppKit

// MARK: - BrowserFullScreenMenuTarget

/// Target of View › Enter Full Screen. The item keeps AppKit's action so AppKit
/// adds no item of its own, but a child window with the keyboard, such as docked
/// Developer Tools or a Peek card, would take full screen alone; the window it
/// belongs to does instead.
@MainActor final class BrowserFullScreenMenuTarget: NSObject, NSMenuItemValidation {
    /// The key window, or the main one, raised to the window it is a child of.
    static var targetWindow: NSWindow? {
        topLevelWindow(of: NSApp.keyWindow ?? NSApp.mainWindow)
    }

    static func topLevelWindow(of window: NSWindow?) -> NSWindow? {
        var window = window
        while let parent = window?.parent {
            window = parent
        }
        return window
    }

    @objc func toggleFullScreen(_ sender: Any?) {
        Self.targetWindow?.toggleFullScreen(sender)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(toggleFullScreen(_:)) else { return true }
        let window = Self.targetWindow
        item.title = window?.styleMask.contains(.fullScreen) == true
            ? BrowserStrings.menuExitFullScreen
            : BrowserStrings.menuEnterFullScreen
        return window?.collectionBehavior.contains(.fullScreenNone) == false
    }
}
