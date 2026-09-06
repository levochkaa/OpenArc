import AppKit
import SwiftUI

// MARK: - BrowserTabSwitcherEventObserver

struct BrowserTabSwitcherEventObserver: NSViewRepresentable {
    let isEnabled: Bool
    let onTab: (Bool) -> Bool
    let onCommit: () -> Bool
    let onCancel: () -> Bool

    func makeNSView(context _: Context) -> BrowserTabSwitcherEventNSView {
        let view = BrowserTabSwitcherEventNSView()
        view.isEnabled = isEnabled
        view.onTab = onTab
        view.onCommit = onCommit
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: BrowserTabSwitcherEventNSView, context _: Context) {
        nsView.isEnabled = isEnabled
        nsView.onTab = onTab
        nsView.onCommit = onCommit
        nsView.onCancel = onCancel
    }
}

// MARK: - BrowserTabSwitcherEventNSView

final class BrowserTabSwitcherEventNSView: NSView {
    // MARK: Internal

    var isEnabled = false
    var onTab: (Bool) -> Bool = { _ in false }
    var onCommit: () -> Bool = { false }
    var onCancel: () -> Bool = { false }

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

    // MARK: Private

    private static let tabKeyCode: UInt16 = 48
    private static let escapeKeyCode: UInt16 = 53

    private let localMonitorCleanup = BrowserTabSwitcherMonitorCleanup()

    private static func isOptionTabEvent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.keyCode == tabKeyCode
            && modifiers.contains(.option)
            && !modifiers.contains(.command)
            && !modifiers.contains(.control)
    }

    private static func isOptionReleasedEvent(_ event: NSEvent) -> Bool {
        !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.option)
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
            if Self.isOptionTabEvent(event) {
                return onTab(event.modifierFlags.contains(.shift)) ? nil : event
            }

            if event.keyCode == Self.escapeKeyCode {
                return onCancel() ? nil : event
            }

            return event
        case .flagsChanged:
            return Self.isOptionReleasedEvent(event) && onCommit() ? nil : event
        default:
            return event
        }
    }
}

// MARK: - BrowserTabSwitcherMonitorCleanup

private final class BrowserTabSwitcherMonitorCleanup: @unchecked Sendable {
    // MARK: Lifecycle

    deinit {
        remove()
    }

    // MARK: Internal

    var monitor: Any?

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

// MARK: - BrowserTabSwitcherOverlay

/// Temporary mounting adapter; rendering and layout belong to AppKit.
struct BrowserTabSwitcherOverlay: NSViewRepresentable {
    let state: BrowserChromeModel.TabSwitcherState

    func makeNSView(context _: Context) -> BrowserTabSwitcherNSView {
        let view = BrowserTabSwitcherNSView()
        view.update(state: state)
        return view
    }

    func updateNSView(_ view: BrowserTabSwitcherNSView, context _: Context) {
        view.update(state: state)
    }
}
