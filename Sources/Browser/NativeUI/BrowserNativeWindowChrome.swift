// BrowserNativeWindowChrome.swift

import AppKit

// MARK: - BrowserChromeBackgroundMode

enum BrowserChromeBackgroundMode: Hashable { case blurred, black }

// MARK: - BrowserChromeBackgroundNSView

final class BrowserChromeBackgroundNSView: NSView {
    // MARK: Internal

    var mode = BrowserChromeBackgroundMode.blurred { didSet { update() } }

    // MARK: Private

    private let effect = NSVisualEffectView()
    private let themeView = NSView()
    private let textureView = NSView()
    private var theme: BrowserSpaceTheme?
    private var renderedAspect: CGFloat = 0
    private var renderedIsDark = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(effect)
        addSubview(themeView)
        addSubview(textureView)
        effect.blendingMode = .behindWindow
        effect.state = .active
        themeView.wantsLayer = true
        themeView.layer?.contentsGravity = .resize
        textureView.wantsLayer = true
        update()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    override func hitTest(_: NSPoint) -> NSView? { nil }
    override func layout() { super.layout()
        effect.frame = bounds
        themeView.frame = bounds
        textureView.frame = bounds
        renderTheme()
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance()
        update()
        renderTheme(force: true)
    }

    override func draw(_: NSRect) {
        if mode == .black {
            BrowserChromeColors.solidBackground.setFill()
            bounds.fill()
        }
    }

    /// The selected Space's theme, nil for neutral. A different Space's theme
    /// cross-fades; edits in progress apply at once.
    func setTheme(_ theme: BrowserSpaceTheme?, animated: Bool) {
        let next = theme?.colors.isEmpty == true ? nil : theme
        guard next != self.theme else { return }
        self.theme = next
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.25
            fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
            themeView.layer?.add(fade, forKey: "theme")
            textureView.layer?.add(fade, forKey: "theme")
        }
        renderTheme(force: true)
    }

    private func update() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        effect.isHidden = mode != .blurred
        effect.material = dark ? .hudWindow : .sidebar
        needsDisplay = true
    }

    private func renderTheme(force: Bool = false) {
        guard let theme, bounds.width > 0, bounds.height > 0 else {
            themeView.layer?.contents = nil
            textureView.isHidden = true
            renderedAspect = 0
            return
        }
        let aspect = bounds.width / bounds.height
        let isDark =
            switch theme.mode {
            case .automatic: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            case .light: false
            case .dark: true
            }
        if force || abs(aspect - renderedAspect) > 0.005 || isDark != renderedIsDark {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            themeView.layer?.contents = BrowserSpaceThemeRenderer.image(for: theme, aspect: aspect, isDark: isDark)
            let strength = theme.noise * theme.texture.strength
            textureView.isHidden = strength <= 0
            textureView.layer?.opacity = Float(strength)
            textureView.layer?.backgroundColor = NSColor(patternImage: BrowserSpaceThemeTexture.tile(theme.texture))
                .cgColor
            CATransaction.commit()
            renderedAspect = aspect
            renderedIsDark = isDark
        }
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
            focusRequestID: model.findBarFocusRequest,
            blockedLeadingInset: blockedLeadingInset,
        )
    }
}
