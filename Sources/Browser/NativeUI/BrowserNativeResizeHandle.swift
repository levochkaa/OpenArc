// BrowserNativeResizeHandle.swift

import AppKit

final class BrowserNativeResizeHandle: NSView {
    // MARK: Internal

    override var isHidden: Bool {
        didSet {
            if isHidden {
                hoverTask?.cancel()
                hovering = false
                highlighted = false
                finishResize()
                popCursor()
            }
        }
    }

    var getWidth: () -> CGFloat = { 0 }
    var setWidth: (CGFloat) -> Void = { _ in }
    var defaultWidth: CGFloat = 0
    var direction: CGFloat = 1
    var verticalPadding = BrowserChromeLayout.sidebarOuterPadding
    var hapticsEnabled = true
    var onResizePhaseChange: (Bool) -> Void = { _ in }
    /// When set, releasing a drag that went below this width calls `onCollapse`.
    var collapseWidth: CGFloat?
    var onCollapse: () -> Void = {}
    private(set) var isResizing = false

    // MARK: Private

    private var tracking: NSTrackingArea?
    private var hoverTask: Task<Void, Never>?
    private var hovering = false
    private var highlighted = false
    private var pushedCursor = false
    private var snapped = false
    private var startX: CGFloat = 0
    private var startWidth: CGFloat = 0
    private var lastProposedWidth: CGFloat?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }
    isolated deinit { hoverTask?.cancel()
        popCursor()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
        )
        addTrackingArea(tracking)
        self.tracking = tracking
    }

    override func mouseEntered(with _: NSEvent) {
        hovering = true
        hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: BrowserChromeLayout.sidebarResizeHoverDelayNanoseconds)
            } catch {
                return
            }
            guard let self, hovering, !isResizing else { return }
            highlighted = true
            pushCursor()
            needsDisplay = true
        }
    }

    override func mouseExited(with _: NSEvent) {
        hovering = false
        highlighted = false
        hoverTask?.cancel()
        if !isResizing {
            popCursor()
        }
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            hoverTask?.cancel()
            hovering = false
            highlighted = false
            finishResize()
            popCursor()
        }
    }

    override func mouseDown(with event: NSEvent) {
        // A double click on the sidebar edge restores the default width.
        if event.clickCount == 2, defaultWidth > 0 {
            onResizePhaseChange(true)
            setWidth(defaultWidth)
            onResizePhaseChange(false)
            return
        }
        startX = screenPoint(event).x
        startWidth = getWidth()
        isResizing = true
        snapped = false
        hoverTask?.cancel()
        pushCursor()
        onResizePhaseChange(true)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) { updateDrag(translation: screenPoint(event).x - startX) }
    override func mouseUp(with _: NSEvent) { finishResize() }

    override func draw(_: NSRect) {
        guard highlighted || isResizing else { return }
        (highlighted ? BrowserChromeColors.resizeHandleHover : BrowserChromeColors.resizeHandle).setFill()
        NSRect(x: bounds.midX - 1, y: verticalPadding, width: 2, height: max(bounds.height - verticalPadding * 2, 0))
            .fill()
    }

    func updateDrag(translation: CGFloat) {
        guard isResizing else { return }
        let proposed = startWidth + translation * direction
        lastProposedWidth = proposed
        let shouldSnap = abs(proposed - defaultWidth) <= BrowserChromeLayout.sidebarSnapThreshold
        setWidth(shouldSnap ? defaultWidth : proposed)
        if shouldSnap, !snapped, hapticsEnabled {
            NSHapticFeedbackManager.defaultPerformer.perform(
                .alignment,
                performanceTime: .now,
            )
        }
        snapped = shouldSnap
    }

    private func screenPoint(_ event: NSEvent) -> NSPoint { window?
        .convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    }

    private func pushCursor() {
        if !pushedCursor {
            NSCursor.resizeLeftRight.push()
            pushedCursor = true
        }
    }

    private func popCursor() {
        if pushedCursor {
            NSCursor.pop()
            pushedCursor = false
        }
    }

    private func finishResize() {
        let wasResizing = isResizing
        var collapses = false
        if wasResizing, let collapseWidth, let lastProposedWidth {
            collapses = lastProposedWidth < collapseWidth
        }
        isResizing = false
        snapped = false
        lastProposedWidth = nil
        if !hovering || !highlighted {
            popCursor()
        }
        if wasResizing {
            onResizePhaseChange(false)
        }
        if collapses {
            onCollapse()
        }
        needsDisplay = true
    }
}
