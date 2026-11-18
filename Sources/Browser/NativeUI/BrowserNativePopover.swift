// BrowserNativePopover.swift

import AppKit

/// Gives native popovers Escape dismissal even when their contents have no enabled first responder.
final class BrowserNativePopover: NSPopover {
    // MARK: Internal

    /// Asked first on Escape; true means it handled the key and the popover stays open.
    var escapeHandler: (() -> Bool)?

    // MARK: Private

    private weak var anchorWindow: NSWindow?
    private var keyMonitor: Any?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didClose),
            name: NSPopover.didCloseNotification,
            object: self,
        )
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }
    isolated deinit { removeKeyMonitor() }

    override func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {
        anchorWindow = positioningView.window
        super.show(relativeTo: positioningRect, of: positioningView, preferredEdge: preferredEdge)
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, isShown, event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  event.window === anchorWindow || event.window === contentViewController?.view.window
            else { return event }
            if escapeHandler?() != true {
                performClose(nil)
            }
            return nil
        }
    }

    @objc private func didClose() { removeKeyMonitor() }
    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}
