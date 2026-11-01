// BrowserTabSwitcherView.swift

import AppKit

// MARK: - BrowserTabSwitcherEventNSView

final class BrowserTabSwitcherEventNSView: NSView {
    // MARK: Private

    private static let escapeKeyCode: UInt16 = 53

    // MARK: Internal

    var isEnabled = false
    var onTab: (Bool) -> Bool = { _ in false }
    var onCommit: () -> Bool = { false }
    var onCancel: () -> Bool = { false }

    private let localMonitorCleanup = BrowserTabSwitcherMonitorCleanup()

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window == nil {
            removeLocalMonitor()
        } else {
            installLocalMonitorIfNeeded()
        }
    }

    private func installLocalMonitorIfNeeded() {
        guard localMonitorCleanup.monitor == nil else {
            return
        }

        localMonitorCleanup.set(NSEvent.addLocalMonitorForEvents(matching: [
            .keyDown,
            .flagsChanged,
        ]) { [weak self] event in
            guard let self else {
                return event
            }

            return handle(event)
        })
    }

    private func removeLocalMonitor() {
        localMonitorCleanup.remove()
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard
            isEnabled,
            let window,
            event.window == nil || event.window === window
        else {
            return event
        }

        switch event.type {
        case .keyDown:
            if BrowserTabSwitcherKeys.isSwitcherTab(event) {
                return onTab(event.modifierFlags.contains(.shift)) ? nil : event
            }

            if event.keyCode == Self.escapeKeyCode {
                return onCancel() ? nil : event
            }

            return event
        case .flagsChanged:
            return BrowserTabSwitcherKeys.isControlReleased(event) && onCommit() ? nil : event
        default:
            return event
        }
    }
}

// MARK: - BrowserTabSwitcherMonitorCleanup

private final class BrowserTabSwitcherMonitorCleanup: @unchecked Sendable {
    // MARK: Internal

    var monitor: Any?

    deinit {
        remove()
    }

    func set(_ monitor: Any?) {
        remove()
        self.monitor = monitor
    }

    func remove() {
        guard let monitor else {
            return
        }

        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
}
