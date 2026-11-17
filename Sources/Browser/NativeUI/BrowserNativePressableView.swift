// BrowserNativePressableView.swift

import AppKit
import QuartzCore

// MARK: - BrowserNativeDragValue

struct BrowserNativeDragValue {
    let startLocation: CGPoint
    let location: CGPoint
    let translation: CGSize
    let predictedEndTranslation: CGSize
    var grabAnchor: CGPoint?
}

// MARK: - BrowserNativePressableView

/// Pointer tracking is shared by sidebar rows, tiles and small native controls.
// swiftformat:disable:next preferFinalClasses
class BrowserNativePressableView: BrowserNativeSurface {
    // MARK: Internal

    override var isHidden: Bool {
        didSet {
            if isHidden {
                resetInteraction()
                BrowserNativeTooltipPresenter.shared.end(id: tooltipID, detached: true)
            }
        }
    }

    private(set) var isHovered = false
    private(set) var isPressed = false
    private(set) var isDragging = false
    var onClick: (NSEvent?) -> Void = { _ in }
    var onDoubleClick: ((NSEvent?) -> Void)?
    /// Acts on the press itself; returning true drops the single click its release would send.
    var onPress: ((NSEvent) -> Bool)?
    var onHoverChanged: (Bool) -> Void = { _ in }
    var onBeginDragSession: ((BrowserNativeDragValue) -> Bool)?
    var onDragChanged: ((BrowserNativeDragValue) -> Void)?
    var onDragEnded: ((BrowserNativeDragValue) -> Void)?
    var menuProvider: (() -> NSMenu)?
    weak var dragCoordinateView: NSView?
    var tooltipTitle: String?
    var tooltipCaption: String?
    var tooltipAnchorXFraction = BrowserChromeLayout.tooltipAnchorXFraction
    var tooltipShortcut: BrowserKeyboardShortcut?
    var tooltipPlacement = BrowserTooltipPlacement.belowLeading
    var permitsTooltip = true
    var pressedScale = BrowserChromeLayout.sidebarButtonPressedScale
    var pressCurve = BrowserNativeAnimation.Curve.press

    var isInteractionEnabled = true {
        didSet {
            if !isInteractionEnabled {
                resetInteraction()
            }
        }
    }

    // MARK: Private

    private let tooltipID = UUID()
    private var tracking: NSTrackingArea?
    private let pressAnimation = BrowserNativeAnimation()
    private var displayedScale: CGFloat = 1
    private var downEvent: NSEvent?
    private var pressActedOnDown = false
    private var dragGrabAnchor: CGPoint?
    private var hasExternalDragSession = false
    private var previousDragSample: (point: CGPoint, time: TimeInterval)?
    private var velocity = CGSize.zero

    var dragContentBounds: CGRect { bounds }

    /// Rows wait longer than buttons before showing a tooltip.
    var tooltipTarget: BrowserTooltipCoordinator.Target { .button }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        strokeWidth = 0
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var candidate: NSView? = hit
        while let view = candidate, view !== self {
            if view is NSButton || (view as? NSTextField)?.isEditable == true {
                return view
            }
            candidate = view.superview
        }
        return self
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool {
        guard isInteractionEnabled else { return false }
        onClick(nil)
        return true
    }

    override func menu(for _: NSEvent) -> NSMenu? {
        BrowserNativeTooltipPresenter.shared.end(id: tooltipID, detached: true)
        return menuProvider?()
    }

