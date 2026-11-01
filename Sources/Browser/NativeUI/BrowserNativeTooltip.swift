// BrowserNativeTooltip.swift

import AppKit
import Combine

// MARK: - BrowserNativeTooltipMetrics

struct BrowserNativeTooltipMetrics {
    // MARK: Internal

    /// The view's size: the bubble plus the border that straddles its edge.
    let size: NSSize
    let textWidth: CGFloat
    let titleHeight: CGFloat
    let captionHeight: CGFloat
    let keysWidth: CGFloat
    let keyWidths: [CGFloat]

    init(title: String, caption: String?, shortcut: BrowserKeyboardShortcut?, maximumWidth: CGFloat) {
        let layout = BrowserChromeLayout.self
        let titleFont = NSFont.systemFont(ofSize: layout.tooltipTitleFontSize, weight: .medium)
        let captionFont = NSFont.systemFont(ofSize: layout.tooltipCaptionFontSize)
        let capFont = NSFont.systemFont(ofSize: layout.tooltipKeyFontSize, weight: .medium)
        let caps = shortcut?.keyCaps ?? []
        self.keyWidths = caps.map { max(
            ceil(($0 as NSString).size(withAttributes: [.font: capFont]).width) + layout
                .tooltipKeyHorizontalPadding * 2,
            layout.tooltipKeyHeight,
        ) }
        self.keysWidth = keyWidths.reduce(0, +) + CGFloat(max(keyWidths.count - 1, 0)) * layout.tooltipKeySpacing
        let accessoryWidth = caps.isEmpty ? 0 : keysWidth + layout.tooltipContentSpacing
        let idealTextWidth = max(
            (title as NSString).size(withAttributes: [.font: titleFont]).width,
            ((caption ?? "") as NSString).size(withAttributes: [.font: captionFont]).width,
        )
        let border = layout.tooltipBorderWidth
        // A label's frame is 2 pt wider than its text on each side.
        self.textWidth = min(
            ceil(idealTextWidth * 2) / 2 + 4,
            max(maximumWidth - border - layout.tooltipHorizontalPadding * 2 - accessoryWidth + 4, 1),
        )
        let measuredTextWidth = max(textWidth - 4, 1)
        func textHeight(_ string: String, font: NSFont) -> CGFloat {
            let measured = (string as NSString)
                .boundingRect(
                    with: NSSize(width: measuredTextWidth, height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font],
                )
                .height
            return min(ceil(measured), ceil((font.ascender - font.descender + font.leading) * 2))
        }
        self.titleHeight = textHeight(title, font: titleFont)
        self.captionHeight = caption.map { textHeight($0, font: captionFont) } ?? 0
        let padding = caption == nil ? layout.tooltipVerticalPadding : layout.tooltipCaptionVerticalPadding
        let bubbleHeight = max(
            titleHeight + captionHeight + padding * 2,
            caps.isEmpty ? 0 : layout.tooltipKeyHeight + layout.tooltipVerticalPadding * 2 - 4,
        )
        self.size = NSSize(
            width: min(
                maximumWidth,
                textWidth - 4 + accessoryWidth + layout.tooltipHorizontalPadding * 2 + border,
            ),
            height: bubbleHeight + border,
        )
    }
}

// MARK: - BrowserNativeTooltipContent

final class BrowserNativeTooltipContent: BrowserNativeSurface {
    // MARK: Internal

    override var intrinsicContentSize: NSSize { measuredSize(maximumWidth: BrowserChromeLayout.tooltipMaximumWidth) }

    // MARK: Private

    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let captionLabel = NSTextField(wrappingLabelWithString: "")
    private var caption: String?
    private var shortcut: BrowserKeyboardShortcut?
    private var placement = BrowserTooltipPlacement.belowLeading
    private var keyCaps = [BrowserNativeTooltipKeyCap]()

