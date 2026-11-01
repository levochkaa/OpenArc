// BrowserNativeAnimation.swift

import AppKit
import QuartzCore

// MARK: - BrowserNativeAnimation

/// The timing contracts of the original chrome, expressed independently of SwiftUI.
/// Frames are advanced together on the main run loop: nested AppKit/CEF views see the
/// current geometry, rather than a final model frame with an animated backing layer.
@MainActor final class BrowserNativeAnimation {
    // MARK: Internal

    enum Curve {
        case easeInOut(Double)
        case easeOut(Double)
        case spring(response: Double, damping: Double)
        /// A cubic timing curve through (x1, y1) and (x2, y2).
        case bezier(Double, x1: Double, y1: Double, x2: Double, y2: Double)

        // MARK: Internal

        /// Page, sidebar and bar geometry: 0.08 s, timing (0.25, 0.46, 0.45, 0.94).
        static let sidebar = Curve.bezier(0.08, x1: 0.25, y1: 0.46, x2: 0.45, y2: 0.94)
        /// The theme cross-fading to a chosen Space.
        static let spaceSlide = Curve.bezier(0.19, x1: 0.215, y1: 0.61, x2: 0.355, y2: 1)
        /// The Library sliding in from the window edge.
        static let libraryOpen = Curve.spring(response: 0.2, damping: 0.995)
        /// The Library leaving.
        static let library = Curve.spring(response: 0.19, damping: 0.995)
        /// Spaces sliding to a chosen Space or settling after a swipe: critically damped.
        static let spaceSelect = Curve.spring(response: 0.2, damping: 0.995)
        /// A pinned row's title making room for its caption, and the caption fading.
        static let caption = Curve.easeInOut(0.1)
        /// Rows placed by a drag: 0.12 s, timing (0, 0, 0.58, 1).
        static let rowMove = Curve.bezier(0.12, x1: 0, y1: 0, x2: 0.58, y2: 1)
        /// Rows making room when a tab opens or closes: 0.12 s, timing (0.25, 0.1, 0.25, 1).
        static let rowList = Curve.bezier(0.12, x1: 0.25, y1: 0.1, x2: 0.25, y2: 1)
        /// Rows closing up under a folder that collapses.
        static let folderCollapse = Curve.bezier(0.2, x1: 0, y1: 0, x2: 0.58, y2: 1)
        /// Rows making room for a folder that expands, and the find bar's fade.
        static let standard = Curve.bezier(0.25, x1: 0.25, y1: 0.1, x2: 0.25, y2: 1)
        /// Rows appearing and leaving: 0.12 s, timing (0.25, 0.1, 0.25, 1).
        static let rowFade = Curve.bezier(0.12, x1: 0.25, y1: 0.1, x2: 0.25, y2: 1)
        /// The chevron turning open or closed, with its overshoot.
        static let disclosure = Curve.spring(response: 0.3, damping: 0.6)
        /// A dock button pressed and released: 0.13 s, timing (0.215, 0.61, 0.355, 1).
        static let dockPress = Curve.bezier(0.13, x1: 0.215, y1: 0.61, x2: 0.355, y2: 1)
        /// A tooltip replaced or dismissed by a press.
        static let tooltipOut = Curve.easeOut(0.1)
        /// A tooltip left behind by the pointer.
        static let tooltipFade = Curve.easeOut(0.3)
        /// Hover fills: 0.1 s, timing (0, 0, 0.58, 1).
        static let hover = Curve.easeOut(0.1)
        /// Element appearance: opacity over 0.15 s, timing (0, 0, 0.58, 1).
        static let appearance = Curve.easeOut(0.15)
        static let press = Curve.spring(response: 0.23, damping: 0.72)
        /// Press on sidebar rows: stiffness 987, damping 31.4.
        static let rowPress = Curve.spring(response: 0.2, damping: 0.5)
        /// Floating sidebar slide: stiffness 1218, damping 55.9.
        static let floatingSidebar = Curve.spring(response: 0.17, damping: 0.8)
        /// The sidebar leaving for the Library.
        static let sidebarToLibrary = Curve.bezier(0.045, x1: 0, y1: 0, x2: 1, y2: 1)
        /// The sidebar coming back from the Library.
        static let sidebarFromLibrary = Curve.bezier(0.36, x1: 0.15, y1: 0.8, x2: 0.2, y2: 1)
        /// The update pill rising into place and fading in.
        static let toastAppear = Curve.spring(response: 0.6, damping: 0.4)
        /// The update pill opening into a card under the pointer.
        static let toastExpand = Curve.spring(response: 0.33, damping: 0.7)
        /// The update card closing back into a pill.
        static let toastCollapse = Curve.spring(response: 0.21, damping: 0.9)
        /// A dropped row landing in place, with the rows making room for it.
        static let landing = rowList
        /// Reload and Stop dissolving into each other.
        static let reloadDissolve = Curve.easeInOut(0.1)
        /// The copy button's link turning into a check: the first leaves, then the next arrives.
        static let copy = Curve.bezier(0.4, x1: 0, y1: 0, x2: 1, y2: 1)
        /// The check turning back into a link.
        static let copyReset = Curve.bezier(0.3, x1: 0, y1: 0, x2: 1, y2: 1)
        /// A mini player growing on hover and shrinking back.
        static let miniPlayerGrow = Curve.easeInOut(0.2)
        static let miniPlayerShrink = Curve.easeOut(0.17)