    /// VoiceOver's Show Menu (VO-Shift-M) opens the same menu as a right click,
    /// under the view's leading edge.
    override func accessibilityPerformShowMenu() -> Bool {
        guard isInteractionEnabled, let menu = menuProvider?(), !menu.items.isEmpty else { return false }
        BrowserNativeTooltipPresenter.shared.end(id: tooltipID, detached: true)
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.minX, y: isFlipped ? bounds.maxY : bounds.minY), in: self)
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        tracking = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true)
        pointerMoved(event)
    }

    override func mouseMoved(with event: NSEvent) { pointerMoved(event) }
    override func mouseExited(with event: NSEvent) { setHovered(false)
        pointerMoved(event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            resetInteraction()
            BrowserNativeTooltipPresenter.shared.end(id: tooltipID, detached: true)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isInteractionEnabled else { return }
        downEvent = event
        let localPoint = convert(event.locationInWindow, from: nil)
        let area = dragContentBounds
        dragGrabAnchor = CGPoint(
            x: min(max((localPoint.x - area.minX) / max(area.width, 1), 0), 1),
            y: min(max((localPoint.y - area.minY) / max(area.height, 1), 0), 1),
        )
        hasExternalDragSession = false
        previousDragSample = nil
        velocity = .zero
        isDragging = false
        setPressed(true)
        pressActedOnDown = onPress?(event) ?? false
    }

    override func mouseDragged(with event: NSEvent) {
        guard isInteractionEnabled, let downEvent, !hasExternalDragSession else { return }
        let distance = hypot(
            event.locationInWindow.x - downEvent.locationInWindow.x,
            event.locationInWindow.y - downEvent.locationInWindow.y,
        )
        if onDragChanged != nil || onBeginDragSession != nil,
           distance >= BrowserChromeLayout.sidebarTabDragMinimumDistance
        {
            isDragging = true
            setPressed(false)
            BrowserNativeTooltipPresenter.shared.end(id: tooltipID, detached: true)
            let value = dragValue(event)
            if let onBeginDragSession, onBeginDragSession(value) {
                hasExternalDragSession = true
                isDragging = true
                setPressed(false)
                refreshTooltip()
            } else {
                onDragChanged?(value)
            }
        } else if !isDragging {
            setPressed(bounds.contains(convert(event.locationInWindow, from: nil)))
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard downEvent != nil else { return }
        if hasExternalDragSession {
            resetInteraction()
            return
        }
        let didDrag = isDragging
        let value = dragValue(event)
        downEvent = nil
        dragGrabAnchor = nil
        isDragging = false
        setPressed(false)
        if didDrag {
            onDragEnded?(value)
        } else if isInteractionEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) {
            BrowserNativeTooltipPresenter.shared.end(id: tooltipID, detached: true)
            if event.clickCount >= 2, let onDoubleClick {
                onDoubleClick(event)
            } else if !pressActedOnDown {
                onClick(event)
            }
        }
    }

    /// Hover follows a still pointer as the view scrolls under it: tracking areas report
    /// nothing until the pointer moves.
    func syncHoverWithPointer() {
        guard NSEvent.pressedMouseButtons == 0, let window, window.isKeyWindow, !isHiddenOrHasHiddenAncestor else {
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHovered(bounds.contains(point) && visibleRect.contains(point))
    }

    /// Tracking reports nothing when the view moves away from a still pointer.
    func endHoverIfPointerLeft() {
        guard isHovered, NSEvent.pressedMouseButtons == 0, let window else { return }
        // Not `visibleRect`: a view that doesn't clip reports its scroll view's whole area.
        if !bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            setHovered(false)
        }
    }

    func pointerMoved(_: NSEvent) {}
    func interactionChanged() { needsDisplay = true }
    func resetInteraction() {
        hasExternalDragSession = false
        downEvent = nil
        dragGrabAnchor = nil
        isDragging = false
        setPressed(false)
        setHovered(false)
    }

    func synchronizeHoverWithPointer() {
        guard let window, !isHiddenOrHasHiddenAncestor else { setHovered(false)
            return
        }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        // `visibleRect` alone is not enough: a view that doesn't clip reports its ancestors' visible area.
        setHovered(bounds.contains(point) && visibleRect.contains(point))
    }

    func refreshTooltip() {
        if isHovered, permitsTooltip, isInteractionEnabled, !isDragging, let tooltipTitle, window != nil {
            BrowserNativeTooltipPresenter.shared.begin(
                id: tooltipID,
                anchor: self,
                title: tooltipTitle,
                caption: tooltipCaption,
                shortcut: tooltipShortcut,
                placement: tooltipPlacement,
                anchorXFraction: tooltipAnchorXFraction,
                target: tooltipTarget,
            )
        } else {
            BrowserNativeTooltipPresenter.shared.end(id: tooltipID)
        }
    }

    private func dragValue(_ event: NSEvent) -> BrowserNativeDragValue {
        let coordinateView = dragCoordinateView ?? superview ?? self
        let start = coordinateView.convert(downEvent?.locationInWindow ?? event.locationInWindow, from: nil)
        let location = coordinateView.convert(event.locationInWindow, from: nil)
        let translation = CGSize(width: location.x - start.x, height: location.y - start.y)
        if let previousDragSample {
            let elapsed = event.timestamp - previousDragSample.time
            if elapsed > 0, elapsed < 0.15 {
                velocity = CGSize(
                    width: (location.x - previousDragSample.point.x) / elapsed,
                    height: (location.y - previousDragSample.point.y) / elapsed,
                )
            } else if elapsed >= 0.15 {
                velocity = .zero
            }
        }
        previousDragSample = (location, event.timestamp)
        return BrowserNativeDragValue(
            startLocation: start,
            location: location,
            translation: translation,
            predictedEndTranslation: CGSize(
                width: translation.width + velocity.width * 0.15,
                height: translation.height + velocity
                    .height * 0.15,
            ),
            grabAnchor: dragGrabAnchor,
        )
    }

    private func setHovered(_ value: Bool) {
        let value = value && isInteractionEnabled
        guard isHovered != value else { return }
        isHovered = value
        onHoverChanged(value)
        interactionChanged()
        refreshTooltip()
    }

    private func setPressed(_ value: Bool) {
        guard isPressed != value else { return }
        isPressed = value
        let scale = value ? pressedScale : 1
        if case .spring(let response, let damping) = pressCurve {
            pressWithSpring(to: scale, response: response, damping: damping)
            interactionChanged()
            return
        }
        let from = displayedScale
        pressAnimation.start(pressCurve) { [weak self] progress in
            guard let self else { return }
            displayedScale = from + (scale - from) * progress
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.setAffineTransform(pressTransform(scale: displayedScale))
            CATransaction.commit()
        }
        interactionChanged()
    }

    private func pressTransform(scale: CGFloat) -> CGAffineTransform {
        CGAffineTransform(
            translationX: bounds.width * (1 - scale) / 2,
            y: bounds.height * (1 - scale) / 2,
        ).scaledBy(x: scale, y: scale)
    }

    /// The press springs in the render server, so work that the press starts on
    /// the main thread, such as showing a tab, never holds its first frames.
    private func pressWithSpring(to scale: CGFloat, response: Double, damping: Double) {
        pressAnimation.cancel()
        displayedScale = scale
        guard let layer else { return }
        let from = layer.presentation()?.transform ?? layer.transform
        let target = CATransform3DMakeAffineTransform(pressTransform(scale: scale))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = target
        CATransaction.commit()
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            layer.removeAnimation(forKey: "press")
            return
        }
        let animation = CASpringAnimation(keyPath: "transform")
        animation.mass = 1
        animation.stiffness = pow(2 * .pi / response, 2)
        animation.damping = 4 * .pi * damping / response
        animation.fromValue = NSValue(caTransform3D: from)
        animation.toValue = NSValue(caTransform3D: target)
        animation.duration = animation.settlingDuration
        layer.add(animation, forKey: "press")
    }
}
