// BrowserTabSwitcherNSView.swift

import AppKit

// MARK: - BrowserTabSwitcherKeys

/// Control-Tab opens the switcher and moves through it, Shift goes back, and releasing Control picks the tab.
enum BrowserTabSwitcherKeys {
    private static let tabKeyCode: UInt16 = 48

    static func isSwitcherTab(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.keyCode == tabKeyCode
            && modifiers.contains(.control)
            && !modifiers.contains(.command)
            && !modifiers.contains(.option)
    }

    static func isControlReleased(_ event: NSEvent) -> Bool {
        !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.control)
    }
}

// MARK: - BrowserTabSwitcherLayout

/// Fixed cards side by side in a panel sized to them, scrolling when the
/// window is too narrow: 180 x 156 pt cards, a 158 x 104 pt picture each.
struct BrowserTabSwitcherLayout {
    static let cardWidth: CGFloat = 180
    static let cardHeight: CGFloat = 156
    static let previewSize = CGSize(width: 158, height: 104)

    let containerSize: CGSize
    let entryCount: Int
    let panelPadding: CGFloat = 16
    let cardSpacing: CGFloat = 2

    var cardWidth: CGFloat { Self.cardWidth }
    var cardHeight: CGFloat { Self.cardHeight }
    var contentWidth: CGFloat { max(CGFloat(entryCount) * (cardWidth + cardSpacing) - cardSpacing, 0) }
    var panelWidth: CGFloat { min(contentWidth + panelPadding * 2, max(containerSize.width - 32, 0)) }
    var panelHeight: CGFloat { cardHeight + panelPadding * 2 }
}

// MARK: - BrowserTabSwitcherNSView

final class BrowserTabSwitcherNSView: NSView {
    // MARK: Internal

    override var isFlipped: Bool { true }

    private(set) var selectedTabID: String?
    private(set) var cards = [BrowserTabSwitcherCardNSView]()
    /// The chosen card's fill, from the Space's color; the plain selection without one.
    var selectionTint: NSColor?

    // MARK: Private

    private let panel = NSVisualEffectView()
    private let tint = BrowserNativeSurface()
    private let scrollView = NSScrollView()
    private let cardsContainer = BrowserNativeSurface()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("browser.tab-switcher")
        panel.material = .hudWindow
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 18
        panel.layer?.masksToBounds = true
        addSubview(panel)
        tint.cornerRadius = 18
        tint.fillColor = BrowserChromeColors.commandBarPanelTint
        tint.strokeColor = BrowserChromeColors.commandBarPanelBorder
        panel.addSubview(tint)
        panel.addSubview(scrollView)
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.documentView = cardsContainer
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let layout = BrowserTabSwitcherLayout(containerSize: bounds.size, entryCount: cards.count)
        panel.frame = NSRect(
            x: (bounds.width - layout.panelWidth) / 2,
            y: (bounds.height - layout.panelHeight) / 2,
            width: layout.panelWidth,
            height: layout.panelHeight,
        )
        tint.frame = panel.bounds
        scrollView.frame = panel.bounds.insetClamped(dx: layout.panelPadding, dy: layout.panelPadding)
        let documentWidth = max(CGFloat(cards.count) * (layout.cardWidth + layout.cardSpacing) - layout.cardSpacing, 0)
        cardsContainer.frame = NSRect(x: 0, y: 0, width: documentWidth, height: layout.cardHeight)
        for (index, card) in cards.enumerated() {
            card.frame = NSRect(
                x: CGFloat(index) * (layout.cardWidth + layout.cardSpacing),
                y: 0,
                width: layout.cardWidth,
                height: layout.cardHeight,
            )
        }
        if let card = cards.first(where: { $0.tabID == selectedTabID }) {
            cardsContainer.scrollToVisible(card.frame)
        }
    }

    func update(state: BrowserChromeModel.TabSwitcherState) {
        selectedTabID = state.selectedTabID
        panel.isHidden = state.entries.isEmpty
        let existing = Dictionary(uniqueKeysWithValues: cards.map { ($0.tabID, $0) })
        let nextCards = state.entries.map { entry in
            let card = existing[entry.id] ?? BrowserTabSwitcherCardNSView(entry: entry)
            card.update(entry: entry, selected: entry.id == state.selectedTabID, tint: selectionTint)
            return card
        }
        for card in cards where !nextCards.contains(where: { $0 === card }) {
            card.removeFromSuperview()
        }
        for card in nextCards where card.superview == nil {
            cardsContainer.addSubview(card)
        }
        cards = nextCards
        needsLayout = true
    }
}

// MARK: - BrowserTabSwitcherCardNSView

final class BrowserTabSwitcherCardNSView: BrowserNativeSurface {
    // MARK: Internal

    let tabID: String
    private(set) var isSelected = false

    private let title = NSTextField(labelWithString: "")
    private let favicon = BrowserFaviconNSView()
    private let preview = BrowserTabPreviewNSView()
    /// A Split View's panes, side by side, each with its icon under it.
    private var panePreviews = [BrowserTabPreviewNSView]()
    private var paneFavicons = [BrowserFaviconNSView]()

