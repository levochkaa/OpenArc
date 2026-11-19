// BrowserCommandSuggestionNSView.swift

import AppKit

final class BrowserCommandSuggestionNSView: NSButton {
    // MARK: Internal

    /// The fill of shortcut badges and key caps in the command bar.
    static let badgeFill = NSColor(name: nil) { appearance in
        var resolved = NSColor.clear
        appearance.performAsCurrentDrawingAppearance {
            let color = BrowserChromeColors.commandBarPanelBorder.usingColorSpace(.sRGB) ?? .clear
            resolved = color.withAlphaComponent(color.alphaComponent * 0.55)
        }
        return resolved
    }

    override var isFlipped: Bool { true }

    var onPress: () -> Void = {}

    // MARK: Private

    private let tile = BrowserNativeSurface()
    private let switchLabel = NSTextField(labelWithString: "")
    private let switchTile = BrowserNativeSurface()
    private let switchArrow = NSImageView()
    private let icon = NSImageView()
    private let primary = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let badge = BrowserNativeSurface()
    private let badgeLabel = NSTextField(labelWithString: "")
    private var hovered = false
    private var isSelectedSuggestion = false
    private var selectionColor: NSColor?
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        action = #selector(pressed)
        tile.strokeWidth = 0
        tile.cornerRadius = 6
        addSubview(tile, positioned: .below, relativeTo: nil)
        primary.font = .systemFont(ofSize: 13, weight: .medium)
        primary.textColor = BrowserChromeColors.primaryText
        detail.font = .systemFont(ofSize: 12, weight: .medium)
        detail.textColor = BrowserChromeColors.secondaryText
        // A long address keeps its start and end.
        detail.lineBreakMode = .byTruncatingMiddle
        badgeLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        badgeLabel.textColor = BrowserChromeColors.secondaryText
        badge.cornerRadius = 5
        badge.fillColor = Self.badgeFill
        badge.addSubview(badgeLabel)
        icon.imageScaling = .scaleProportionallyUpOrDown
        switchLabel.font = .systemFont(ofSize: 13, weight: .medium)
        switchLabel.stringValue = BrowserStrings.commandBarSwitchToTab
        switchTile.strokeWidth = 0
        switchTile.cornerRadius = 6
        switchTile.addSubview(switchArrow)
        switchArrow.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        for view in [icon, primary, detail, badge, switchLabel, switchTile] {
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        for label in [primary, detail, badgeLabel] {
            label.lineBreakMode = .byTruncatingTail
        }
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
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

    override func mouseEntered(with _: NSEvent) { hovered = true
        needsDisplay = true
    }

    override func mouseExited(with _: NSEvent) { hovered = false
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_: NSRect) {
        if isSelectedSuggestion, let selectionColor {
            selectionColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        } else if isSelectedSuggestion || hovered {
            BrowserChromeColors.commandBarSuggestionSelected.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
    }

    override func layout() {
        super.layout()
        let padding = BrowserChromeLayout.commandBarRowHorizontalPadding
        let spacing = BrowserChromeLayout.commandBarRowContentSpacing
        tile.frame = NSRect(x: 10, y: (bounds.height - 24) / 2, width: 24, height: 24)
        icon.frame = NSRect(
            x: padding,
            y: (bounds.height - 14) / 2,
            width: BrowserChromeLayout.commandBarSymbolWidth,
            height: 14,
        )
        let badgeWidth = badge.isHidden ? 0 : textWidth(badgeLabel) + 14
        badge.frame = NSRect(
            x: bounds.width - padding - badgeWidth,
            y: (bounds.height - 22) / 2,
            width: badgeWidth,
            height: 22,
        )
        badgeLabel.frame = NSRect(x: 7, y: 4, width: max(badgeWidth - 14, 0), height: 14)
        switchTile.frame = NSRect(x: bounds.width - 12 - 24, y: (bounds.height - 24) / 2, width: 24, height: 24)
        switchArrow.frame = switchTile.bounds.insetClamped(dx: 4, dy: 4)
        let switchWidth = switchLabel.isHidden ? 0 : textWidth(switchLabel) + 2
        switchLabel.frame = NSRect(
            x: switchTile.frame.minX - 9 - switchWidth,
            y: (bounds.height - 18) / 2,
            width: switchWidth,
            height: 18,
        )
        let trailingWidth = switchLabel.isHidden ? badgeWidth : switchWidth + 9 + 24
        let x: CGFloat = 41
        let available = max(bounds.width - padding - x - (trailingWidth > 0 ? trailingWidth + spacing : 0), 0)
        let hasDetail = !detail.stringValue.isEmpty
        let titleWidth = min(textWidth(primary), hasDetail ? available * 0.72 : available)
        primary.frame = NSRect(x: x, y: (bounds.height - 20) / 2 + 0.5, width: titleWidth, height: 20)
        detail.frame = NSRect(
            x: primary.frame.maxX,
            y: (bounds.height - 16) / 2,
            width: max(available - titleWidth, 0),
            height: 16,
        )
        detail.isHidden = !hasDetail
    }

    /// `selectionColor` fills the selected row, white on it, for a site search.
    func update(
        suggestion: BrowserCommandSuggestion,
        selected: Bool,
        favicon: NSImage?,
        selectionColor: NSColor? = nil,
    ) {
        isSelectedSuggestion = selected
        self.selectionColor = selectionColor
        let tinted = selected && selectionColor != nil
        let isCommand = suggestion.kind == .command
        let isPage = [.openTab, .history, .bookmark].contains(suggestion.kind)
        // An Ask row shows the text it sends, and the provider at its end.
        let isAsk = suggestion.kind == .aiSearch
        let pageIcon = favicon ?? suggestion.iconData.flatMap(NSImage.init(data:))
        // Commands sit on a tile; the selected page's icon too, on a white one.
        let tiled = isCommand || selected && isPage && pageIcon != nil
        tile.isHidden = !tiled
        tile.fillColor = selected ? .white : BrowserCommandSuggestionNSView.badgeFill
        badge.fillColor = tinted ? .white : BrowserCommandSuggestionNSView.badgeFill
        badgeLabel.textColor = tinted ? selectionColor : BrowserChromeColors.secondaryText
        primary.textColor = tinted
            ? .white
            : selected ? BrowserChromeColors.commandBarRowSelectedText : BrowserChromeColors.commandBarRowText
        detail.textColor = tinted ? NSColor.white.withAlphaComponent(0.75) : BrowserChromeColors.commandBarRowDetail
        title = suggestion.displayText
        primary.stringValue = isAsk ? suggestion.detailText ?? "" : suggestion.displayText
        // "Title — address", the address after a dash.
        detail.stringValue = isAsk ? "" : suggestion.detailText.map { "— " + $0 } ?? ""
        badgeLabel.stringValue = suggestion.shortcut?.displayText ?? ""
        badge.isHidden = suggestion.shortcut == nil
        let isTab = suggestion.kind == .openTab
        switchLabel.stringValue = isAsk
            ? suggestion.displayText
            : suggestion.spaceTitle ?? BrowserStrings.commandBarSwitchToTab
        switchLabel.isHidden = !isTab && !isAsk
        switchTile.isHidden = !isTab && !isAsk
        switchLabel.textColor = tinted ? .white : BrowserChromeColors.secondaryText
        switchTile.fillColor = tinted ? .white : BrowserCommandSuggestionNSView.badgeFill
        switchArrow.contentTintColor = tinted ? selectionColor : BrowserChromeColors.primaryText
        if let image = pageIcon {
            icon.image = image
            icon.contentTintColor = nil
        } else if isAsk, let logo = suggestion.aiSearchProvider?.commandBarLogo {
            icon.image = logo
            icon.contentTintColor = tinted
                ? .white
                : selected ? BrowserChromeColors.commandBarRowSelectedText : BrowserChromeColors.commandBarRowIcon
        } else {
            icon.image = NSImage(systemSymbolName: suggestion.systemImageName, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: BrowserChromeLayout.commandBarSymbolSize, weight: .regular))
            icon.contentTintColor =
                if tinted {
                    isCommand ? selectionColor : .white
                } else if selected {
                    // Dark on the white tile, full strength beside it.
                    isCommand ? .black : BrowserChromeColors.commandBarRowSelectedText
                } else {
                    BrowserChromeColors.commandBarRowIcon
                }
        }
        setAccessibilityLabel(suggestion.displayText)
        setAccessibilityHelp(suggestion.detailText)
        setAccessibilityIdentifier("browser.command.suggestion.\(suggestion.id)")
        needsLayout = true
        needsDisplay = true
    }

    private func textWidth(_ label: NSTextField) -> CGFloat {
        ceil((label.stringValue as NSString)
            .size(withAttributes: [.font: label.font ?? NSFont.systemFont(ofSize: 13)])
            .width) + 4
    }

    @objc private func pressed() { onPress() }
}