        var duration: Double {
            switch self {
            case .bezier(let duration, _, _, _, _),
                 .easeInOut(let duration),
                 .easeOut(let duration): duration
            case .spring(let response, let damping):
                // Near critical damping the tail decays slower than the envelope alone.
                -log(0.001) / (damping * 2 * .pi / response) * (damping >= 0.9 ? 1.5 : 1)
            }
        }

        private static func bezierValue(_ x: Double, x1: Double, y1: Double, x2: Double, y2: Double) -> Double {
            var low = 0.0
            var high = 1.0
            for _ in 0..<18 {
                let t = (low + high) / 2
                let position = 3 * (1 - t) * (1 - t) * t * x1 + 3 * (1 - t) * t * t * x2 + t * t * t
                if position < x {
                    low = t
                } else {
                    high = t
                }
            }
            let t = (low + high) / 2
            return 3 * (1 - t) * (1 - t) * t * y1 + 3 * (1 - t) * t * t * y2 + t * t * t
        }

        /// The same motion for Core Animation, from `fromValue` to `toValue`.
        func layerAnimation(keyPath: String) -> CABasicAnimation {
            let animation: CABasicAnimation
            switch self {
            case .spring(let response, let damping):
                let omega = 2 * Double.pi / response
                let spring = CASpringAnimation(keyPath: keyPath)
                spring.mass = 1
                spring.stiffness = omega * omega
                spring.damping = 2 * damping * omega
                animation = spring
            case .easeInOut:
                animation = CABasicAnimation(keyPath: keyPath)
                animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.42, 0, 0.58, 1)
            case .easeOut:
                animation = CABasicAnimation(keyPath: keyPath)
                animation.timingFunction = CAMediaTimingFunction(controlPoints: 0, 0, 0.58, 1)
            case .bezier(_, let x1, let y1, let x2, let y2):
                animation = CABasicAnimation(keyPath: keyPath)
                animation.timingFunction = CAMediaTimingFunction(
                    controlPoints: Float(x1),
                    Float(y1),
                    Float(x2),
                    Float(y2),
                )
            }
            animation.duration = duration
            return animation
        }