    init(title: String, caption: String?, shortcut: BrowserKeyboardShortcut?, placement: BrowserTooltipPlacement) {
        super.init(frame: .zero)
        setAccessibilityIdentifier("browser.tooltip")
        fillColor = BrowserChromeColors.tooltipBackground
        strokeColor = BrowserChromeColors.tooltipBorder
        strokeWidth = BrowserChromeLayout.tooltipBorderWidth
        titleLabel.font = .systemFont(ofSize: BrowserChromeLayout.tooltipTitleFontSize, weight: .medium)
        titleLabel.textColor = BrowserChromeColors.tooltipText
        captionLabel.font = .systemFont(ofSize: BrowserChromeLayout.tooltipCaptionFontSize)
        captionLabel.textColor = BrowserChromeColors.tooltipCaption
        for label in [titleLabel, captionLabel] {
            label.maximumNumberOfLines = 2
            addSubview(label)
        }
        configure(title: title, caption: caption, shortcut: shortcut, placement: placement)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let metrics = BrowserNativeTooltipMetrics(
            title: titleLabel.stringValue,
            caption: caption,
            shortcut: shortcut,
            maximumWidth: max(bounds.width, 1),
        )
        let border = BrowserChromeLayout.tooltipBorderWidth / 2
        let textHeight = metrics.titleHeight + metrics.captionHeight
        let top = (bounds.height - textHeight) / 2
        // Labels draw 2 pt inside their frames.
        titleLabel.frame = NSRect(
            x: border + BrowserChromeLayout.tooltipHorizontalPadding - 2,
            y: top,
            width: metrics.textWidth,
            height: metrics.titleHeight,
        )
        captionLabel.frame = NSRect(
            x: titleLabel.frame.minX,
            y: titleLabel.frame.maxY,
            width: metrics.textWidth,
            height: metrics.captionHeight,
        )
        var x = titleLabel.frame.maxX - 2 + BrowserChromeLayout.tooltipContentSpacing
        for (index, cap) in keyCaps.enumerated() {
            cap.frame = NSRect(
                x: x,
                y: (bounds.height - BrowserChromeLayout.tooltipKeyHeight) / 2,
                width: metrics.keyWidths[index],
                height: BrowserChromeLayout.tooltipKeyHeight,
            )
            x += metrics.keyWidths[index] + BrowserChromeLayout.tooltipKeySpacing
        }
        switch placement {
        case .belowLeading: cornerRadius = BrowserChromeLayout.tooltipCornerRadius
            roundsTopLeadingCorner = false
            topLeadingCornerRadius = BrowserChromeLayout.tooltipTopLeadingCornerRadius
        case .aboveCapsule: cornerRadius = bounds.height / 2
            roundsTopLeadingCorner = true
        }
    }

    /// The bubble's outline in `rect`, for the shadows behind it.
    func bubblePath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let radius = min(BrowserChromeLayout.tooltipCornerRadius, rect.height / 2)
        let leading = placement == .belowLeading
            ? min(BrowserChromeLayout.tooltipTopLeadingCornerRadius, radius)
            : radius
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + leading))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.minX + leading, y: rect.minY),
            radius: leading,
        )
        for (corner, next) in [
            (CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)),
            (CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)),
            (CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.minY)),
        ] {
            path.addArc(tangent1End: corner, tangent2End: next, radius: radius)
        }
        path.closeSubpath()
        return path
    }

    func measuredSize(maximumWidth: CGFloat) -> NSSize {
        BrowserNativeTooltipMetrics(
            title: titleLabel.stringValue,
            caption: caption,
            shortcut: shortcut,
            maximumWidth: maximumWidth,
        ).size
    }

    func configure(
        title: String,
        caption: String?,
        shortcut: BrowserKeyboardShortcut?,
        placement: BrowserTooltipPlacement,
    ) {
        titleLabel.stringValue = title
        captionLabel.stringValue = caption ?? ""
        captionLabel.isHidden = caption == nil
        self.caption = caption
        self.shortcut = shortcut
        self.placement = placement
        for cap in keyCaps {
            cap.removeFromSuperview()
        }
        keyCaps = (shortcut?.keyCaps ?? []).map { text in
            let cap = BrowserNativeTooltipKeyCap(text: text)
            addSubview(cap)
            return cap
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
}

// MARK: - BrowserNativeTooltipKeyCap

/// A key: a darker base with a soft gradient, and a lighter face that leaves
/// its bottom edge showing.
private final class BrowserNativeTooltipKeyCap: NSView {
    // MARK: Internal

    override var isFlipped: Bool { true }

    init(text: String) {
        super.init(frame: .zero)
        let label = BrowserNativeControls.label(
            text,
            size: BrowserChromeLayout.tooltipKeyFontSize,
            weight: .medium,
            color: BrowserChromeColors.tooltipKeyText,
        )
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        let inset = BrowserChromeLayout.tooltipKeyFaceInset
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(
                equalTo: topAnchor,
                constant: inset + BrowserChromeLayout.tooltipKeyFaceHeight / 2,
            ),
        ])
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_: NSRect) {
        let radius = BrowserChromeLayout.tooltipKeyCornerRadius
        let base = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        BrowserChromeColors.tooltipKeyBase.setFill()
        base.fill()
        NSGradient(
            colors: [
                .black.withAlphaComponent(0),
                .black.withAlphaComponent(0.05),
                .black.withAlphaComponent(0.1),
            ],
            atLocations: [0, 0.5, 1],
            colorSpace: .sRGB,
        )?.draw(in: base, angle: 90)
        let inset = BrowserChromeLayout.tooltipKeyFaceInset
        let faceRadius = BrowserChromeLayout.tooltipKeyFaceCornerRadius
        BrowserChromeColors.tooltipKeyBackground.setFill()
        NSBezierPath(
            roundedRect: NSRect(
                x: inset,
                y: inset,
                width: max(bounds.width - inset * 2, 0),
                height: BrowserChromeLayout.tooltipKeyFaceHeight,
            ),
            xRadius: faceRadius,
            yRadius: faceRadius,
        ).fill()
    }
}

