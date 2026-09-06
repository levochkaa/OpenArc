import AppKit

// MARK: - BrowserChromeBackgroundMode

enum BrowserChromeBackgroundMode: Hashable { case blurred, black }

// MARK: - BrowserChromeBackgroundNSView

final class BrowserChromeBackgroundNSView: NSView {
    // MARK: Lifecycle

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(effect)
        effect.blendingMode = .behindWindow
        effect.state = .active
        update()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    // MARK: Internal

    var mode = BrowserChromeBackgroundMode.blurred { didSet { update() } }

    override func hitTest(_: NSPoint) -> NSView? { nil }
    override func layout() { super.layout()
        effect.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance()
        update()
    }

    override func draw(_: NSRect) {
        if mode == .black {
            BrowserChromeColors.solidBackground.setFill()
            bounds.fill()
        }
    }

    // MARK: Private

    private let effect = NSVisualEffectView()

    private func update() {
        effect.isHidden = mode != .blurred
        effect.material = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .hudWindow : .sidebar
        needsDisplay = true
    }
}

// MARK: - BrowserNativeWindowMargins

/// The transparent portions pass pointer events to CEF; only the visible window margins drag.
final class BrowserNativeWindowMargins: NSView {
    override var isFlipped: Bool { true }

    var regions = [CGRect]()
    var menuProvider: (() -> NSMenu?)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return !isHidden && regions.contains(where: { $0.contains(local) }) ? self : nil
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func menu(for _: NSEvent) -> NSMenu? { menuProvider?() }

    func configure(blockedLeadingWidth: CGFloat, leading: CGFloat, top: CGFloat, trailing: CGFloat, bottom: CGFloat) {
        regions = [
            CGRect(x: blockedLeadingWidth, y: 0, width: max(bounds.width - blockedLeadingWidth, 0), height: top),
            CGRect(
                x: blockedLeadingWidth,
                y: max(bounds.height - bottom, 0),
                width: max(bounds.width - blockedLeadingWidth, 0),
                height: bottom
            ),
            CGRect(x: max(bounds.width - trailing, 0), y: 0, width: trailing, height: bounds.height),
            CGRect(x: blockedLeadingWidth, y: 0, width: leading, height: bounds.height),
        ].filter { !$0.isEmpty }
    }
}

// MARK: - BrowserNativeSidebarRevealEdge

final class BrowserNativeSidebarRevealEdge: NSView {
    // MARK: Internal

    var onHoverChange: (Bool) -> Void = { _ in }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with _: NSEvent) { onHoverChange(true) }
    override func mouseExited(with _: NSEvent) { onHoverChange(false) }

    // MARK: Private

    private var tracking: NSTrackingArea?
}

extension BrowserFindBarNSView {
    func bind(to model: BrowserChromeModel) {
        queryField.focusPermission = { [weak model] in model?.isFindBarPresented == true }
        onQueryChanged = { [weak model] in model?.findQuery = $0 }
        onNext = { [weak model] in model?.findNextInPage() }
        onPrevious = { [weak model] in model?.findPreviousInPage() }
        onDismiss = { [weak model] in model?.dismissFindBar() }
    }

    func refresh(from model: BrowserChromeModel, blockedLeadingInset: CGFloat) {
        update(
            query: model.findQuery,
            isPresented: model.isFindBarPresented,
            canStep: model.canStepThroughFindMatches,
            focusRequestID: model.findBarFocusRequest,
            blockedLeadingInset: blockedLeadingInset
        )
    }
}
