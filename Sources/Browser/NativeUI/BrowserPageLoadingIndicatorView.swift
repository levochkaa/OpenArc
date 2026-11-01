// BrowserPageLoadingIndicatorView.swift

import AppKit

/// The thin bar above the page while it loads. It breathes at first; a load that takes
/// longer opens into a track with a highlight passing over it, and the end closes it.
final class BrowserPageLoadingIndicatorView: NSView {
    // MARK: Private

    private enum Timing {
        static let pulse: TimeInterval = 1.63
        static let waitingPulses = 2.0
        static let sweep: TimeInterval = 1.13
        static let sweepTravel: TimeInterval = 0.73
        static let finish: TimeInterval = 0.33
    }

    private enum Phase {
        case idle
        case waiting
        case running
    }

    // MARK: Internal

    static let size = CGSize(width: 128, height: 4)

    override var isFlipped: Bool { true }

    private let pill = CALayer()
    private let highlight = CALayer()
    private var color = NSColor.white
    private var isLoading = false
    private var phase = Phase.idle
    private var phaseTimer: Timer?

    private var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        pill.cornerRadius = Self.size.height / 2
        pill.masksToBounds = true
        pill.opacity = 0
        pill.addSublayer(highlight)
        layer?.addSublayer(pill)
        isHidden = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        withoutActions {
            let backingScale = window?.backingScaleFactor ?? 2
            pill.contentsScale = backingScale
            highlight.contentsScale = backingScale
            pill.position = CGPoint(x: bounds.midX, y: bounds.midY)
            highlight.bounds = CGRect(origin: .zero, size: Self.size)
        }
    }

    /// The bar's color, which follows the Space's theme.
    func setColor(_ color: NSColor) {
        guard color != self.color else { return }
        self.color = color
        applyColors()
    }

    func setLoading(_ loading: Bool) {
        guard loading != isLoading else { return }
        isLoading = loading
        if loading {
            beginWaiting()
        } else {
            finish()
        }
    }

    private func withoutActions(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }

    private func applyColors() {
        withoutActions {
            pill.backgroundColor = color.withAlphaComponent(phase == .running ? 0.2 : 1).cgColor
            highlight.backgroundColor = color.withAlphaComponent(0.8).cgColor
        }
    }

    private func beginWaiting() {
        phaseTimer?.invalidate()
        pill.removeAllAnimations()
        highlight.removeAllAnimations()
        isHidden = false
        phase = .waiting
        applyColors()
        withoutActions {
            highlight.isHidden = true
            pill.bounds = CGRect(x: 0, y: 0, width: 48, height: Self.size.height)
            pill.opacity = reducesMotion ? 0.72 : 0
        }
        guard !reducesMotion else { return }

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 0.72, 0, 0]
        let width = CAKeyframeAnimation(keyPath: "bounds.size.width")
        width.values = [42, 48, 42, 42]
        for animation in [opacity, width] {
            animation.keyTimes = [0, 0.386, 0.772, 1]
            let ease = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.7, 1)
            animation.timingFunctions = [ease, ease, CAMediaTimingFunction(name: .linear)]
            animation.duration = Timing.pulse
            animation.repeatCount = .infinity
        }
        pill.add(opacity, forKey: "pulse.opacity")
        pill.add(width, forKey: "pulse.width")
        let timer = Timer(timeInterval: Timing.pulse * Timing.waitingPulses, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginRunning() }
        }
        RunLoop.main.add(timer, forMode: .common)
        phaseTimer = timer
    }

    private func beginRunning() {
        guard isLoading else { return }
        phase = .running
        pill.removeAllAnimations()
        applyColors()
        withoutActions {
            highlight.isHidden = false
            pill.bounds = CGRect(origin: .zero, size: Self.size)
            pill.opacity = 0.92
            highlight.position = CGPoint(x: -Self.size.width, y: Self.size.height / 2)
        }
        for (keyPath, from, to) in [
            ("bounds.size.width", 42 as CGFloat, Self.size.width),
            ("opacity", 0 as CGFloat, 0.92 as CGFloat),
        ] {
            let spring = CASpringAnimation(keyPath: keyPath)
            spring.mass = 1
            spring.stiffness = 61.7
            spring.damping = 14.5
            spring.fromValue = from
            spring.toValue = to
            spring.duration = spring.settlingDuration
            pill.add(spring, forKey: "open.\(keyPath)")
        }
        let travel = CAKeyframeAnimation(keyPath: "position.x")
        travel.values = [-Self.size.width / 2, Self.size.width * 1.5, Self.size.width * 1.5]
        travel.keyTimes = [0, NSNumber(value: Timing.sweepTravel / Timing.sweep), 1]
        travel.calculationMode = .linear
        travel.duration = Timing.sweep
        travel.repeatCount = .infinity
        highlight.add(travel, forKey: "sweep")
    }

    private func didFinishClosing() {
        guard phase == .idle else { return }
        highlight.removeAllAnimations()
        isHidden = true
    }

    private func finish() {
        phaseTimer?.invalidate()
        phaseTimer = nil
        guard phase != .idle else { return }
        phase = .idle
        let presented = pill.presentation()
        let width = presented?.bounds.width ?? pill.bounds.width
        let opacity = presented?.opacity ?? pill.opacity
        pill.removeAllAnimations()
        withoutActions {
            pill.bounds.size.width = 0
            pill.opacity = 0
        }
        guard !reducesMotion, opacity > 0.01 else {
            highlight.removeAllAnimations()
            isHidden = true
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.didFinishClosing() }
        }
        for (keyPath, from) in [("bounds.size.width", width), ("opacity", CGFloat(opacity))] {
            let close = CABasicAnimation(keyPath: keyPath)
            close.fromValue = from
            close.toValue = 0
            close.duration = Timing.finish
            close.timingFunction = CAMediaTimingFunction(controlPoints: 0.42, 0, 1, 1)
            pill.add(close, forKey: "close.\(keyPath)")
        }
        CATransaction.commit()
    }
}
