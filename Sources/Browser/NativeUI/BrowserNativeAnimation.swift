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

        // MARK: Internal

        static let sidebar = Curve.easeInOut(0.18)
        /// Hover fills: 0.1 s, timing (0, 0, 0.58, 1).
        static let hover = Curve.easeOut(0.1)
        /// Element appearance: opacity over 0.15 s, timing (0, 0, 0.58, 1).
        static let appearance = Curve.easeOut(0.15)
        static let press = Curve.spring(response: 0.18, damping: 0.72)
        /// Press on sidebar rows: stiffness 987, damping 31.4.
        static let rowPress = Curve.spring(response: 0.2, damping: 0.5)
        /// Floating sidebar slide: stiffness 1218, damping 55.9.
        static let floatingSidebar = Curve.spring(response: 0.18, damping: 0.8)
        static let list = Curve.spring(response: 0.28, damping: 0.82)
        static let dragPreview = Curve.spring(response: 0.2, damping: 0.86)
        static let copy = Curve.spring(response: 0.22, damping: 0.68)

        var duration: Double {
            switch self {
            case .easeInOut(let duration),
                 .easeOut(let duration): duration
            case .spring(let response, let damping): -log(0.001) / (damping * 2 * .pi / response)
            }
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
            case .easeInOut,
                 .easeOut:
                let x = elapsed / duration
                let x1: Double =
                    if case .easeInOut = self {
                        0.42
                    } else {
                        0
                    }
                let x2 = 0.58
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
                return 3 * (1 - t) * t * t + t * t * t
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
        let start = CACurrentMediaTime()
        updates(0)
        let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let elapsed = CACurrentMediaTime() - start
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

    // MARK: Internal

    var onFrameChange: () -> Void = {}

    private var transitions = [ObjectIdentifier: Transition]()

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
    }

    func setFrame(
        _ frame: CGRect,
        of view: NSView,
        animated: Bool,
        curve: BrowserNativeAnimation.Curve = .list,
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
