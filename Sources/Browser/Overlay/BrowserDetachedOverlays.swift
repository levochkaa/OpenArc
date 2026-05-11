import AppKit
import QuartzCore
import SwiftUI

// MARK: - BrowserDetachedControlsOverlayContent

struct BrowserDetachedControlsOverlayContent: View {
    @ObservedObject var model: BrowserChromeModel
    @ObservedObject var commandBarModel: BrowserCommandBarModel

    let blockedLeadingInset: CGFloat

    var body: some View {
        ZStack {
            BrowserFindBarOverlay(
                model: model,
                blockedLeadingInset: blockedLeadingInset
            )
            .zIndex(8)

            BrowserCommandBarOverlay(
                model: commandBarModel,
                blockedLeadingInset: blockedLeadingInset,
                style: .standard,
                faviconCandidate: nil
            )
            .zIndex(10)
        }
    }
}

// MARK: - BrowserDetachedCurrentPageCommandBarOverlayContent

struct BrowserDetachedCurrentPageCommandBarOverlayContent: View {
    @ObservedObject var currentPageCommandBarModel: BrowserCommandBarModel

    let blockedLeadingInset: CGFloat
    let anchorFrame: CGRect?
    let sidebarWidth: CGFloat
    let faviconCandidate: BrowserCommandBarFaviconCandidate?

    var body: some View {
        BrowserCommandBarOverlay(
            model: currentPageCommandBarModel,
            blockedLeadingInset: blockedLeadingInset,
            style: .compact(anchorFrame: anchorFrame, sidebarWidth: sidebarWidth),
            faviconCandidate: faviconCandidate
        )
        .zIndex(10)
    }
}

// MARK: - BrowserDetachedSidebarHoverOverlayContent

struct BrowserDetachedSidebarHoverOverlayContent: View {
    @ObservedObject var model: BrowserChromeModel
    @EnvironmentObject var tooltipCoordinator: BrowserTooltipCoordinator
    @EnvironmentObject var faviconCache: BrowserFaviconCache

    let snapshot: BrowserSidebarSnapshot
    let showsWindowControlsInSidebar: Bool
    let isCommandBarPresented: Bool
    let isCurrentPageCommandBarPresented: Bool
    let isOverlayPresentation: Bool
    let showsOverlayBorder: Bool
    let roundsWindowLeadingCorners: Bool
    let chromeBackgroundMode: BrowserChromeBackgroundMode
    let sidebarWidth: CGFloat
    let sidebarHeight: CGFloat
    let containerWidth: CGFloat
    let containerHeight: CGFloat
    let isPresented: Bool
    let onToggleSidebar: () -> Void
    let onURLRowFrameChange: (CGRect?) -> Void

    var sidebarXOffset: CGFloat {
        if isPresented {
            return isOverlayPresentation ? BrowserChromeLayout.sidebarHoverOverlayEdgeInset : 0
        }

        return -sidebarWidth
    }

    var sidebarYOffset: CGFloat {
        isOverlayPresentation ? BrowserChromeLayout.sidebarHoverOverlayEdgeInset : 0
    }

    var sidebarContentSize: CGSize {
        CGSize(
            width: max(sidebarWidth - dockedWindowBorderInset, 0),
            height: max(sidebarHeight - dockedWindowBorderInset * 2, 0)
        )
    }

    var sidebarContentOffset: CGPoint {
        CGPoint(
            x: sidebarXOffset + dockedWindowBorderInset,
            y: sidebarYOffset + dockedWindowBorderInset
        )
    }

    var dockedWindowBorderInset: CGFloat {
        guard !isOverlayPresentation, !showsOverlayBorder, roundsWindowLeadingCorners else {
            return 0
        }

        return BrowserChromeLayout.detachedSidebarWindowBorderInset
    }

    var sidebarClipCornerRadius: CGFloat {
        if isOverlayPresentation || showsOverlayBorder {
            return BrowserChromeLayout.sidebarOverlayCornerRadius
        }

        return roundsWindowLeadingCorners ? BrowserWindowGeometry.windowCornerRadius : 0
    }

    var sidebarClipMaskedCorners: CACornerMask {
        if isOverlayPresentation || showsOverlayBorder {
            return [
                .layerMinXMinYCorner,
                .layerMinXMaxYCorner,
                .layerMaxXMinYCorner,
                .layerMaxXMaxYCorner,
            ]
        }

        guard roundsWindowLeadingCorners else {
            return []
        }

        return [.layerMinXMinYCorner, .layerMinXMaxYCorner]
    }