// MARK: - BrowserNativeTooltipPanelView

/// The tooltip's panel: margins around the bubble, and the two soft shadows
/// that fall into them.
private final class BrowserNativeTooltipPanelView: NSView {
    // MARK: Internal

    override var isFlipped: Bool { true }

    // MARK: Private

    private let outerShadow = CALayer()
    private let innerShadow = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for (shadow, radius, opacity, offset) in [
            (
                outerShadow,
                BrowserChromeLayout.tooltipOuterShadowRadius,
                BrowserChromeLayout.tooltipOuterShadowOpacity,
                BrowserChromeLayout.tooltipOuterShadowOffset,
            ),
            (
                innerShadow,
                BrowserChromeLayout.tooltipInnerShadowRadius,
                BrowserChromeLayout.tooltipInnerShadowOpacity,
                0,
            ),
        ] {
            shadow.shadowColor = NSColor.black.cgColor
            shadow.shadowRadius = radius
            shadow.shadowOpacity = opacity
            shadow.shadowOffset = CGSize(width: 0, height: offset)
            layer?.addSublayer(shadow)
        }
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ content: BrowserNativeTooltipContent, size: NSSize) {
        for view in subviews {
            view.removeFromSuperview()
        }
        let margin = BrowserChromeLayout.tooltipPanelMargin
        let contentFrame = NSRect(x: margin, y: margin, width: size.width, height: size.height)
        content.frame = contentFrame
        addSubview(content)
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        let border = BrowserChromeLayout.tooltipBorderWidth / 2
        let path = content.bubblePath(in: contentFrame.insetBy(dx: border, dy: border))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shadow in [outerShadow, innerShadow] {
            shadow.frame = bounds
            shadow.shadowPath = path
        }
        CATransaction.commit()
    }
}

// MARK: - BrowserNativeTooltipPresenter

@MainActor final class BrowserNativeTooltipPresenter: NSObject {
    // MARK: Private

    private struct Descriptor {
        let id: UUID
        let title: String
        let caption: String?
        let shortcut: BrowserKeyboardShortcut?
        let placement: BrowserTooltipPlacement
        let anchorXFraction: CGFloat
    }

    // MARK: Internal

    static let shared = BrowserNativeTooltipPresenter()

    /// While a Space is swiped the rows pass under the pointer; they must not show tooltips.
    var isSuppressed = false {
        didSet {
            if isSuppressed, let descriptor {
                end(id: descriptor.id, detached: true)
            }
        }
    }

    private var hoveredID: UUID?
    private weak var anchor: NSView?
    private var descriptor: Descriptor?
    private let coordinator = BrowserTooltipCoordinator()
    private var observation: AnyCancellable?
    private var panel: NSPanel?
    private let visibilityAnimation = BrowserNativeAnimation()

