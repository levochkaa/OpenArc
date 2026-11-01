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

struct BrowserTabSwitcherLayout {
    let containerSize: CGSize
    let entryCount: Int
    let panelPadding: CGFloat = 12
    let cardSpacing: CGFloat = 10

    var panelWidth: CGFloat { min(max(containerSize.width * 2 / 3, 280), max(containerSize.width - 32, 0)) }
    var cardWidth: CGFloat {
        guard entryCount > 0 else { return 0 }
        return max(
            floor((panelWidth - panelPadding * 2 - cardSpacing * CGFloat(entryCount - 1)) / CGFloat(entryCount)),
            92,
        )
    }

    var cardHeight: CGFloat { ceil(max(cardWidth - 12, 0) * 0.62 + 12 + 8 + 32) }
    var panelHeight: CGFloat { cardHeight + panelPadding * 2 }
}

// MARK: - BrowserTabSwitcherNSView

final class BrowserTabSwitcherNSView: NSView {
    // MARK: Internal

    override var isFlipped: Bool { true }

    private(set) var selectedTabID: String?
    private(set) var cards = [BrowserTabSwitcherCardNSView]()

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
            y: bounds.height * 0.45 - layout.panelHeight / 2,
            width: layout.panelWidth,
            height: layout.panelHeight,
        )
        tint.frame = panel.bounds
        scrollView.frame = panel.bounds.insetBy(dx: layout.panelPadding, dy: layout.panelPadding)
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
            card.update(entry: entry, selected: entry.id == state.selectedTabID)
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
    private let url = NSTextField(labelWithString: "")
    private let preview = BrowserTabPreviewNSView()

    init(entry: BrowserChromeModel.TabSwitcherEntry) {
        self.tabID = entry.id
        super.init(frame: .zero)
        cornerRadius = 8
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = BrowserChromeColors.primaryText
        url.font = .systemFont(ofSize: 11)
        url.textColor = BrowserChromeColors.secondaryText
        for label in [title, url] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            addSubview(label)
        }
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 7
        preview.layer?.masksToBounds = true
        addSubview(preview)
        update(entry: entry, selected: false)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let width = max(bounds.width - 12, 0)
        preview.frame = NSRect(x: 6, y: 6, width: width, height: width * 0.62)
        title.frame = NSRect(x: 6, y: preview.frame.maxY + 8, width: width, height: 16)
        url.frame = NSRect(x: 6, y: title.frame.maxY + 2, width: width, height: 14)
    }

    func update(entry: BrowserChromeModel.TabSwitcherEntry, selected: Bool) {
        isSelected = selected
        title.stringValue = entry.tab.displayTitle
        url.stringValue = BrowserURLDisplayFormatter.displayString(for: entry.tab.urlString)
        preview.image = entry.previewImage
        preview.title = entry.tab.displayTitle
        let fill = selected ? BrowserChromeColors.rowSelected : BrowserChromeColors.commandBarFieldTint
        let stroke = selected ? BrowserChromeColors.primaryText.withAlphaComponent(0.38) : .clear
        fillColor = fill
        strokeColor = stroke
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(entry.tab.displayTitle)
        setAccessibilityValue(selected ? "selected" : "")
        setAccessibilityIdentifier("browser.tab-switcher.card.\(tabID)")
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