    init(entry: BrowserChromeModel.TabSwitcherEntry) {
        self.tabID = entry.id
        super.init(frame: .zero)
        cornerRadius = 8
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = BrowserChromeColors.primaryText
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        addSubview(title)
        addSubview(favicon)
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 7
        preview.layer?.masksToBounds = true
        addSubview(preview)
        update(entry: entry, selected: false)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let size = BrowserTabSwitcherLayout.previewSize
        preview.frame = NSRect(x: (bounds.width - size.width) / 2, y: 12, width: size.width, height: size.height)
        let rowY = preview.frame.maxY + (bounds.height - preview.frame.maxY - 16) / 2
        if !panePreviews.isEmpty {
            let gap: CGFloat = 4
            let count = CGFloat(panePreviews.count)
            let width = (size.width - gap * (count - 1)) / count
            for (index, (pane, icon)) in zip(panePreviews, paneFavicons).enumerated() {
                let x = preview.frame.minX + CGFloat(index) * (width + gap)
                pane.frame = NSRect(x: x, y: preview.frame.minY, width: width, height: size.height)
                icon.frame = NSRect(x: x + (width - 14) / 2, y: rowY + 1, width: 14, height: 14)
            }
        }
        favicon.frame = NSRect(x: preview.frame.minX, y: rowY + 1, width: 14, height: 14)
        title.frame = NSRect(
            x: favicon.frame.maxX + 6,
            y: rowY,
            width: max(preview.frame.maxX - favicon.frame.maxX - 6, 0),
            height: 16,
        )
    }

    func update(entry: BrowserChromeModel.TabSwitcherEntry, selected: Bool, tint: NSColor? = nil) {
        isSelected = selected
        title.stringValue = entry.tab.displayTitle
        favicon.update(url: entry.tab.faviconURL, pageURLString: entry.tab.urlString)
        updatePanes(entry.splitPanes)
        preview.image = entry.previewImage
        preview.title = entry.tab.displayTitle
        let fill = selected ? tint ?? BrowserChromeColors.rowSelected : .clear
        let stroke = selected && tint == nil ? BrowserChromeColors.primaryText.withAlphaComponent(0.38) : .clear
        fillColor = fill
        strokeColor = stroke
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(entry.tab.displayTitle)
        setAccessibilityValue(selected ? "selected" : "")
        setAccessibilityIdentifier("browser.tab-switcher.card.\(tabID)")
    }

    private func updatePanes(_ panes: [(tab: BrowserChromeModel.Tab, previewImage: NSImage?)]) {
        if panePreviews.count != panes.count {
            panePreviews.forEach { $0.removeFromSuperview() }
            paneFavicons.forEach { $0.removeFromSuperview() }
            panePreviews = panes.map { _ in
                let view = BrowserTabPreviewNSView()
                view.wantsLayer = true
                view.layer?.cornerRadius = 7
                view.layer?.masksToBounds = true
                addSubview(view)
                return view
            }
            paneFavicons = panes.map { _ in
                let view = BrowserFaviconNSView()
                addSubview(view)
                return view
            }
            needsLayout = true
        }
        for ((pane, icon), item) in zip(zip(panePreviews, paneFavicons), panes) {
            pane.image = item.previewImage
            pane.title = item.tab.displayTitle
            icon.update(url: item.tab.faviconURL, pageURLString: item.tab.urlString)
        }
        let isSplit = !panes.isEmpty
        preview.isHidden = isSplit
        title.isHidden = isSplit
        favicon.isHidden = isSplit
    }
}

// MARK: - BrowserTabPreviewNSView

private final class BrowserTabPreviewNSView: NSView {
    // MARK: Internal

    override var isFlipped: Bool { true }

    var image: NSImage? {
        didSet {
            wantsLayer = true
            previewLayer.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            previewLayer.contentsGravity = .resizeAspectFill
            previewLayer.masksToBounds = true
            if previewLayer.superlayer == nil {
                layer?.addSublayer(previewLayer)
            }
            needsLayout = true
            needsDisplay = true
        }
    }

    var title = "" { didSet { needsDisplay = true } }

    // MARK: Private

    private let previewLayer = CALayer()

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
        previewLayer.isHidden = image == nil
    }

    override func draw(_: NSRect) {
        BrowserChromeColors.contentBackground.setFill()
        bounds.fill()
        if image == nil {
            BrowserChromeColors.commandBarFieldTint.setFill()
            NSBezierPath(roundedRect: NSRect(x: 12, y: 12, width: 58, height: 8), xRadius: 4, yRadius: 4).fill()
            BrowserChromeColors.rowHover.setFill()
            for (index, width) in [122.0, 96, 142, 76].enumerated() {
                NSBezierPath(
                    roundedRect: NSRect(x: 12, y: 28 + CGFloat(index) * 16, width: width, height: 8),
                    xRadius: 4,
                    yRadius: 4,
                ).fill()
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            (title as NSString).draw(
                in: NSRect(x: 12, y: bounds.height - 24, width: max(bounds.width - 24, 0), height: 14),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: BrowserChromeColors.secondaryText,
                    .paragraphStyle: paragraph,
                ],
            )
        }
        BrowserChromeColors.commandBarPanelBorder.setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: 7, yRadius: 7)
        border.lineWidth = 0.5
        border.stroke()
    }
}
