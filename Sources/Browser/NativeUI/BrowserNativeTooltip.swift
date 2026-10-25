// BrowserNativeTooltip.swift

import AppKit
import Combine

// MARK: - BrowserNativeTooltipMetrics

struct BrowserNativeTooltipMetrics {
    // MARK: Internal

    let size: NSSize
    let textWidth: CGFloat
    let titleHeight: CGFloat
    let captionHeight: CGFloat
    let keysWidth: CGFloat
    let keyWidths: [CGFloat]

    init(title: String, caption: String?, shortcut: BrowserKeyboardShortcut?, maximumWidth: CGFloat) {
        let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let captionFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let capFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        let caps = shortcut?.keyCaps ?? []
        self.keyWidths = caps.map { max(
            ceil(($0 as NSString).size(withAttributes: [.font: capFont]).width) + BrowserChromeLayout
                .tooltipKeyHorizontalPadding * 2,
            BrowserChromeLayout.tooltipKeyHeight,
        ) }
        self.keysWidth = keyWidths.reduce(0, +) + CGFloat(max(keyWidths.count - 1, 0)) * BrowserChromeLayout
            .tooltipKeySpacing
        let accessoryWidth = caps.isEmpty ? 0 : keysWidth + BrowserChromeLayout.tooltipContentSpacing
        let idealTextWidth = max(
            (title as NSString).size(withAttributes: [.font: titleFont]).width,
            ((caption ?? "") as NSString).size(withAttributes: [.font: captionFont]).width,
        )
        self.textWidth = min(
            ceil(idealTextWidth) + 4,
            max(maximumWidth - BrowserChromeLayout.tooltipHorizontalPadding * 2 - accessoryWidth, 1),
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
            return min(ceil(measured), ceil((font.ascender - font.descender + font.leading) * 2)) + 2
        }
        self.titleHeight = textHeight(title, font: titleFont)
        self.captionHeight = caption.map { textHeight($0, font: captionFont) } ?? 0
        let textHeight = titleHeight + (caption == nil ? 0 : 2 + captionHeight)
        self.size = NSSize(
            width: min(maximumWidth, textWidth + accessoryWidth + BrowserChromeLayout.tooltipHorizontalPadding * 2),
            height: max(textHeight, caps.isEmpty ? 0 : BrowserChromeLayout.tooltipKeyHeight) + BrowserChromeLayout
                .tooltipVerticalPadding * 2,
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
    private var keyCaps = [BrowserNativeSurface]()

    init(title: String, caption: String?, shortcut: BrowserKeyboardShortcut?, placement: BrowserTooltipPlacement) {
        super.init(frame: .zero)
        setAccessibilityIdentifier("browser.tooltip")
        fillColor = BrowserChromeColors.tooltipBackground
        strokeColor = BrowserChromeColors.tooltipBorder
        strokeWidth = BrowserChromeLayout.tooltipBorderWidth
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.textColor = BrowserChromeColors.tooltipText
        captionLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
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
        let textHeight = metrics.titleHeight + (caption == nil ? 0 : 2 + metrics.captionHeight)
        let top = (bounds.height - textHeight) / 2
        titleLabel.frame = NSRect(
            x: BrowserChromeLayout.tooltipHorizontalPadding,
            y: top,
            width: metrics.textWidth,
            height: metrics.titleHeight,
        )
        captionLabel.frame = NSRect(
            x: titleLabel.frame.minX,
            y: titleLabel.frame.maxY + 2,
            width: metrics.textWidth,
            height: metrics.captionHeight,
        )
        var x = titleLabel.frame.maxX + BrowserChromeLayout.tooltipContentSpacing
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
        case .aboveCapsule: cornerRadius = bounds.height / 2
            roundsTopLeadingCorner = true
        }
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
            let cap = BrowserNativeSurface()
            cap.cornerRadius = 6
            cap.fillColor = BrowserChromeColors.tooltipKeyBackground
            let label = BrowserNativeControls.label(
                text,
                size: 11.5,
                weight: .semibold,
                color: BrowserChromeColors.tooltipKeyText,
            )
            cap.addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: cap.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: cap.centerYAnchor),
            ])
            addSubview(cap)
            return cap
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
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
    }

    // MARK: Internal

    static let shared = BrowserNativeTooltipPresenter()

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
                hide()
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
    ) {
        let isAlreadyHovering = hoveredID == id
        hoveredID = id
        self.anchor = anchor
        descriptor = Descriptor(id: id, title: title, caption: caption, shortcut: shortcut, placement: placement)
        if isAlreadyHovering {
            if coordinator.activeTooltipID == id {
                show()
            }
        } else {
            coordinator.setHovering(true, for: id)
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
            panel.hasShadow = true
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
            tooltipSize: size, containerSize: screenFrame.size, placement: descriptor.placement,
        )
        panel.appearance = window.effectiveAppearance
        panel.contentView = content
        panel.setFrame(NSRect(
            x: screenFrame.minX + origin.x,
            y: screenFrame.maxY - origin.y - size.height,
            width: size.width,
            height: size.height,
        ), display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        let from = panel.isVisible ? panel.alphaValue : 0
        panel.alphaValue = from
        panel.orderFront(nil)
        visibilityAnimation.start(.appearance) { [weak panel] progress in
            panel?.alphaValue = from + (1 - from) * progress
        }
    }

    private func hide() {
        guard let panel else { return }
        let from = panel.alphaValue
        visibilityAnimation.start(.appearance) { [weak panel] progress in
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
