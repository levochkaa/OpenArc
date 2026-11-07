// BrowserSpacePagerScrollNSView.swift

import AppKit

// MARK: - BrowserLocalMonitorCleanup

final class BrowserLocalMonitorCleanup: @unchecked Sendable {
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

// MARK: - BrowserSpacePagerScrollNSView

final class BrowserSpacePagerScrollNSView: NSView {
    // MARK: Internal

    var isEnabled = false
    var onScrollDelta: (CGFloat) -> Void = { _ in }
    var onScrollReleased: () -> Void = {}
    var onScrollEnded: () -> Void = {}

    var isTrackingHorizontalScroll = false
    var didSendScrollRelease = false
    var scrollEndWorkItem: DispatchWorkItem?

    private var axisLock = BrowserSwipeAxisLock()

    // MARK: Private

    private let localMonitorCleanup = BrowserLocalMonitorCleanup()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

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

        localMonitorCleanup.set(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleScrollWheel(event) ?? event
        })
    }

    private func handleScrollWheel(_ event: NSEvent) -> NSEvent? {
        guard
            isEnabled,
            !isHiddenOrHasHiddenAncestor,
            let window,
            event.window === window,
            bounds.contains(convert(event.locationInWindow, from: nil))
        else {
            finishHorizontalScrollIfNeeded()
            return event
        }

        // The tail of a gesture another view tracked starts nothing here.
        guard isTrackingHorizontalScroll || event.momentumPhase.isEmpty else {
            return event
        }

        let horizontalDelta = event.scrollingDeltaX
        let verticalDelta = event.scrollingDeltaY
        let isSideways = axisLock.isSideways(phase: event.phase, dx: horizontalDelta, dy: verticalDelta)
        guard isTrackingHorizontalScroll || isSideways else {
            return event
        }

        if !isTrackingHorizontalScroll {
            isTrackingHorizontalScroll = true
            didSendScrollRelease = false
        }

        // The event that starts a gesture only arms it.
        if horizontalDelta != 0, !didSendScrollRelease, !event.phase.contains(.began) {
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

// MARK: - BrowserSwipeAxisLock

/// Tells a sideways swipe from a scroll. A trackpad gesture gets its axis once, from
/// its first few points and leaning sideways, since a swipe rarely starts level; a
/// gesture that began scrolling a list stays a scroll, so a drift never takes it over.
/// A mouse wheel has no gesture, so each tick decides.
struct BrowserSwipeAxisLock {
    // MARK: Private

    private enum Axis { case sideways, vertical }

    private var axis: Axis?
    private var travel = CGSize.zero

    // MARK: Internal

    mutating func isSideways(phase: NSEvent.Phase, dx: CGFloat, dy: CGFloat) -> Bool {
        if phase.isEmpty {
            return abs(dx) > max(abs(dy) * 1.08, 0.5)
        }
        if phase.contains(.began) || phase.contains(.mayBegin) {
            axis = nil
            travel = .zero
        }
        if axis == nil {
            travel.width += abs(dx)
            travel.height += abs(dy)
            if travel.width + travel.height >= 3 {
                axis = travel.width >= travel.height * 0.8 ? .sideways : .vertical
            }
        }
        return axis == .sideways
    }
}
