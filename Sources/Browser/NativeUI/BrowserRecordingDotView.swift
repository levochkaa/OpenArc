// BrowserRecordingDotView.swift

import AppKit
import QuartzCore

// MARK: - BrowserRecordingDotView

/// A red dot on a tab whose page uses the camera, the microphone or screen
/// capture: 8 pt, pulsing once a second unless Reduce Motion is on.
final class BrowserRecordingDotView: NSView {
    // MARK: Internal

    static let diameter: CGFloat = 8

    // MARK: Private

    private static let pulseKey = "recordingPulse"

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.diameter, height: Self.diameter) }

    override var isHidden: Bool { didSet { if isHidden != oldValue { updatePulse() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        self.isHidden = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.systemRed.cgColor
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePulse()
    }

    private func updatePulse() {
        guard let layer else { return }
        let pulses = !isHidden && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !pulses {
            layer.removeAnimation(forKey: Self.pulseKey)
        } else if layer.animation(forKey: Self.pulseKey) == nil {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.35
            pulse.duration = 1
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(pulse, forKey: Self.pulseKey)
        }
    }
}