    override init() {
        super.init()
        self.observation = coordinator.$activeTooltipID.sink { [weak self] id in
            guard let self else { return }
            if id == descriptor?.id, id != nil {
                show()
            } else {
                hide(curve: .tooltipFade)
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDeactivated),
            name: NSApplication.didResignActiveNotification,
            object: nil,
        )
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowGeometryChanged),
                name: name,
                object: nil,
            )
        }
    }

    func begin(
        id: UUID,
        anchor: NSView,
        title: String,
        caption: String? = nil,
        shortcut: BrowserKeyboardShortcut? = nil,
        placement: BrowserTooltipPlacement = .belowLeading,
        anchorXFraction: CGFloat = BrowserChromeLayout.tooltipAnchorXFraction,
        target: BrowserTooltipCoordinator.Target = .button,
    ) {
        guard !isSuppressed else { return }
        let isAlreadyHovering = hoveredID == id
        hoveredID = id
        self.anchor = anchor
        descriptor = Descriptor(
            id: id,
            title: title,
            caption: caption,
            shortcut: shortcut,
            placement: placement,
            anchorXFraction: anchorXFraction,
        )
        if isAlreadyHovering {
            if coordinator.activeTooltipID == id {
                show()
            }
        } else {
            coordinator.setHovering(true, for: id, target: target)
        }
    }

    func end(id: UUID, detached: Bool = false) {
        guard descriptor?.id == id else { return }
        if hoveredID == id {
            hoveredID = nil
            coordinator.setHovering(false, for: id)
        }
        if detached {
            hide()
            anchor = nil
            descriptor = nil
        }
    }

    private func show() {
        guard let descriptor, let anchor, let window = anchor.window, window.isVisible,
              !anchor.isHiddenOrHasHiddenAncestor, !anchor.visibleRect.isEmpty
        else { hide()
            return
        }
        let panel: NSPanel
        if let existing = self.panel {
            panel = existing
        } else {
            panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false,
            )
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .floating
            panel.collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
            self.panel = panel
        }
        let screenFrame = window.styleMask.contains(.fullScreen)
            ? window.frame
            : (window.screen?.visibleFrame ?? window.frame)
        let source = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let content = BrowserNativeTooltipContent(
            title: descriptor.title,
            caption: descriptor.caption,
            shortcut: descriptor.shortcut,
            placement: descriptor.placement,
        )
        let size = content.measuredSize(maximumWidth: min(
            BrowserChromeLayout.tooltipMaximumWidth,
            max(
                screenFrame.width - BrowserChromeLayout
                    .tooltipViewportPadding * 2,
                1,
            ),
        ))
        let origin = BrowserTooltipPlacementResolver.topLeft(
            sourceFrame: CGRect(
                x: source.minX - screenFrame.minX,
                y: screenFrame.maxY - source.maxY,
                width: source.width,
                height: source.height,
            ),
            tooltipSize: size,
            containerSize: screenFrame.size,
            placement: descriptor.placement,
            verticalGap: BrowserChromeLayout.tooltipVerticalGap,
            anchorXFraction: descriptor.anchorXFraction,
            anchorYFraction: BrowserChromeLayout.tooltipAnchorYFraction,
            viewportPadding: BrowserChromeLayout.tooltipViewportPadding,
        )
        let margin = BrowserChromeLayout.tooltipPanelMargin
        let panelSize = NSSize(width: size.width + margin * 2, height: size.height + margin * 2)
        panel.appearance = window.effectiveAppearance
        let panelView = BrowserNativeTooltipPanelView(frame: NSRect(origin: .zero, size: panelSize))
        panel.contentView = panelView
        panel.setFrame(NSRect(
            x: screenFrame.minX + origin.x - margin,
            y: screenFrame.maxY - origin.y - size.height - margin,
            width: panelSize.width,
            height: panelSize.height,
        ), display: false)
        panelView.show(content, size: size)
        panel.displayIfNeeded()
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        visibilityAnimation.cancel()
        panel.alphaValue = 1
        panel.orderFront(nil)
    }

    private func hide(curve: BrowserNativeAnimation.Curve = .tooltipOut) {
        guard let panel else { return }
        let from = panel.alphaValue
        visibilityAnimation.start(curve) { [weak panel] progress in
            panel?.alphaValue = from * (1 - progress)
        } completion: { [weak panel] in
            guard let panel else { return }
            panel.orderOut(nil)
            panel.parent?.removeChildWindow(panel)
        }
    }

    @objc private func applicationDeactivated() {
        if let descriptor {
            end(id: descriptor.id, detached: true)
        }
        hide()
    }

    @objc private func windowGeometryChanged(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === anchor?.window,
              coordinator.activeTooltipID == descriptor?.id else { return }
        show()
    }
}