        func value(at elapsed: Double) -> Double {
            if elapsed >= duration {
                return 1
            }
            if elapsed <= 0 {
                return 0
            }
            switch self {
            case .spring(let response, let damping):
                let omega = 2 * Double.pi / response
                let frequency = omega * sqrt(1 - damping * damping)
                return 1 - exp(-damping * omega * elapsed)
                    * (cos(frequency * elapsed) + damping * omega / frequency * sin(frequency * elapsed))
            case .easeInOut:
                return Self.bezierValue(elapsed / duration, x1: 0.42, y1: 0, x2: 0.58, y2: 1)
            case .easeOut:
                return Self.bezierValue(elapsed / duration, x1: 0, y1: 0, x2: 0.58, y2: 1)
            case .bezier(_, let x1, let y1, let x2, let y2):
                return Self.bezierValue(elapsed / duration, x1: x1, y1: y1, x2: x2, y2: y2)
            }
        }
    }

    private(set) var isRunning = false

    // MARK: Private

    private var timer: Timer?

    isolated deinit { timer?.invalidate() }

    static func interpolate(_ from: CGRect, _ to: CGRect, _ progress: Double) -> CGRect {
        CGRect(
            x: from.minX + (to.minX - from.minX) * progress,
            y: from.minY + (to.minY - from.minY) * progress,
            width: from.width + (to.width - from.width) * progress,
            height: from.height + (to.height - from.height) * progress,
        )
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    func start(
        _ curve: Curve,
        updates: @escaping @MainActor (Double) -> Void,
        completion: @escaping @MainActor () -> Void = {},
    ) {
        cancel()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            updates(1)
            completion()
            return
        }
        isRunning = true
        updates(0)
        // The clock starts at the first tick: work done in the same turn of the
        // run loop must not eat the opening frames.
        var start: CFTimeInterval?
        let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CACurrentMediaTime()
                let elapsed = now - (start ?? now)
                start = start ?? now
                updates(curve.value(at: elapsed))
                if elapsed >= curve.duration {
                    self.cancel()
                    completion()
                }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

// MARK: - BrowserNativeVisibilityAnimation

@MainActor final class BrowserNativeVisibilityAnimation {
    // MARK: Private

    private let animation = BrowserNativeAnimation()
    private var target: Bool?
    private weak var targetView: NSView?

    // MARK: Internal

    func setVisible(_ visible: Bool, view: NSView, curve: BrowserNativeAnimation.Curve) {
        if targetView !== view {
            animation.cancel()
            target = nil
            targetView = view
        }
        guard target != visible else { return }
        animation.cancel()
        let initial = target == nil
        target = visible
        let from = view.isHidden ? 0 : view.alphaValue
        if visible {
            view.isHidden = false
        }
        guard !initial, view.window != nil else {
            view.isHidden = !visible
            view.alphaValue = visible ? 1 : 0
            return
        }
        animation.start(curve) { [weak view] progress in
            view?.alphaValue = from + ((visible ? 1 : 0) - from) * progress
        } completion: { [weak view] in view?.isHidden = !visible }
    }
}

// MARK: - BrowserNativeFrameTransitions

@MainActor final class BrowserNativeFrameTransitions {
    // MARK: Private

    private struct Transition {
        weak var view: NSView?
        var target: CGRect
        let animation: BrowserNativeAnimation
    }

    private static let slideKey = "browser.slide."

    // MARK: Internal

    var onFrameChange: () -> Void = {}

    private var transitions = [ObjectIdentifier: Transition]()
    private let slidingViews = NSHashTable<NSView>.weakObjects()
    private var slideCount = 0
    private var leaving = [ObjectIdentifier: (view: NSView?, target: CGRect)]()

    func targetFrame(of view: NSView) -> CGRect { transitions[ObjectIdentifier(view)]?.target ?? view.frame }

    func freezeFrame(of view: NSView) {
        let id = ObjectIdentifier(view)
        guard var transition = transitions[id] else { return }
        transition.animation.cancel()
        transition.target = view.frame
        transitions[id] = transition
    }

    func finishAll() {
        for transition in transitions.values {
            transition.animation.cancel()
            transition.view?.frame = transition.target
            transition.view?.layoutSubtreeIfNeeded()
        }
        for view in slidingViews.allObjects {
            for key in view.layer?.animationKeys() ?? [] where key.hasPrefix(Self.slideKey) {
                view.layer?.removeAnimation(forKey: key)
            }
        }
        slidingViews.removeAllObjects()
    }

    /// Moves a view out of its superview without the main thread. AppKit stops showing a
    /// view above its siblings once its frame is outside, so the frame stays until
    /// `endSlideOut`.
    func slideOut(
        _ view: NSView,
        to frame: CGRect,
        curve: BrowserNativeAnimation.Curve,
        delay: CFTimeInterval = 0,
    ) {
        view.wantsLayer = true
        let animation = curve.layerAnimation(keyPath: "position")
        animation.isAdditive = true
        animation.fromValue = NSValue(point: .zero)
        animation.toValue = NSValue(point: CGPoint(x: frame.minX - view.frame.minX, y: frame.minY - view.frame.minY))
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        if delay > 0 {
            animation.beginTime = CACurrentMediaTime() + delay
        }
        slideCount &+= 1
        view.layer?.add(animation, forKey: "\(Self.slideKey)\(slideCount)")
        slidingViews.add(view)
        leaving[ObjectIdentifier(view)] = (view, frame)
    }

    /// Ends every `slideOut`. A view still on its way stays where it is on screen, so
    /// that a new move can continue from there.
    func endSlideOuts(atTarget: Bool) {
        for (view, target) in leaving.values {
            guard let view else { continue }
            var origin = target.origin
            if !atTarget, let layer = view.layer, let shown = layer.presentation() {
                origin = CGPoint(
                    x: view.frame.minX + shown.position.x - layer.position.x,
                    y: view.frame.minY + shown.position.y - layer.position.y,
                )
            }
            for key in view.layer?.animationKeys() ?? [] where key.hasPrefix(Self.slideKey) {
                view.layer?.removeAnimation(forKey: key)
            }
            view.frame = CGRect(origin: origin, size: target.size)
        }
        leaving.removeAll()
    }

    /// Moves a view without the main thread: its frame is final at once, and an additive
    /// animation on its layer carries the rest of the way. A busy main thread cannot stall
    /// it, and a move made during another adds to it, so a row never jumps.
    func slide(
        _ view: NSView,
        to frame: CGRect,
        animated: Bool,
        curve: BrowserNativeAnimation.Curve,
        initialVelocity: CGFloat = 0,
        delay: CFTimeInterval = 0,
    ) {
        let from = view.frame
        guard animated, view.window != nil, from != .zero, from.origin != frame.origin,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            view.frame = frame
            return
        }
        view.wantsLayer = true
        view.frame = frame
        let animation = curve.layerAnimation(keyPath: "position")
        (animation as? CASpringAnimation)?.initialVelocity = initialVelocity
        if delay > 0 {
            animation.beginTime = CACurrentMediaTime() + delay
            animation.fillMode = .backwards
        }
        animation.isAdditive = true
        animation.fromValue = NSValue(point: CGPoint(x: from.minX - frame.minX, y: from.minY - frame.minY))
        animation.toValue = NSValue(point: .zero)
        slideCount &+= 1
        view.layer?.add(animation, forKey: "\(Self.slideKey)\(slideCount)")
        slidingViews.add(view)
    }

    func setFrame(
        _ frame: CGRect,
        of view: NSView,
        animated: Bool,
        curve: BrowserNativeAnimation.Curve = .rowMove,
    ) {
        transitions = transitions.filter { $0.value.view != nil }
        let id = ObjectIdentifier(view)
        if let previous = transitions[id], previous.target == frame, previous.animation.isRunning {
            return
        }
        let animation = transitions[id]?.animation ?? BrowserNativeAnimation()
        animation.cancel()
        transitions[id] = Transition(view: view, target: frame, animation: animation)
        guard animated, view.window != nil, view.frame != .zero, view.frame != frame else {
            view.frame = frame
            return
        }
        let from = view.frame
        let onFrameChange = onFrameChange
        animation.start(curve) { [weak view] progress in
            view?.frame = BrowserNativeAnimation.interpolate(from, frame, progress)
            view?.layoutSubtreeIfNeeded()
            onFrameChange()
        }
    }
}
