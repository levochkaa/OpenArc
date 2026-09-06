import AppKit
import QuartzCore

// MARK: - BrowserLocalMonitorCleanup

private final class BrowserLocalMonitorCleanup: @unchecked Sendable {
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

// MARK: - BrowserNotificationObserverCleanup

private final class BrowserNotificationObserverCleanup: @unchecked Sendable {
    // MARK: Lifecycle

    deinit {
        removeAll()
    }

    // MARK: Internal

    func append(_ observer: NSObjectProtocol) {
        observers.append(observer)
    }

    func removeAll() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    // MARK: Private

    private var observers = [NSObjectProtocol]()
}

// MARK: - BrowserSpaceSwipeNSView

final class BrowserSpaceSwipeNSView: NSView {
    // MARK: Lifecycle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Internal

    var canSwitchSpaces = false
    var onSwipeLeft: () -> Void = {}
    var onSwipeRight: () -> Void = {}

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

        localMonitorCleanup.set(NSEvent.addLocalMonitorForEvents(matching: .swipe) { [weak self] event in
            guard
                let self,
                canSwitchSpaces,
                let window,
                event.window === window
            else {
                return event
            }

            if event.deltaX < 0 {
                onSwipeLeft()
            } else if event.deltaX > 0 {
                onSwipeRight()
            } else {
                return event
            }

            return nil
        })
    }

    private func removeLocalMonitor() {
        localMonitorCleanup.remove()
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

// MARK: - BrowserPassthroughInteractionNSView

final class BrowserPassthroughInteractionNSView: NSView {
    // MARK: Lifecycle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        postsFrameChangedNotifications = true
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Internal

    var onInteraction: (NSEvent, NSView) -> Void = { _, _ in }

    var eventMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown] {
        didSet {
            guard eventMask != oldValue else {
                return
            }

            reinstallLocalMonitorIfNeeded()
        }
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

    // MARK: Private

    private let localMonitorCleanup = BrowserLocalMonitorCleanup()

    private func reinstallLocalMonitorIfNeeded() {
        guard window != nil else {
            return
        }

        removeLocalMonitor()
        installLocalMonitorIfNeeded()
    }

    private func installLocalMonitorIfNeeded() {
        guard localMonitorCleanup.monitor == nil else {
            return
        }

        localMonitorCleanup.set(NSEvent.addLocalMonitorForEvents(
            matching: eventMask
        ) { [weak self] event in
            guard let self else {
                return event
            }

            guard let window, event.window === window else {
                return event
            }

            let frameInWindow = convert(bounds, to: nil)
            if frameInWindow.contains(event.locationInWindow) {
                onInteraction(event, self)
            }

            return event
        })
    }

    private func removeLocalMonitor() {
        localMonitorCleanup.remove()
    }
}

// MARK: - BrowserWindowFrameReaderNSView

final class BrowserWindowFrameReaderNSView: NSView {
    // MARK: Lifecycle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        postsFrameChangedNotifications = true
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Internal

    var onFrameChange: (CGRect?) -> Void = { _ in }

    var lastFrameInWindow: CGRect?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleFrameUpdate()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        scheduleFrameUpdate()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scheduleFrameUpdate()
    }

    override func layout() {
        super.layout()
        scheduleFrameUpdate()
    }

    func scheduleFrameUpdate() {
        DispatchQueue.main.async { [weak self] in
            self?.sendFrameUpdateIfNeeded()
        }
    }

    // MARK: Private

    private func sendFrameUpdateIfNeeded() {
        let frameInWindow = window.map { _ in convert(bounds, to: nil) }
        guard frameInWindow != lastFrameInWindow else {
            return
        }

        lastFrameInWindow = frameInWindow
        onFrameChange(frameInWindow)
    }
}

// MARK: - BrowserScreenFrameReaderNSView

final class BrowserScreenFrameReaderNSView: NSView {
    // MARK: Lifecycle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        postsFrameChangedNotifications = true
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Internal

    var onFrameChange: (CGRect?) -> Void = { _ in }

    var lastFrameInScreen: CGRect?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateWindowObservers()
        scheduleFrameUpdate()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        scheduleFrameUpdate()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scheduleFrameUpdate()
    }

    override func layout() {
        super.layout()
        scheduleFrameUpdate()
    }

