// BrowserViewportClipView.swift

import AppKit
import QuartzCore

// MARK: - BrowserViewportClipView

final class BrowserViewportClipView: NSView {
    // MARK: Internal

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    var hostedView: NSView

    init(hostView: NSView) {
        self.hostedView = hostView
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        attachHostedViewIfNeeded()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        if hostedView.frame != bounds {
            hostedView.frame = bounds
        }
    }

    func update(hostView: NSView) {
        guard hostedView !== hostView else {
            attachHostedViewIfNeeded()
            return
        }

        hostedView.removeFromSuperview()
        hostedView = hostView
        attachHostedViewIfNeeded()
        needsLayout = true
    }

    func updateClipping(cornerRadius: CGFloat, maskedCorners: CACornerMask) {
        guard let layer else {
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = max(cornerRadius, 0)
        layer.cornerCurve = .continuous
        layer.maskedCorners = maskedCorners
        CATransaction.commit()
    }

    // MARK: Private

    private func attachHostedViewIfNeeded() {
        if hostedView.superview !== self {
            hostedView.removeFromSuperview()
            addSubview(hostedView)
        }

        hostedView.autoresizingMask = [.width, .height]
        if hostedView.frame != bounds {
            hostedView.frame = bounds
        }
    }
}
