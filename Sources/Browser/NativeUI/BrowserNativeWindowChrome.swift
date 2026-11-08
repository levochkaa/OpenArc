// BrowserNativeWindowChrome.swift

import AppKit

// MARK: - BrowserChromeBackgroundMode

enum BrowserChromeBackgroundMode: Hashable { case blurred, black }

// MARK: - BrowserChromeBackgroundNSView

final class BrowserChromeBackgroundNSView: NSView {
    // MARK: Private

    /// One theme's gradient and its texture above it.
    private final class ThemeLayerView: NSView {
        let gradient = CALayer()
        let texture = CALayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            gradient.contentsGravity = .resize
            layer?.addSublayer(gradient)
            layer?.addSublayer(texture)
        }

        @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gradient.frame = bounds
            texture.frame = bounds
            CATransaction.commit()
        }

        func render(_ theme: BrowserSpaceTheme?, aspect: CGFloat, isDark: Bool) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let theme {
                gradient.contents = BrowserSpaceThemeRenderer.image(for: theme, aspect: aspect, isDark: isDark)
                let strength = theme.noise * theme.texture.strength
                texture.isHidden = strength <= 0
                texture.opacity = Float(strength)
                texture.backgroundColor = NSColor(patternImage: BrowserSpaceThemeTexture.tile(theme.texture)).cgColor
            } else {
                gradient.contents = nil
                texture.isHidden = true
            }
            CATransaction.commit()
        }
    }

    // MARK: Internal

    var mode = BrowserChromeBackgroundMode.blurred { didSet { update() } }

    private let effect = NSVisualEffectView()
    private let themeContainer = NSView()
    private let currentTheme = ThemeLayerView()
    private let incomingTheme = ThemeLayerView()
    private var theme: BrowserSpaceTheme?
    private var incoming: BrowserSpaceTheme?
    private var renderedAspect: CGFloat = 0
    private var renderedIsDark = false

    private var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(effect)
        addSubview(themeContainer)
        themeContainer.wantsLayer = true
        themeContainer.addSubview(currentTheme)
        themeContainer.addSubview(incomingTheme)
        incomingTheme.alphaValue = 0
        effect.blendingMode = .behindWindow
        effect.state = .active
        update()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    override func hitTest(_: NSPoint) -> NSView? { nil }
    override func layout() { super.layout()
        effect.frame = bounds
        themeContainer.frame = bounds
        currentTheme.frame = bounds
        incomingTheme.frame = bounds
        renderThemes()
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance()
        update()
        renderThemes(force: true)
    }

    override func draw(_: NSRect) {
        if mode == .black {
            BrowserChromeColors.solidBackground.setFill()
            bounds.fill()
        }
    }

    /// The selected Space's theme, nil for neutral. A different Space's theme
    /// cross-fades as its page slides in; edits in progress apply at once.
    func setTheme(_ theme: BrowserSpaceTheme?, animated: Bool, delay: CFTimeInterval = 0) {
        let next = theme?.colors.isEmpty == true ? nil : theme
        guard next != self.theme else { return }
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = BrowserNativeAnimation.Curve.spaceSlide.duration
            fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.215, 0.61, 0.355, 1)
            if delay > 0 {
                fade.beginTime = CACurrentMediaTime() + delay
                fade.fillMode = .backwards
            }
            themeContainer.layer?.add(fade, forKey: "theme")
        }
        self.theme = next
        incoming = nil
        incomingTheme.alphaValue = 0
        renderThemes(force: true)
    }

    /// During a swipe, blends in the theme of the Space it is moving toward.
    func setSwipeTransition(toward theme: BrowserSpaceTheme?, progress: CGFloat) {
        let next = theme?.colors.isEmpty == true ? nil : theme
        guard progress > 0 else {
            if incomingTheme.alphaValue != 0 {
                incoming = nil
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                incomingTheme.alphaValue = 0
                currentTheme.alphaValue = 1
                CATransaction.commit()
            }
            return
        }
        if next != incoming || incomingTheme.alphaValue == 0 {
            incoming = next
            incomingTheme.render(next, aspect: max(bounds.width, 1) / max(bounds.height, 1), isDark: appliedDark(next))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        incomingTheme.alphaValue = progress
        currentTheme.alphaValue = 1 - progress
        CATransaction.commit()
    }

    private func appliedDark(_ theme: BrowserSpaceTheme?) -> Bool {
        switch theme?.mode {
        case .light: false
        case .dark: true
        default: isDark
        }
    }

    private func update() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        effect.isHidden = mode != .blurred
        effect.material = dark ? .hudWindow : .sidebar
        needsDisplay = true
    }

    private func renderThemes(force: Bool = false) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let aspect = bounds.width / bounds.height
        let isDark = appliedDark(theme)
        guard force || abs(aspect - renderedAspect) > 0.005 || isDark != renderedIsDark else { return }
        currentTheme.alphaValue = 1
        currentTheme.render(theme, aspect: aspect, isDark: isDark)
        renderedAspect = aspect
        renderedIsDark = isDark
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

    func configure(
        blockedLeadingWidth: CGFloat,
        blockedTrailingWidth: CGFloat = 0,
        leading: CGFloat,
        top: CGFloat,
        trailing: CGFloat,
        bottom: CGFloat,
    ) {
        let width = max(bounds.width - blockedLeadingWidth - blockedTrailingWidth, 0)
        let trailingEdge = max(bounds.width - blockedTrailingWidth, 0)
        regions = [
            CGRect(x: blockedLeadingWidth, y: 0, width: width, height: top),
            CGRect(x: blockedLeadingWidth, y: max(bounds.height - bottom, 0), width: width, height: bottom),
            CGRect(x: max(trailingEdge - trailing, 0), y: 0, width: trailing, height: bounds.height),
            CGRect(x: blockedLeadingWidth, y: 0, width: leading, height: bounds.height),
        ].filter { !$0.isEmpty }
    }
}

// MARK: - BrowserNativeSidebarRevealEdge

final class BrowserNativeSidebarRevealEdge: NSView {
    // MARK: Internal

    var onHoverChange: (Bool) -> Void = { _ in }

    // MARK: Private

    private var tracking: NSTrackingArea?

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
            owner: self,
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with _: NSEvent) { onHoverChange(true) }
    override func mouseExited(with _: NSEvent) { onHoverChange(false) }
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
            result: Self.result(
                query: model.findQuery,
                count: model.findResultMatchCount,
                active: model.findResultActiveOrdinal,
            ),
            focusRequestID: model.findBarFocusRequest,
            blockedLeadingInset: blockedLeadingInset,
        )
    }

    static func result(query: String, count: Int?, active: Int?) -> Result {
        guard !query.isEmpty, let count else { return .none }
        guard count > 0 else { return .notFound }
        return .matches(active: active.flatMap { (1...count).contains($0) ? $0 : nil }, count: count)
    }
}
