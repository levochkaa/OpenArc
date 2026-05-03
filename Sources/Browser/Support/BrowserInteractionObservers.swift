import AppKit
import QuartzCore
import SwiftUI

struct BrowserSpaceSwipeObserver: NSViewRepresentable {
    let canSwitchSpaces: Bool
    let onSwipeLeft: () -> Void
    let onSwipeRight: () -> Void

    func makeNSView(context _: Context) -> BrowserSpaceSwipeNSView {
        let view = BrowserSpaceSwipeNSView()
        view.canSwitchSpaces = canSwitchSpaces
        view.onSwipeLeft = onSwipeLeft
        view.onSwipeRight = onSwipeRight
        return view
    }

    func updateNSView(_ nsView: BrowserSpaceSwipeNSView, context _: Context) {
        nsView.canSwitchSpaces = canSwitchSpaces
        nsView.onSwipeLeft = onSwipeLeft
        nsView.onSwipeRight = onSwipeRight
    }
}
final class BrowserSpaceSwipeNSView: NSView {
    var canSwitchSpaces = false
    var onSwipeLeft: () -> Void = {}
    var onSwipeRight: () -> Void = {}

    var localMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        removeLocalMonitor()
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
        guard localMonitor == nil else {
            return
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .swipe) { [weak self] event in
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
        }
    }

    private func removeLocalMonitor() {
        guard let localMonitor else {
            return
        }

        NSEvent.removeMonitor(localMonitor)
        self.localMonitor = nil
    }
}
struct BrowserPassthroughInteractionObserver: NSViewRepresentable {
    let eventMask: NSEvent.EventTypeMask
    let onInteraction: (NSEvent, NSView) -> Void

    init(
        eventMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown],
        onInteraction: @escaping () -> Void
    ) {
        self.eventMask = eventMask
        self.onInteraction = { _, _ in
            onInteraction()
        }
    }

    init(
        eventMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown],
        onInteraction: @escaping (NSEvent, NSView) -> Void
    ) {
        self.eventMask = eventMask
        self.onInteraction = onInteraction
    }

    func makeNSView(context _: Context) -> BrowserPassthroughInteractionNSView {
        let view = BrowserPassthroughInteractionNSView()
        view.eventMask = eventMask
        view.onInteraction = onInteraction
        return view
    }

    func updateNSView(_ nsView: BrowserPassthroughInteractionNSView, context _: Context) {
        nsView.eventMask = eventMask
        nsView.onInteraction = onInteraction
    }
}
final class BrowserPassthroughInteractionNSView: NSView {
    var eventMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown] {
        didSet {
            guard eventMask != oldValue else {
                return
            }

            reinstallLocalMonitorIfNeeded()
        }
    }

    var onInteraction: (NSEvent, NSView) -> Void = { _, _ in }

    var localMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        postsFrameChangedNotifications = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        removeLocalMonitor()
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

    private func reinstallLocalMonitorIfNeeded() {
        guard window != nil else {
            return
        }

        removeLocalMonitor()
        installLocalMonitorIfNeeded()
    }

    private func installLocalMonitorIfNeeded() {
        guard localMonitor == nil else {
            return
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(
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
        }
    }

    private func removeLocalMonitor() {
        guard let localMonitor else {
            return
        }

        NSEvent.removeMonitor(localMonitor)
        self.localMonitor = nil
    }
}
struct BrowserWindowFrameReader: NSViewRepresentable {
    let onFrameChange: (CGRect?) -> Void

    func makeNSView(context _: Context) -> BrowserWindowFrameReaderNSView {
        let view = BrowserWindowFrameReaderNSView()
        view.onFrameChange = onFrameChange
        return view
    }

    func updateNSView(_ nsView: BrowserWindowFrameReaderNSView, context _: Context) {
        nsView.onFrameChange = onFrameChange
        nsView.scheduleFrameUpdate()
    }
}
final class BrowserWindowFrameReaderNSView: NSView {
    var onFrameChange: (CGRect?) -> Void = { _ in }

    var lastFrameInWindow: CGRect?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        postsFrameChangedNotifications = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

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

    private func sendFrameUpdateIfNeeded() {
        let frameInWindow = window.map { _ in convert(bounds, to: nil) }
        guard frameInWindow != lastFrameInWindow else {
            return
        }

        lastFrameInWindow = frameInWindow
        onFrameChange(frameInWindow)
    }
}
struct BrowserWindowFullscreenState: Equatable {
    let isFullscreen: Bool
    let isTransitioning: Bool
}
struct BrowserWindowFullscreenReader: NSViewRepresentable {
    let onFullscreenStateChange: (BrowserWindowFullscreenState) -> Void

    func makeNSView(context _: Context) -> BrowserWindowFullscreenReaderNSView {
        let view = BrowserWindowFullscreenReaderNSView()
        view.onFullscreenStateChange = onFullscreenStateChange
        return view
    }

    func updateNSView(_ nsView: BrowserWindowFullscreenReaderNSView, context _: Context) {
        nsView.onFullscreenStateChange = onFullscreenStateChange
        nsView.sendFullscreenStateIfNeeded()
    }
}
final class BrowserWindowFullscreenReaderNSView: NSView {
    var onFullscreenStateChange: (BrowserWindowFullscreenState) -> Void = { _ in }

    private weak var observedWindow: NSWindow?
    var notificationObservers: [NSObjectProtocol] = []
    var lastFullscreenState: BrowserWindowFullscreenState?

    deinit {
        removeNotificationObservers()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

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
        handler: @escaping () -> Void
    ) {
        let observer = NotificationCenter.default.addObserver(
            forName: name,
            object: window,
            queue: .main
        ) { _ in
            handler()
        }
        notificationObservers.append(observer)
    }

    private func removeNotificationObservers() {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers = []
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
