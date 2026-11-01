// BrowserLinkStatusView.swift

import AppKit

/// The address of the link under the pointer, in a pill at the page's bottom corner.
final class BrowserLinkStatusView: BrowserNativeSurface {
    // MARK: Internal

    static let height: CGFloat = 22
    static let inset: CGFloat = 6

    private static let showDelay: TimeInterval = 0.45

    // MARK: Private

    private let label = BrowserNativeControls.label("", size: 11, color: .white)
    private let visibility = BrowserNativeVisibilityAnimation()
    private var wantsVisible = false
    private var showWorkItem: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        fillColor = NSColor.black.withAlphaComponent(0.85)
        strokeColor = NSColor.white.withAlphaComponent(0.15)
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

    static func displayText(for status: String) -> String {
        var text = status
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) {
            text.removeFirst(scheme.count)
        }
        if text.hasPrefix("www.") {
            text.removeFirst(4)
        }
        return text.hasSuffix("/") ? String(text.dropLast()) : text
    }

    /// The width it wants for `status`, up to `maximumWidth`. The pill waits a moment before it
    /// appears, so moving the pointer across links shows nothing; once shown it follows at once.
    func update(status: String?, maximumWidth: CGFloat) -> CGFloat {
        if let status {
            label.stringValue = Self.displayText(for: status)
        }
        if (status != nil) != wantsVisible {
            wantsVisible = status != nil
            showWorkItem?.cancel()
            showWorkItem = nil
            if wantsVisible {
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    visibility.setVisible(true, view: self, curve: .linkStatus)
                }
                showWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDelay, execute: workItem)
            } else {
                visibility.setVisible(false, view: self, curve: .hover)
            }
        }
        return min(ceil(label.intrinsicContentSize.width) + 24, maximumWidth)
    }
}
