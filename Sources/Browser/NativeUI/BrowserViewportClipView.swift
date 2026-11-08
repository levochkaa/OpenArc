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

    /// Keeps the page at this size, top-left aligned and clipped, while the
    /// viewport is narrower, so that it does not lay out again.
    var fixedHostedSize: CGSize? {
        didSet {
            guard fixedHostedSize != oldValue else { return }
            attachHostedViewIfNeeded()
        }
    }

    private var hostedFrame: CGRect {
        fixedHostedSize.map { size in
            CGRect(x: 0, y: isFlipped ? 0 : bounds.height - size.height, width: size.width, height: size.height)
        } ?? bounds
    }

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
        if hostedView.frame != hostedFrame {
            hostedView.frame = hostedFrame
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

        // A fixed page stays put at the top left while the viewport slides and narrows.
        hostedView.autoresizingMask = fixedHostedSize == nil ? [.width, .height] : [.maxXMargin, .minYMargin]
        if hostedView.frame != hostedFrame {
            hostedView.frame = hostedFrame
        }
    }
}
