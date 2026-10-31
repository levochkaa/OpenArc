// BrowserPageTopWindowDrag.swift

import AppKit

// MARK: - BrowserPageTopWindowDrag

/// "Allow window dragging from the top of websites": with nothing above
/// the page, dragging its top strip moves the window, while a click there
/// still reaches the page. The press waits until the pointer moves, which
/// starts the window drag, or the button comes up, which hands the page the
/// press and then the release. Its owner stops it before going away.
@MainActor final class BrowserPageTopWindowDrag {
    // MARK: Internal

    static let regionHeight: CGFloat = 36
    /// Movement that turns a press into a window drag.
    static let dragThreshold: CGFloat = 3

    /// The strip in window coordinates, or nil while something sits above the
    /// page or the setting is off.
    var region: () -> NSRect? = { nil }
    /// Only presses that would reach this view, the page, are held back.
    var pageView: () -> NSView? = { nil }
    var performDrag: (NSWindow, NSEvent) -> Void = { window, event in window.performDrag(with: event) }
    var replay: (NSWindow, NSEvent) -> Void = { window, event in window.sendEvent(event) }

    private(set) var pendingPress: NSEvent?

    // MARK: Private

    private weak var window: NSWindow?
    private var monitor: Any?
    private var isReplaying = false

    func start(in window: NSWindow?) {
        self.window = window
        guard monitor == nil, window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) {
            [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        pendingPress = nil
        window = nil
    }

    /// The event to deliver, or nil to hold it back.
    func handle(_ event: NSEvent) -> NSEvent? {
        guard !isReplaying, let window, event.window === window else { return event }
        switch event.type {
        case .leftMouseDown:
            pendingPress = nil
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard event.clickCount == 1, modifiers.isEmpty, let region = region(),
                  region.contains(event.locationInWindow), let page = pageView(),
                  let hit = window.contentView?.hitTest(
                      window.contentView?.superview?.convert(event.locationInWindow, from: nil)
                          ?? event.locationInWindow,
                  ),
                  hit === page || hit.isDescendant(of: page)
            else { return event }
            pendingPress = event
            return nil
        case .leftMouseDragged:
            guard let press = pendingPress else { return event }
            let dx = event.locationInWindow.x - press.locationInWindow.x
            let dy = event.locationInWindow.y - press.locationInWindow.y
            guard dx * dx + dy * dy > Self.dragThreshold * Self.dragThreshold else { return nil }
            pendingPress = nil
            performDrag(window, press)
            return nil
        case .leftMouseUp:
            guard let press = pendingPress else { return event }
            pendingPress = nil
            isReplaying = true
            replay(window, press)
            isReplaying = false
            return event
        default:
            return event
        }
    }
}
