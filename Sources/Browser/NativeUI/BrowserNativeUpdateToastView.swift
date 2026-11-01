// BrowserNativeUpdateToastView.swift

import AppKit

/// A pill that rises above the dock when an update is ready, and opens into a card under the pointer.
final class BrowserNativeUpdateToastView: NSView {
    // MARK: Internal

    static let collapsedHeight: CGFloat = 24
    static let expandedHeight: CGFloat = 88.5

    // MARK: Private

    private static let appearDistance: CGFloat = 32
    private static let expandDelay: TimeInterval = 0.3

    override var isFlipped: Bool { true }

    var onInstall: () -> Void = {}
    var onAutomaticUpdatesChanged: (Bool) -> Void = { _ in }
    var onExpansionChanged: () -> Void = {}

    private let surface = BrowserNativeSurface()
    private let title = BrowserNativeControls.label("", size: 12)
    private let divider = NSView()
    private let automaticUpdates = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let install = BrowserNativePressableView()
    private let installFill = CAGradientLayer()
    private let actionTitle = BrowserNativeControls.label("", size: 12, weight: .medium, color: .white)
    private let expansionAnimation = BrowserNativeAnimation()

    private var expansion = 0.0
    private var isExpandedTarget = false
    private var expandWorkItem: DispatchWorkItem?
    private var tracking: NSTrackingArea?

    var displayHeight: CGFloat {
        Self.collapsedHeight + (Self.expandedHeight - Self.collapsedHeight) * expansion
    }

    var isAutomaticUpdatesOn: Bool {
        get { automaticUpdates.state == .on }
        set { automaticUpdates.state = newValue ? .on : .off }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        surface.cornerRadius = 12
        addSubview(surface)
        title.alignment = .center
        divider.wantsLayer = true
        automaticUpdates.controlSize = .small
        automaticUpdates.font = .systemFont(ofSize: 12)
        automaticUpdates.title = BrowserStrings.settingsAutomaticUpdates
        automaticUpdates.target = self
        automaticUpdates.action = #selector(automaticUpdatesToggled)
        install.wantsLayer = true
        install.layer?.cornerRadius = 6
        install.layer?.cornerCurve = .continuous
        install.layer?.masksToBounds = true
        install.cornerRadius = 6
        install.fillColor = NSColor(red: 0.11, green: 0.153, blue: 0.988, alpha: 1)
        install.strokeColor = NSColor.white.withAlphaComponent(0.2)
        installFill.type = .radial
        installFill.colors = [
            NSColor(red: 0.5, green: 0.22, blue: 0.94, alpha: 1).cgColor,
            NSColor(red: 0.5, green: 0.22, blue: 0.94, alpha: 0).cgColor,
        ]
        installFill.startPoint = CGPoint(x: 0.37, y: 1)
        installFill.endPoint = CGPoint(x: 0.67, y: 0)
        install.layer?.addSublayer(installFill)
        actionTitle.alignment = .center
        install.addSubview(actionTitle)
        install.onClick = { [weak self] _ in self?.onInstall() }
        for subview in [title, divider, automaticUpdates, install] {
            surface.addSubview(subview)
        }
        applyExpansion()
        setAccessibilityIdentifier("browser.update.toast")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        install.setAccessibilityIdentifier("browser.update.install")
        automaticUpdates.setAccessibilityIdentifier("browser.update.automatic")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        surface.frame = bounds
        let width = bounds.width
        title.frame = NSRect(x: 8, y: 4, width: max(width - 16, 0), height: 16)
        divider.frame = NSRect(x: 0, y: Self.collapsedHeight, width: width, height: 1)
        let checkboxSize = automaticUpdates.intrinsicContentSize
        automaticUpdates.frame = NSRect(
            x: (width - min(checkboxSize.width, width)) / 2,
            y: 40.5 - checkboxSize.height / 2,
            width: min(checkboxSize.width, width),
            height: checkboxSize.height,
        )
        install.frame = NSRect(x: 8, y: 56.5, width: max(width - 16, 0), height: 24)
        actionTitle.frame = NSRect(x: 4, y: 4, width: max(install.frame.width - 8, 0), height: 16)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        installFill.frame = install.bounds
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with _: NSEvent) {
        expandWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.setExpanded(true, animated: true) }
        expandWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.expandDelay, execute: workItem)
    }

    override func mouseExited(with _: NSEvent) {
        expandWorkItem?.cancel()
        expandWorkItem = nil
        setExpanded(false, animated: true)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyExpansion()
    }

    func update(_ toast: BrowserUpdateToast) {
        title.stringValue = toast.title
        actionTitle.stringValue = toast.actionTitle
        install.setAccessibilityLabel(toast.actionTitle)
    }

    /// Rises from behind the dock, with the fade following the same spring.
    func playAppear() {
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let slide = BrowserNativeAnimation.Curve.toastAppear.layerAnimation(keyPath: "position")
        slide.isAdditive = true
        slide.fromValue = NSValue(point: CGPoint(x: 0, y: Self.appearDistance))
        slide.toValue = NSValue(point: .zero)
        layer?.add(slide, forKey: "browser.toast.slide")
        let fade = BrowserNativeAnimation.Curve.toastAppear.layerAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        layer?.add(fade, forKey: "browser.toast.fade")
    }

    func setExpanded(_ expanded: Bool, animated: Bool) {
        guard isExpandedTarget != expanded else { return }
        isExpandedTarget = expanded
        expansionAnimation.cancel()
        let to = expanded ? 1.0 : 0.0
        guard animated, window != nil else {
            setExpansion(to)
            return
        }
        let from = expansion
        expansionAnimation.start(expanded ? .toastExpand : .toastCollapse) { [weak self] progress in
            self?.setExpansion(from + (to - from) * progress)
        }
    }

    func reset() {
        expandWorkItem?.cancel()
        expandWorkItem = nil
        layer?.removeAnimation(forKey: "browser.toast.slide")
        layer?.removeAnimation(forKey: "browser.toast.fade")
        setExpanded(false, animated: false)
    }

    @objc private func automaticUpdatesToggled() {
        onAutomaticUpdatesChanged(automaticUpdates.state == .on)
    }

    private func setExpansion(_ value: Double) {
        expansion = value
        applyExpansion()
        onExpansionChanged()
    }

    private func applyExpansion() {
        let progress = max(min(expansion, 1), 0)
        let foreground: CGFloat = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 1 : 0
        surface.fillColor = NSColor(
            white: foreground + (1 - 2 * foreground) * progress,
            alpha: 0.1 + 0.9 * progress,
        )
        surface.strokeColor = NSColor(white: foreground, alpha: 0.24 - 0.15 * progress)
        title.textColor = NSColor(white: foreground, alpha: 1)
        divider.layer?.backgroundColor = NSColor(white: foreground, alpha: 0.11).cgColor
        divider.alphaValue = progress
        automaticUpdates.alphaValue = progress
        install.alphaValue = progress
    }
}