    func scheduleFrameUpdate() {
        DispatchQueue.main.async { [weak self] in
            self?.sendFrameUpdateIfNeeded()
        }
    }

    // MARK: Private

    private let windowObserverCleanup = BrowserNotificationObserverCleanup()

    private func updateWindowObservers() {
        removeWindowObservers()

        guard let window else {
            return
        }

        let notificationCenter = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            let observer = notificationCenter.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleFrameUpdate()
                }
            }
            windowObserverCleanup.append(observer)
        }
    }

    private func removeWindowObservers() {
        windowObserverCleanup.removeAll()
    }

    private func sendFrameUpdateIfNeeded() {
        let frameInScreen = window.map { window in
            window.convertToScreen(convert(bounds, to: nil))
        }
        guard frameInScreen != lastFrameInScreen else {
            return
        }

        lastFrameInScreen = frameInScreen
        onFrameChange(frameInScreen)
    }
}

// MARK: - BrowserWindowFullscreenState

struct BrowserWindowFullscreenState: Equatable {
    let isFullscreen: Bool
    let isTransitioning: Bool
}

// MARK: - BrowserWindowFullscreenReaderNSView

final class BrowserWindowFullscreenReaderNSView: NSView {
    // MARK: Lifecycle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Internal

    var onFullscreenStateChange: (BrowserWindowFullscreenState) -> Void = { _ in }

    var lastFullscreenState: BrowserWindowFullscreenState?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateObservedWindow()
        sendFullscreenStateIfNeeded()
    }

    func sendFullscreenStateIfNeeded() {
        sendFullscreenStateIfNeeded(
            BrowserWindowFullscreenState(
                isFullscreen: window?.styleMask.contains(.fullScreen) ?? false,
                isTransitioning: false
            )
        )
    }

    // MARK: Private

    private let notificationObserverCleanup = BrowserNotificationObserverCleanup()

    private weak var observedWindow: NSWindow?

    private func updateObservedWindow() {
        guard observedWindow !== window else {
            return
        }

        removeNotificationObservers()
        observedWindow = window

        guard let window else {
            return
        }

        addNotificationObserver(for: NSWindow.willEnterFullScreenNotification, window: window) { [weak self] in
            self?.sendFullscreenStateIfNeeded(
                BrowserWindowFullscreenState(isFullscreen: true, isTransitioning: true)
            )
        }
        addNotificationObserver(for: NSWindow.didEnterFullScreenNotification, window: window) { [weak self] in
            self?.sendFullscreenStateIfNeeded(
                BrowserWindowFullscreenState(isFullscreen: true, isTransitioning: false)
            )
        }
        addNotificationObserver(for: NSWindow.willExitFullScreenNotification, window: window) { [weak self] in
            self?.sendFullscreenStateIfNeeded(
                BrowserWindowFullscreenState(isFullscreen: false, isTransitioning: true)
            )
        }
        addNotificationObserver(for: NSWindow.didExitFullScreenNotification, window: window) { [weak self] in
            self?.sendFullscreenStateIfNeeded(
                BrowserWindowFullscreenState(isFullscreen: false, isTransitioning: false)
            )
        }
    }

    private func addNotificationObserver(
        for name: NSNotification.Name,
        window: NSWindow,
        handler: @escaping @MainActor @Sendable () -> Void
    ) {
        let observer = NotificationCenter.default.addObserver(
            forName: name,
            object: window,
            queue: .main
        ) { _ in
            Task { @MainActor in
                handler()
            }
        }
        notificationObserverCleanup.append(observer)
    }

    private func removeNotificationObservers() {
        notificationObserverCleanup.removeAll()
    }

    private func sendFullscreenStateIfNeeded(_ fullscreenState: BrowserWindowFullscreenState) {
        guard lastFullscreenState != fullscreenState else {
            return
        }

        lastFullscreenState = fullscreenState
        onFullscreenStateChange(fullscreenState)
    }
}

extension NSView {
    func containsWindowPoint<T: NSView>(_ windowPoint: NSPoint, inDescendantOfType descendantType: T.Type) -> Bool {
        if self is T, bounds.contains(convert(windowPoint, from: nil)) {
            return true
        }

        return subviews.contains {
            $0.containsWindowPoint(windowPoint, inDescendantOfType: descendantType)
        }
    }
}
