// BrowserCommandBarNSView.swift

import AppKit
import Combine

// MARK: - BrowserCommandBarNSView

final class BrowserCommandBarNSView: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static let closeButtonTrailing: CGFloat = 22

    // MARK: Internal

    override var isFlipped: Bool { true }

    let queryField = BrowserCommandNSTextField()
    private(set) var displayedSuggestions = [BrowserCommandSuggestion]()

    /// The selected row's fill, from the Space's theme.
    var themeSelectionColor: NSColor?

    /// Selects the text the bar opens with, in place of the style's choice.
    var selectsTextOnFocus: Bool?

    /// The widest the bar gets, below the usual width, as over a small window.
    var panelWidthLimit: CGFloat? {
        didSet { needsLayout = true }
    }

    // MARK: Private

    private let model: BrowserCommandBarModel
    private let faviconCache: BrowserFaviconCache
    /// Model changes refresh the bar, and new favicons its icons, once per run loop pass.
    private lazy var coalescedRefresh = BrowserCoalescedRefresh { [weak self] in self?.refresh() }
    private lazy var coalescedIconRefresh = BrowserCoalescedRefresh { [weak self] in self?.refreshIcons() }

    private let panel = BrowserNativeMaterialPanel()
    private let symbol = NSImageView()
    private let siteChip = BrowserNativeSurface()
    /// The site whose chip already flashed, so a refresh doesn't flash it again.
    private var flashedSiteSearchID: BrowserSiteSearch.ID?
    private let siteChipLabel = NSTextField(labelWithString: "")
    private let siteHint = NSTextField(labelWithString: "")
    private let siteHintKey = BrowserNativeSurface()
    private let siteHintKeyLabel = NSTextField(labelWithString: "Tab")
    private let divider = BrowserNativeSurface()
    private let closeButton = BrowserNativeChromeButton(
        symbol: "xmark",
        title: BrowserStrings.commandBarClose,
        style: .commandBarClose,
        pressEffect: .compress,
        action: {},
    )
    private let scrollView = NSScrollView()
    private let table = BrowserCommandSuggestionTableView()
    private var style = BrowserCommandBarOverlayStyle.standard
    private var blockedLeadingInset: CGFloat = 0
    private var blockedTrailingInset: CGFloat = 0
    private var faviconCandidate: BrowserCommandBarFaviconCandidate?
    private var scrolledSelectionID: String?
    private let scrollAnimation = BrowserNativeAnimation()

    var panelFrame: CGRect { panel.frame }

    /// Close beside the field, for a bar with no window around it to click away to.
    var showsCloseButton: Bool {
        get { !closeButton.isHidden }
        set {
            closeButton.isHidden = !newValue
            needsLayout = true
        }
    }

    init(model: BrowserCommandBarModel, faviconCache: BrowserFaviconCache = .shared) {
        self.model = model
        self.faviconCache = faviconCache
        super.init(frame: .zero)
        addSubview(panel)
        panel.contentView.addSubview(symbol)
        panel.contentView.addSubview(queryField)
        panel.contentView.addSubview(siteChip)
        panel.contentView.addSubview(siteHint)
        panel.contentView.addSubview(siteHintKey)
        panel.contentView.addSubview(divider)
        panel.contentView.addSubview(closeButton)
        closeButton.isHidden = true
        closeButton.onAction = { [weak self] in self?.model.dismiss() }
        closeButton.setAccessibilityIdentifier("browser.command.close")
        panel.contentView.addSubview(scrollView)
        symbol.imageScaling = .scaleProportionallyUpOrDown
        symbol.setAccessibilityElement(false)
        queryField.delegate = self
        queryField.focusPermission = { [weak model] in model?.isPresented == true }
        queryField.placeholderString = BrowserStrings.commandBarPlaceholder
        queryField.setAccessibilityLabel(BrowserStrings.commandBarPlaceholder)
        queryField.setAccessibilityIdentifier("browser.command.query")
        siteChipLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        siteChipLabel.textColor = .white
        siteChipLabel.alignment = .center
        siteChip.addSubview(siteChipLabel)
        siteChip.setAccessibilityElement(true)
        siteChip.setAccessibilityRole(.staticText)
        siteChip.setAccessibilityIdentifier("browser.command.site-search")
        siteHint.font = .systemFont(ofSize: 13, weight: .medium)
        siteHint.textColor = BrowserChromeColors.secondaryText
        siteHint.alignment = .right
        siteHint.lineBreakMode = .byTruncatingTail
        siteHint.setAccessibilityIdentifier("browser.command.site-search-hint")
        siteHintKeyLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        siteHintKeyLabel.textColor = BrowserChromeColors.secondaryText
        siteHintKeyLabel.alignment = .center
        siteHintKey.cornerRadius = 5
        siteHintKey.fillColor = BrowserCommandSuggestionNSView.badgeFill
        siteHintKey.addSubview(siteHintKeyLabel)
        siteHintKey.setAccessibilityElement(false)
        divider.fillColor = BrowserChromeColors.commandBarPanelBorder
        divider.strokeWidth = 0
        scrollView.drawsBackground = false
        scrollView.setAccessibilityIdentifier("browser.command.suggestion-scroll")
        table.setAccessibilityIdentifier("browser.command.suggestions")
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: BrowserChromeLayout.commandBarSuggestionScrollInset,
            left: 0,
            bottom: BrowserChromeLayout.commandBarSuggestionScrollInset,
            right: 0,
        )
        table.addTableColumn(NSTableColumn(identifier: .init("suggestions")))
        table.headerView = nil
        table.style = .plain
        table.usesAutomaticRowHeights = false
        table.backgroundColor = .clear
        table.rowHeight = BrowserChromeLayout.commandBarSuggestionRowHeight
        table.intercellSpacing = NSSize(width: 0, height: BrowserChromeLayout.commandBarSuggestionSpacing)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.focusRingType = .none
        scrollView.documentView = table
        coalescedRefresh.observe([model.objectWillChange.eraseToAnyPublisher()])
        coalescedIconRefresh.observe([faviconCache.objectWillChange.eraseToAnyPublisher()])
        refresh()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            queryField.pendingFocus = false
        } else {
            refresh()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard model.isPresented else { return nil }
        let hit = super.hitTest(point)
        if hit !== self {
            return hit
        }
        let x = convert(point, from: superview).x
        return x >= blockedLeadingInset && x <= bounds.width - blockedTrailingInset ? self : nil
    }

    override func mouseDown(with _: NSEvent) { model.dismiss() }

    override func layout() {
        super.layout()
        let geometry = BrowserCommandBarLayout(
            availableSize: bounds.size,
            style: style,
            displayText: model.previewDisplayText ?? model.query,
            suggestionCount: displayedSuggestions.count,
            extraWidth: siteSearchWidth(),
            widthLimit: panelWidthLimit,
        )
        panel.frame = geometry.panelFrame
        let outer = BrowserChromeLayout.commandBarOuterPadding
        let fieldHeight = geometry.inputHeight
        let horizontal = BrowserChromeLayout.commandBarFieldLeading
        symbol.frame = NSRect(
            x: horizontal,
            y: outer + (fieldHeight - style.symbolSize) / 2,
            width: BrowserChromeLayout.commandBarSymbolWidth,
            height: style.symbolSize,
        )
        let spacing = BrowserChromeLayout.commandBarRowContentSpacing
        var queryX = symbol.frame.maxX + spacing - 1.5
        if !siteChip.isHidden {
            let height = style.fontSize > 16 ? 24.0 : 20.0
            let width = ceil(siteChipLabel.attributedStringValue.size().width) + 20
            siteChip.frame = NSRect(x: queryX, y: outer + (fieldHeight - height) / 2, width: width, height: height)
            siteChip.cornerRadius = height / 2
            siteChipLabel.frame = NSRect(x: 0, y: (height - 17) / 2, width: width, height: 17)
            queryX = siteChip.frame.maxX + 6
        }
        var queryMaxX = geometry.panelWidth - horizontal
        if !siteHint.isHidden {
            let keyWidth = ceil(siteHintKeyLabel.attributedStringValue.size().width) + 12
            siteHintKey.frame = NSRect(
                x: queryMaxX - keyWidth,
                y: outer + (fieldHeight - 20) / 2,
                width: keyWidth,
                height: 20,
            )
            siteHintKeyLabel.frame = NSRect(x: 0, y: 3, width: keyWidth, height: 14)
            let hintWidth = min(ceil(siteHint.attributedStringValue.size().width) + 4, geometry.panelWidth / 3)
            siteHint.frame = NSRect(
                x: siteHintKey.frame.minX - 6 - hintWidth,
                y: outer + (fieldHeight - 17) / 2,
                width: hintWidth,
                height: 17,
            )
            queryMaxX = siteHint.frame.minX - spacing
        }
        if !closeButton.isHidden {
            let size = BrowserNativeChromeButtonStyle.commandBarClose.size
            closeButton.frame = NSRect(
                x: geometry.panelWidth - Self.closeButtonTrailing - size,
                y: outer + (fieldHeight - size) / 2,
                width: size,
                height: size,
            )
            queryMaxX = min(queryMaxX, closeButton.frame.minX - spacing)
        }
        queryField.frame = NSRect(
            x: queryX,
            y: outer + (fieldHeight - 28) / 2 + style.textFieldVerticalOffset,
            width: max(queryMaxX - queryX, 0),
            height: 28,
        )
        divider.frame = NSRect(
            x: outer * 2,
            y: outer + fieldHeight,
            width: max(geometry.panelWidth - outer * 4, 0),
            height: 1,
        )
        scrollView.frame = NSRect(
            x: outer * 2,
            y: divider.frame.maxY,
            width: max(geometry.panelWidth - outer * 4, 0),
            height: geometry.suggestionViewportHeight,
        )
        table.tableColumns.first?.width = scrollView.contentSize.width
        table.setFrameSize(NSSize(width: scrollView.contentSize.width, height: table.frame.height))
        scrollSelectionIntoViewIfNeeded()
    }

    func configure(
        blockedLeadingInset: CGFloat,
        blockedTrailingInset: CGFloat = 0,
        style: BrowserCommandBarOverlayStyle,
        faviconCandidate: BrowserCommandBarFaviconCandidate?,
    ) {
        self.blockedTrailingInset = blockedTrailingInset
        let inputStyleChanged = self.style.fontSize != style.fontSize || self.style.selectsTextOnFocus != style
            .selectsTextOnFocus
        self.blockedLeadingInset = blockedLeadingInset
        self.style = style
        self.faviconCandidate = faviconCandidate
        queryField.setAccessibilityIdentifier(style.selectsTextOnFocus
            ? "browser.command.current-page-query"
            : "browser.command.query")
        if inputStyleChanged {
            if model.isPresented {
                queryField.clearFocusSelectionRequest()
                queryField.lastFocusRequestID = -1
            }
            refresh()
        } else {
            refreshIcons()
            needsLayout = true
        }
    }

    func numberOfRows(in _: NSTableView) -> Int { displayedSuggestions.count }
    func tableView(_: NSTableView, shouldSelectRow _: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        guard displayedSuggestions.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("suggestion")
        let view = (tableView.makeView(withIdentifier: identifier, owner: self) as? BrowserCommandSuggestionNSView)
            ?? BrowserCommandSuggestionNSView()
        view.identifier = identifier
        configureRow(view, at: row)
        return view
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? BrowserCommandNSTextField === queryField,
              !queryField.isApplyingPresentation else { return }
        queryField.clearFocusSelectionRequest()
        if model.query != queryField.stringValue {
            model.query = queryField.stringValue
            // The key replaced the completed part; put the completion back
            // before the field draws, or it shows the bare text for a frame.
            refresh()
        }
    }

    func control(_: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertTab(_:)):
            // Site search, else the completed text is taken; the field keeps the focus.
            guard !textView.hasMarkedText() else { return false }
            if model.beginSiteSearch() || queryField.hasSuggestionPreview && model.acceptSelectedSuggestion() {
                // The next key may arrive before the deferred refresh.
                refresh()
            }
            return true
        case #selector(NSResponder.deleteBackward(_:)):
            guard !textView.hasMarkedText() else { return false }
            if textView.string.isEmpty, model.endSiteSearch(restoringQuery: true) {
                refresh()
                return true
            }
            // Delete over the completed part removes it and its page from the top.
            if let completion = queryField.previewSelectionRange, queryField.hasSuggestionPreview,
               textView.selectedRange() == completion, model.removeInlineCompletion()
            {
                refresh()
                return true
            }
            return false
        case #selector(NSResponder.moveUp(_:)): model.moveSelection(by: -1)
            return true
        case #selector(NSResponder.moveDown(_:)): model.moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveRight(_:)):
            guard queryField.hasSuggestionPreview else { return false }
            _ = model.acceptSelectedSuggestion()
            return true
        case #selector(NSResponder.selectAll(_:)): textView.selectAll(nil)
            return true
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            let modifiers = NSApp.currentEvent?.modifierFlags ?? []
            if modifiers.contains(.option) {
                model.submitSelectionInSplitView()
            } else if modifiers.contains(.command) {
                model.submitSelectionInBackground()
            } else {
                model.submitSelection()
            }
            return true
        // Command-Return has no key binding of its own.
        case Selector(("noop:"))
            where NSApp.currentEvent?.type == .keyDown && [36, 76].contains(NSApp.currentEvent?.keyCode)
            && NSApp.currentEvent?.modifierFlags.contains(.command) == true:
            model.submitSelectionInBackground()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if model.endSiteSearch(restoringQuery: false) {
                refresh()
            } else {
                model.dismiss()
            }
            return true
        default: return false
        }
    }

    private func refresh() {
        let changed = displayedSuggestions != model.suggestions
        displayedSuggestions = model.suggestions
        panel.isHidden = !model.isPresented
        panel.cornerRadius = style.cornerRadius
        divider.isHidden = displayedSuggestions.isEmpty
        scrollView.isHidden = displayedSuggestions.isEmpty
        refreshSiteSearch()
        queryField.syncCommandPresentation(
            text: model.query,
            previewDisplayText: model.previewDisplayText,
            inlineCompletionSuffix: model.inlineCompletionSuffix,
            shouldFocus: model.isPresented,
            focusRequestID: model.focusRequestID,
            fontSize: style.fontSize,
            selectAllOnFocus: selectsTextOnFocus ?? style.selectsTextOnFocus,
        )
        if changed {
            scrollAnimation.cancel()
            table.reloadData()
            scrolledSelectionID = nil
        }
        if let index = model.selectedSuggestionIndex, displayedSuggestions.indices.contains(index) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        refreshIcons()
        needsLayout = true
    }

    private func refreshIcons() {
        if let image = faviconCache.image(for: faviconCandidate?.faviconURL(for: model.selectedSuggestion)) {
            symbol.image = image
            symbol.contentTintColor = nil
        } else if !model.query.isEmpty, let logo = model.selectedSuggestion?.aiSearchProvider?.commandBarLogo {
            symbol.image = logo
            symbol.contentTintColor = BrowserChromeColors.primaryText
        } else {
            symbol.image = NSImage(
                systemSymbolName: model.query.isEmpty
                    ? "magnifyingglass"
                    : model.selectedSuggestion?.systemImageName ?? "magnifyingglass",
                accessibilityDescription: nil,
            )?
                .withSymbolConfiguration(.init(pointSize: style.symbolSize, weight: .semibold))
            symbol.contentTintColor = BrowserChromeColors.primaryText
        }
        for row in displayedSuggestions.indices {
            if let view = table
                .view(atColumn: 0, row: row, makeIfNecessary: false) as? BrowserCommandSuggestionNSView
            {
                configureRow(
                    view,
                    at: row,
                )
            }
        }
    }

    /// The chip of the searched site, or the offer to search one with Tab.
    private func refreshSiteSearch() {
        let site = model.activeSiteSearch
        if let site, flashedSiteSearchID != site.id {
            panel.flash(color: site.chipColor)
        }
        flashedSiteSearchID = site?.id
        siteChip.isHidden = site == nil
        if let site {
            siteChipLabel.stringValue = site.displayName
            siteChipLabel.font = .systemFont(ofSize: style.fontSize > 16 ? 13 : 11, weight: .semibold)
            siteChip.fillColor = site.chipColor
            siteChip.setAccessibilityLabel(BrowserStrings.commandBarSiteSearchScope(site.displayName))
        }
        let placeholder = site == nil
            ? BrowserStrings.commandBarPlaceholder
            : BrowserStrings.commandBarSiteSearchPlaceholder
        if queryField.placeholderString != placeholder {
            queryField.placeholderString = placeholder
            queryField.setAccessibilityLabel(placeholder)
        }
        let candidate = model.siteSearchCandidate
        siteHint.isHidden = candidate == nil
        siteHintKey.isHidden = candidate == nil
        if let candidate {
            siteHint.stringValue = BrowserStrings.commandBarSiteSearchOffer(candidate.displayName)
        }
    }

    private func siteSearchWidth() -> CGFloat {
        if let site = model.activeSiteSearch {
            return BrowserCommandBarTextWidthMeasurer.width(for: site.displayName, fontSize: 13) + 26
        }
        if let candidate = model.siteSearchCandidate {
            let offer = BrowserStrings.commandBarSiteSearchOffer(candidate.displayName)
            return BrowserCommandBarTextWidthMeasurer.width(for: offer, fontSize: 13) + 56
        }
        return 0
    }

    private func configureRow(_ view: BrowserCommandSuggestionNSView, at index: Int) {
        let suggestion = displayedSuggestions[index]
        // A tab's icon may not be loaded yet; the cache reports it when it is.
        if let url = suggestion.faviconURL, faviconCache.image(for: url) == nil {
            Task { [faviconCache] in await faviconCache.loadImageIfNeeded(from: url) }
        }
        view.update(
            suggestion: suggestion,
            selected: model.selectedSuggestionID == suggestion.id,
            favicon: faviconCache.image(for: faviconCandidate?.faviconURL(for: suggestion) ?? suggestion.faviconURL),
            selectionColor: model.activeSiteSearch?.chipColor
                ?? suggestion.aiSearchProvider?.commandBarColor
                ?? themeSelectionColor,
        )
        view.onPress = { [weak model] in model?.submitSuggestion(id: suggestion.id) }
    }

    private func scrollSelectionIntoViewIfNeeded() {
        guard let id = model.selectedSuggestionID, id != scrolledSelectionID,
              let row = displayedSuggestions.firstIndex(where: { $0.id == id }) else { return }
        scrollAnimation.cancel()
        let rect = table.rect(ofRow: row)
        let clip = scrollView.contentView
        let visible = clip.bounds
        let inset = BrowserChromeLayout.commandBarSuggestionScrollInset
        var y = visible.minY
        if rect.minY < visible.minY + inset {
            y = rect.minY - inset
        }
        if rect.maxY > visible.maxY - inset {
            y = rect.maxY - visible.height + inset
        }
        y = min(max(y, -inset), max(table.bounds.height - visible.height + inset, -inset))
        let from = visible.minY
        let target = y
        if window == nil {
            clip.scroll(to: NSPoint(x: 0, y: target))
            scrollView.reflectScrolledClipView(clip)
        } else if abs(target - from) > 0.5 {
            scrollAnimation.start(.easeInOut(0.05)) { [weak self] progress in
                guard let self else { return }
                clip.scroll(to: NSPoint(x: 0, y: from + (target - from) * progress))
                scrollView.reflectScrolledClipView(clip)
            }
        }
        scrolledSelectionID = id
    }
}

// MARK: - BrowserCommandSuggestionTableView

/// Arrow keys and typing stay with the command field, including after clicking row spacing.
private final class BrowserCommandSuggestionTableView: NSTableView {
    override var acceptsFirstResponder: Bool { false }
}

// MARK: - BrowserSiteSearch + chip color

extension BrowserSiteSearch {
    /// The site's color in Display P3, or the accent color for a site without one.
    var chipColor: NSColor {
        guard let colorHex, colorHex.count == 6, let value = UInt32(colorHex, radix: 16) else {
            return .controlAccentColor
        }
        return NSColor(
            displayP3Red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1,
        )
    }
}
