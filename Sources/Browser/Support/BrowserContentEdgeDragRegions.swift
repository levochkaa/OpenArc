import AppKit
import QuartzCore
import SwiftUI

// MARK: - BrowserSidebarLocalMonitorCleanup

private final class BrowserSidebarLocalMonitorCleanup: @unchecked Sendable {
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

// MARK: - BrowserContentEdgeDragRegions

struct BrowserContentEdgeDragRegions: View {
    let windowSize: CGSize
    let blockedLeadingWidth: CGFloat
    let leadingInset: CGFloat
    let topInset: CGFloat
    let trailingInset: CGFloat
    let bottomInset: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            if topInset > 0 {
                BrowserWindowDragRegion()
                    .frame(width: max(windowSize.width - blockedLeadingWidth, 0), height: topInset)
                    .offset(x: blockedLeadingWidth)
            }

            if bottomInset > 0 {
                BrowserWindowDragRegion()
                    .frame(width: max(windowSize.width - blockedLeadingWidth, 0), height: bottomInset)
                    .offset(x: blockedLeadingWidth, y: max(windowSize.height - bottomInset, 0))
            }

            if trailingInset > 0 {
                BrowserWindowDragRegion()
                    .frame(width: trailingInset, height: windowSize.height)
                    .offset(x: max(windowSize.width - trailingInset, 0))
            }

            if leadingInset > 0 {
                BrowserWindowDragRegion()
                    .frame(width: leadingInset, height: windowSize.height)
                    .offset(x: blockedLeadingWidth)
            }
        }
        .frame(width: windowSize.width, height: windowSize.height, alignment: .topLeading)
    }
}

// MARK: - BrowserSidebarHoverRevealEdge

struct BrowserSidebarHoverRevealEdge: View {
    let onHoverChange: (Bool) -> Void

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onHover(perform: onHoverChange)
            .gesture(WindowDragGesture())
            .allowsWindowActivationEvents(true)
    }
}

// MARK: - BrowserSidebarHoverOverlayDismissReader

struct BrowserSidebarHoverOverlayDismissReader: NSViewRepresentable {
    let isPresented: Bool
    let sidebarFrame: CGRect
    let allowsPointerSyncDismissal: Bool
    let onPointerMovement: () -> Void
    let onDismiss: () -> Void

    func makeNSView(context _: Context) -> BrowserSidebarHoverOverlayDismissNSView {
        let view = BrowserSidebarHoverOverlayDismissNSView()
        view.update(
            isPresented: isPresented,
            sidebarFrame: sidebarFrame,
            allowsPointerSyncDismissal: allowsPointerSyncDismissal,
            onPointerMovement: onPointerMovement,
            onDismiss: onDismiss
        )
        return view
    }

    func updateNSView(_ nsView: BrowserSidebarHoverOverlayDismissNSView, context _: Context) {
        nsView.update(
            isPresented: isPresented,
            sidebarFrame: sidebarFrame,
            allowsPointerSyncDismissal: allowsPointerSyncDismissal,
            onPointerMovement: onPointerMovement,
            onDismiss: onDismiss
        )
    }
}

// MARK: - BrowserSidebarHoverOverlayDismissNSView

final class BrowserSidebarHoverOverlayDismissNSView: NSView {
    // MARK: Lifecycle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        postsFrameChangedNotifications = true
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Internal

    var isPresented = false
    var sidebarFrame = CGRect.zero
    var allowsPointerSyncDismissal = true
    var onPointerMovement: () -> Void = {}
    var onDismiss: () -> Void = {}
    var trackingArea: NSTrackingArea?

    var sidebarFrameInWindow: CGRect {
        convert(sidebarFrame, to: nil)
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
        syncLocalMonitor()
        schedulePointerSync()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        schedulePointerSync()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        removeHoverTrackingArea()

        guard isPresented else {
            return
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        onPointerMovement()
        dismissIfNeeded(for: event.locationInWindow)
    }

    override func mouseExited(with _: NSEvent) {
        guard isPresented else {
            return
        }

        onPointerMovement()
        dismissIfPointerIsPastSidebarTrailingEdge()
    }

    func update(
        isPresented: Bool,
        sidebarFrame: CGRect,
        allowsPointerSyncDismissal: Bool,
        onPointerMovement: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        let shouldRefreshTracking = self.isPresented != isPresented
        let shouldSyncPointer = shouldRefreshTracking
            || self.sidebarFrame != sidebarFrame
            || self.allowsPointerSyncDismissal != allowsPointerSyncDismissal

        self.isPresented = isPresented
        self.sidebarFrame = sidebarFrame
        self.allowsPointerSyncDismissal = allowsPointerSyncDismissal
        self.onPointerMovement = onPointerMovement
        self.onDismiss = onDismiss

        if shouldRefreshTracking {
            updateTrackingAreas()
            syncLocalMonitor()
        }

        if shouldSyncPointer {
            schedulePointerSync()
        }
    }

    // MARK: Private

    private let localMonitorCleanup = BrowserSidebarLocalMonitorCleanup()

    private func schedulePointerSync() {
        guard allowsPointerSyncDismissal else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.dismissIfPointerOutsideSidebar()
        }
    }

    private func dismissIfPointerOutsideSidebar() {
        guard isPresented, !bounds.isEmpty, let window else {
            return
        }

        dismissIfNeeded(for: window.mouseLocationOutsideOfEventStream)
    }

    private func dismissIfNeeded(for locationInWindow: NSPoint) {
        guard isPresented, !bounds.isEmpty, locationInWindow.x > sidebarFrameInWindow.maxX else {
            return
        }

        onDismiss()
    }

    private func syncLocalMonitor() {
        guard isPresented, window != nil else {
            removeLocalMonitor()
            return
        }

        installLocalMonitorIfNeeded()
    }

    private func installLocalMonitorIfNeeded() {
        guard localMonitorCleanup.monitor == nil else {
            return
        }

        localMonitorCleanup.set(NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else {
                return event
            }

            handleMonitoredEvent(event)
            return event
        })
    }

    private func handleMonitoredEvent(_ event: NSEvent) {
        guard isPresented,
              let sourceWindow = event.window,
              let targetWindow = window
        else {
            return
        }

        let locationInTargetWindow: NSPoint
        if sourceWindow === targetWindow {
            locationInTargetWindow = event.locationInWindow
        } else {
            let screenRect = sourceWindow.convertToScreen(
                NSRect(origin: event.locationInWindow, size: .zero)
            )
            locationInTargetWindow = targetWindow.convertFromScreen(screenRect).origin
        }

        onPointerMovement()
        dismissIfNeeded(for: locationInTargetWindow)
    }

    private func dismissIfPointerIsPastSidebarTrailingEdge() {
        guard isPresented, let window else {
            return
        }

        dismissIfNeeded(for: window.mouseLocationOutsideOfEventStream)
    }

    private func removeHoverTrackingArea() {
        guard let trackingArea else {
            return
        }

        removeTrackingArea(trackingArea)
        self.trackingArea = nil
    }

    private func removeLocalMonitor() {
        localMonitorCleanup.remove()
    }
}

// MARK: - BrowserWindowDragRegion

struct BrowserWindowDragRegion: View {
    var isEnabled = true

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .allowsWindowActivationEvents(true)
            .allowsHitTesting(isEnabled)
    }
}
