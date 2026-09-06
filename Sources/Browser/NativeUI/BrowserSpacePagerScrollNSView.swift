import AppKit

// MARK: - BrowserLocalMonitorCleanup

final class BrowserLocalMonitorCleanup: @unchecked Sendable {
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

// MARK: - BrowserSpacePagerScrollNSView

final class BrowserSpacePagerScrollNSView: NSView {
    // MARK: Lifecycle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Internal

    var isEnabled = false
    var onScrollDelta: (CGFloat) -> Void = { _ in }
    var onScrollReleased: () -> Void = {}
    var onScrollEnded: () -> Void = {}

    var isTrackingHorizontalScroll = false
    var didSendScrollRelease = false
    var scrollEndWorkItem: DispatchWorkItem?

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

    private let localMonitorCleanup = BrowserLocalMonitorCleanup()

    private func installLocalMonitorIfNeeded() {
        guard localMonitorCleanup.monitor == nil else {
            return
        }

        localMonitorCleanup.set(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleScrollWheel(event) ?? event
        })
    }

    private func handleScrollWheel(_ event: NSEvent) -> NSEvent? {
        guard
            isEnabled,
            let window,
            event.window === window,
            bounds.contains(convert(event.locationInWindow, from: nil))
        else {
            finishHorizontalScrollIfNeeded()
            return event
        }

        let horizontalDelta = event.scrollingDeltaX
        let verticalDelta = event.scrollingDeltaY
        guard isTrackingHorizontalScroll || isHorizontalScroll(horizontalDelta, verticalDelta) else {
            return event
        }

        if !isTrackingHorizontalScroll {
            isTrackingHorizontalScroll = true
            didSendScrollRelease = false
        }

        if horizontalDelta != 0, !didSendScrollRelease {
            onScrollDelta(horizontalDelta)
        }

        if scrollWasReleased(event) {
            sendScrollReleasedIfNeeded()
        }

        if scrollWasCancelled(event) || momentumScrollDidEnd(event) {
            finishHorizontalScrollIfNeeded()
        } else {
            scheduleScrollEndFallback()
        }

        return nil
    }

    private func isHorizontalScroll(_ horizontalDelta: CGFloat, _ verticalDelta: CGFloat) -> Bool {
        let horizontal = abs(horizontalDelta)
        let vertical = abs(verticalDelta)
        return horizontal > max(vertical * 1.08, 0.5)
    }

    private func scrollWasReleased(_ event: NSEvent) -> Bool {
        event.phase.contains(.ended)
    }

    private func scrollWasCancelled(_ event: NSEvent) -> Bool {
        event.phase.contains(.cancelled)
            || event.momentumPhase.contains(.cancelled)
    }

    private func momentumScrollDidEnd(_ event: NSEvent) -> Bool {
        event.momentumPhase.contains(.ended)
    }

    private func scheduleScrollEndFallback() {
        scrollEndWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.finishHorizontalScrollIfNeeded()
        }
        scrollEndWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    private func finishHorizontalScrollIfNeeded() {
        guard isTrackingHorizontalScroll else {
            return
        }

        sendScrollReleasedIfNeeded()
        scrollEndWorkItem?.cancel()
        scrollEndWorkItem = nil
        isTrackingHorizontalScroll = false
        didSendScrollRelease = false
        onScrollEnded()
    }

    private func sendScrollReleasedIfNeeded() {
        guard !didSendScrollRelease else {
            return
        }

        didSendScrollRelease = true
        onScrollReleased()
    }

    private func removeLocalMonitor() {
        localMonitorCleanup.remove()
    }
}