    var body: some View {
        BrowserSidebarChromePresentationHost(
            content: BrowserSidebarChromeView(
                model: model,
                snapshot: snapshot,
                showsWindowControlsInSidebar: showsWindowControlsInSidebar,
                isCommandBarPresented: isCommandBarPresented,
                isCurrentPageCommandBarPresented: isCurrentPageCommandBarPresented,
                isOverlayPresentation: isOverlayPresentation,
                showsOverlayBorder: showsOverlayBorder,
                roundsWindowLeadingCorners: roundsWindowLeadingCorners,
                chromeBackgroundMode: chromeBackgroundMode,
                onToggleSidebar: onToggleSidebar,
                onURLRowFrameChange: onURLRowFrameChange
            )
            .frame(width: sidebarWidth, height: sidebarHeight, alignment: .leading)
            .environmentObject(tooltipCoordinator)
            .environmentObject(faviconCache),
            contentSize: sidebarContentSize,
            contentOffset: sidebarContentOffset,
            cornerRadius: sidebarClipCornerRadius,
            maskedCorners: sidebarClipMaskedCorners,
            animationDuration: BrowserChromeLayout.sidebarAnimationDuration,
            animatesOffsetChanges: true
        )
        .frame(width: containerWidth, height: containerHeight, alignment: .topLeading)
    }
}

// MARK: - BrowserSidebarChromePresentationHost

struct BrowserSidebarChromePresentationHost<Content: View>: NSViewRepresentable {
    let content: Content
    let contentSize: CGSize
    let contentOffset: CGPoint
    let cornerRadius: CGFloat
    let maskedCorners: CACornerMask
    let animationDuration: TimeInterval
    let animatesOffsetChanges: Bool

    func makeNSView(context _: Context) -> BrowserSidebarChromePresentationNSView<Content> {
        BrowserSidebarChromePresentationNSView(
            rootView: content,
            contentSize: contentSize,
            contentOffset: contentOffset,
            cornerRadius: cornerRadius,
            maskedCorners: maskedCorners,
            animationDuration: animationDuration,
            animatesOffsetChanges: animatesOffsetChanges
        )
    }

    func updateNSView(_ nsView: BrowserSidebarChromePresentationNSView<Content>, context _: Context) {
        nsView.update(
            rootView: content,
            contentSize: contentSize,
            contentOffset: contentOffset,
            cornerRadius: cornerRadius,
            maskedCorners: maskedCorners,
            animationDuration: animationDuration,
            animatesOffsetChanges: animatesOffsetChanges
        )
    }
}

// MARK: - BrowserSidebarChromePresentationNSView

final class BrowserSidebarChromePresentationNSView<Content: View>: NSView {
    // MARK: Lifecycle

