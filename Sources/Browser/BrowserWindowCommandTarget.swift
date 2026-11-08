// BrowserWindowCommandTarget.swift

import AppKit

// MARK: - BrowserWindowCommandTarget

/// Target of Enter Full Screen, Minimize and Zoom. The items keep AppKit's
/// actions so AppKit adds no items of its own, but a child window with the
/// keyboard, such as docked Developer Tools or a Peek card, would act alone;
/// the window it belongs to does instead. Browser windows are borderless, so
/// AppKit's perform versions, which press the missing title bar buttons, only
/// beep; these minimize directly and zoom to the screen's visible frame and back.
@MainActor final class BrowserWindowCommandTarget: NSObject, NSMenuItemValidation {
    /// The key window, or the main one, raised to the window it is a child of.
    static var targetWindow: NSWindow? {
        topLevelWindow(of: NSApp.keyWindow ?? NSApp.mainWindow)
    }

    /// Where each zoomed window without a title bar was before, to go back to.
    private var framesBeforeZoom = [ObjectIdentifier: NSRect]()

    static func topLevelWindow(of window: NSWindow?) -> NSWindow? {
        var window = window
        while let parent = window?.parent {
            window = parent
        }
        return window
    }

    static func frame(_ frame: NSRect, matches other: NSRect) -> Bool {
        abs(frame.minX - other.minX) < 1 && abs(frame.minY - other.minY) < 1
            && abs(frame.width - other.width) < 1 && abs(frame.height - other.height) < 1
    }

    @objc func toggleFullScreen(_ sender: Any?) {
        Self.targetWindow?.toggleFullScreen(sender)
    }

    @objc func performMiniaturize(_ sender: Any?) {
        Self.targetWindow?.miniaturize(sender)
    }

    @objc func performZoom(_ sender: Any?) {
        guard let window = Self.targetWindow else { return }
        guard !window.styleMask.contains(.titled) else {
            window.zoom(sender)
            return
        }
        // AppKit does not zoom a window without a title bar.
        guard let visible = window.screen?.visibleFrame else { return }
        let key = ObjectIdentifier(window)
        if let previous = framesBeforeZoom[key], Self.frame(window.frame, matches: visible) {
            framesBeforeZoom[key] = nil
            window.setFrame(previous, display: true, animate: true)
        } else {
            framesBeforeZoom[key] = window.frame
            window.setFrame(visible, display: true, animate: true)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let window = Self.targetWindow
        switch item.action {
        case #selector(toggleFullScreen(_:)):
            item.title = window?.styleMask.contains(.fullScreen) == true
                ? BrowserStrings.menuExitFullScreen
                : BrowserStrings.menuEnterFullScreen
            return window?.collectionBehavior.contains(.fullScreenNone) == false
        case #selector(performMiniaturize(_:)):
            return window?.styleMask.contains(.miniaturizable) == true
        case #selector(performZoom(_:)):
            return window?.styleMask.contains(.resizable) == true
                && window?.styleMask.contains(.fullScreen) == false
        default:
            return true
        }
    }
}
