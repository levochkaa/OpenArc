// BrowserLinkStatusView.swift

import AppKit

/// The address of the link under the pointer, in a pill at the page's bottom corner.
final class BrowserLinkStatusView: BrowserNativeSurface {
    // MARK: Internal

    static let height: CGFloat = 22
    static let inset: CGFloat = 6

    // MARK: Private

    private let label = BrowserNativeControls.label("", size: 11, color: .white)
    private let visibility = BrowserNativeVisibilityAnimation()

    override init(frame: NSRect) {
        super.init(frame: frame)
        fillColor = NSColor.black.withAlphaComponent(0.85)
        cornerRadius = Self.height / 2
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        addSubview(label)
        isHidden = true
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 10, dy: 3)
    }

    /// The width it wants for `status`, up to `maximumWidth`.
    func update(status: String?, maximumWidth: CGFloat) -> CGFloat {
        if let status {
            label.stringValue = status
        }
        visibility.setVisible(status != nil, view: self, curve: .hover)
        return min(ceil(label.intrinsicContentSize.width) + 20, maximumWidth)
    }
}