    init(
        rootView: Content,
        contentSize: CGSize,
        contentOffset: CGPoint,
        cornerRadius: CGFloat,
        maskedCorners: CACornerMask,
        animationDuration: TimeInterval,
        animatesOffsetChanges: Bool
    ) {
        self.hostingView = NSHostingView(rootView: rootView)
        self.contentSize = contentSize
        self.contentOffset = contentOffset
        self.cornerRadius = cornerRadius
        self.maskedCorners = maskedCorners
        self.animationDuration = animationDuration
        self.animatesOffsetChanges = animatesOffsetChanges
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true

        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = []
        hostingView.safeAreaRegions = []
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        addSubview(hostingView)

        updateClipping()
        applyHostingFrame(animated: false)
        self.didApplyInitialFrame = true
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Internal

    override var isFlipped: Bool {
        true
    }

    var hostingView: NSHostingView<Content>
    var contentSize: CGSize
    var contentOffset: CGPoint
    var cornerRadius: CGFloat
    var maskedCorners: CACornerMask
    var animationDuration: TimeInterval
    var animatesOffsetChanges: Bool
    var didApplyInitialFrame = false

    func update(
        rootView: Content,
        contentSize: CGSize,
        contentOffset: CGPoint,
        cornerRadius: CGFloat,
        maskedCorners: CACornerMask,
        animationDuration: TimeInterval,
        animatesOffsetChanges: Bool
    ) {
        let shouldAnimateOffset = didApplyInitialFrame
            && animatesOffsetChanges
            && self.contentOffset != contentOffset
            && self.contentSize == contentSize
            && animationDuration > 0

        hostingView.rootView = rootView
        self.contentSize = contentSize
        self.contentOffset = contentOffset
        self.cornerRadius = cornerRadius
        self.maskedCorners = maskedCorners
        self.animationDuration = animationDuration
        self.animatesOffsetChanges = animatesOffsetChanges

        updateClipping()
        applyHostingFrame(animated: shouldAnimateOffset)
        didApplyInitialFrame = true
    }

    // MARK: Private

    private func updateClipping() {
        guard let layer, let hostingLayer = hostingView.layer else {
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.masksToBounds = true
        hostingLayer.cornerRadius = max(cornerRadius, 0)
        hostingLayer.maskedCorners = maskedCorners
        hostingLayer.cornerCurve = .continuous
        hostingLayer.masksToBounds = true
        CATransaction.commit()
    }

    private func applyHostingFrame(animated: Bool) {
        let targetFrame = CGRect(origin: contentOffset, size: contentSize)
        guard !NSEqualRects(hostingView.frame, targetFrame) else {
            return
        }

        guard animated else {
            hostingView.frame = targetFrame
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            hostingView.animator().frame = targetFrame
        }
    }
}

// MARK: - BrowserDetachedOverlayWindowRepresentable

struct BrowserDetachedOverlayWindowRepresentable<Content: View>: NSViewRepresentable {
    let isVisible: Bool
    let isInteractive: Bool
    let contentFrameLeadingInset: CGFloat
    let content: Content

    func makeNSView(context _: Context) -> BrowserDetachedOverlayHostView<Content> {
        BrowserDetachedOverlayHostView(
            rootView: content,
            isVisible: isVisible,
            isInteractive: isInteractive,
            contentFrameLeadingInset: contentFrameLeadingInset
        )
    }

    func updateNSView(_ nsView: BrowserDetachedOverlayHostView<Content>, context _: Context) {
        nsView.update(
            rootView: content,
            isVisible: isVisible,
            isInteractive: isInteractive,
            contentFrameLeadingInset: contentFrameLeadingInset
        )
    }
}

// MARK: - BrowserDetachedOverlayPanel

final class BrowserDetachedOverlayPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    override func performDrag(with event: NSEvent) {
        guard let parent else {
            super.performDrag(with: event)
            return
        }

        let screenRect = convertToScreen(NSRect(origin: event.locationInWindow, size: .zero))
        let parentLocation = parent.convertFromScreen(screenRect).origin
        guard let parentEvent = NSEvent.mouseEvent(
            with: event.type,
            location: parentLocation,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: parent.windowNumber,
            context: nil,
            eventNumber: event.eventNumber,
            clickCount: event.clickCount,
            pressure: event.pressure
        ) else {
            parent.performDrag(with: event)
            return
        }

        parent.performDrag(with: parentEvent)
    }
}

// MARK: - BrowserDetachedOverlayHostView

final class BrowserDetachedOverlayHostView<Content: View>: NSView {
    // MARK: Lifecycle

    init(rootView: Content, isVisible: Bool, isInteractive: Bool, contentFrameLeadingInset: CGFloat) {
        self.hostingView = NSHostingView(rootView: rootView)
        self.isVisible = isVisible
        self.isInteractive = isInteractive
        self.contentFrameLeadingInset = contentFrameLeadingInset
        super.init(frame: .zero)
    }

    deinit {
        detachPanel()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Internal

    var overlayPanel: BrowserDetachedOverlayPanel?
    var hostingView: NSHostingView<Content>
    var isVisible: Bool
    var isInteractive: Bool
    var contentFrameLeadingInset: CGFloat

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncPanel()
    }

    override func layout() {
        super.layout()
        syncPanelFrame()
    }

    func update(rootView: Content, isVisible: Bool, isInteractive: Bool, contentFrameLeadingInset: CGFloat) {
        hostingView.rootView = rootView
        self.isVisible = isVisible
        self.isInteractive = isInteractive
        self.contentFrameLeadingInset = contentFrameLeadingInset
        syncPanel()
    }

    // MARK: Private

    private func syncPanel() {
        guard let window else {
            detachPanel()
            return
        }

        let panel = overlayPanel ?? makePanel()
        overlayPanel = panel
        panel.ignoresMouseEvents = !isInteractive
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.level = window.level

        guard isVisible else {
            panel.orderOut(nil)
            return
        }

        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        } else {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }

        syncPanelFrame()
        panel.orderFront(nil)
    }

    private func makePanel() -> BrowserDetachedOverlayPanel {
        let panel = BrowserDetachedOverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]

        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]
        hostingView.safeAreaRegions = []
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        return panel
    }

    private func syncPanelFrame() {
        guard let panel = overlayPanel, let window else {
            return
        }

        var windowFrame = convert(bounds, to: nil)
        if contentFrameLeadingInset > 0 {
            let inset = min(contentFrameLeadingInset, windowFrame.width)
            windowFrame.origin.x += inset
            windowFrame.size.width -= inset
        }

        let screenFrame = window.convertToScreen(windowFrame)
        guard !screenFrame.isEmpty else {
            panel.orderOut(nil)
            return
        }

        panel.setFrame(screenFrame, display: true)
    }

    private func detachPanel() {
        guard let overlayPanel else {
            return
        }

        overlayPanel.parent?.removeChildWindow(overlayPanel)
        overlayPanel.orderOut(nil)
    }
}
