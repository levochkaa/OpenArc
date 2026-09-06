import AppKit
import Combine

// MARK: - BrowserCommandBarNSView

final class BrowserCommandBarNSView: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    // MARK: Lifecycle

    init(model: BrowserCommandBarModel, faviconCache: BrowserFaviconCache = .shared) {
        self.model = model
        self.faviconCache = faviconCache
        super.init(frame: .zero)
        addSubview(panel)
        panel.contentView.addSubview(symbol)
        panel.contentView.addSubview(queryField)
        panel.contentView.addSubview(divider)
        panel.contentView.addSubview(scrollView)
        symbol.imageScaling = .scaleProportionallyUpOrDown
        symbol.setAccessibilityElement(false)
        queryField.delegate = self
        queryField.focusPermission = { [weak model] in model?.isPresented == true }
        queryField.placeholderString = BrowserStrings.commandBarPlaceholder
        queryField.setAccessibilityLabel(BrowserStrings.commandBarPlaceholder)
        queryField.setAccessibilityIdentifier("browser.command.query")
        divider.fillColor = BrowserChromeColors.commandBarPanelBorder
        divider.strokeWidth = 0
        scrollView.drawsBackground = false
        scrollView.setAccessibilityIdentifier("browser.command.suggestion-scroll")
        table.setAccessibilityIdentifier("browser.command.suggestions")
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: BrowserChromeLayout.commandBarSuggestionVerticalInset,
            left: 0,
            bottom: BrowserChromeLayout.commandBarSuggestionVerticalInset,
            right: 0
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
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &observations)
        faviconCache.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refreshIcons() }
            .store(in: &observations)
        refresh()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Internal

    override var isFlipped: Bool { true }

    let queryField = BrowserCommandNSTextField()
    private(set) var displayedSuggestions = [BrowserCommandSuggestion]()

    var panelFrame: CGRect { panel.frame }

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
        return convert(point, from: superview).x >= blockedLeadingInset ? self : nil
    }

    override func mouseDown(with _: NSEvent) { model.dismiss() }

    override func layout() {
        super.layout()
        let geometry = BrowserCommandBarLayout(
            availableSize: bounds.size,
            style: style,
            displayText: model.previewDisplayText ?? model.query,
            suggestionCount: displayedSuggestions.count
        )
        panel.frame = geometry.panelFrame
        let outer = BrowserChromeLayout.commandBarOuterPadding
        let fieldHeight = geometry.inputHeight
        let horizontal = BrowserChromeLayout.commandBarRowHorizontalPadding + outer * 2
        symbol.frame = NSRect(
            x: horizontal,
            y: outer + (fieldHeight - style.symbolSize) / 2,
            width: BrowserChromeLayout.commandBarSymbolWidth,
            height: style.symbolSize
        )
        let queryX = symbol.frame.maxX + BrowserChromeLayout.commandBarRowContentSpacing
        queryField.frame = NSRect(
            x: queryX,
            y: outer + (fieldHeight - 28) / 2 + style.textFieldVerticalOffset,
            width: max(geometry.panelWidth - queryX - horizontal, 0),
            height: 28
        )
        divider.frame = NSRect(
            x: outer * 2,
            y: outer + fieldHeight,
            width: max(geometry.panelWidth - outer * 4, 0),
            height: 1
        )
        scrollView.frame = NSRect(
            x: outer * 2,
            y: divider.frame.maxY,
            width: max(geometry.panelWidth - outer * 4, 0),
            height: geometry.suggestionViewportHeight
        )
        table.tableColumns.first?.width = scrollView.contentSize.width
        table.setFrameSize(NSSize(width: scrollView.contentSize.width, height: table.frame.height))
        scrollSelectionIntoViewIfNeeded()
    }

    func configure(
        blockedLeadingInset: CGFloat,
        style: BrowserCommandBarOverlayStyle,
        faviconCandidate: BrowserCommandBarFaviconCandidate?
    ) {
        let inputStyleChanged = self.style.fontSize != style.fontSize || self.style.selectsTextOnFocus != style
            .selectsTextOnFocus
        self.blockedLeadingInset = blockedLeadingInset
        self.style = style
        self.faviconCandidate = faviconCandidate
        queryField.setAccessibilityIdentifier(style.selectsTextOnFocus
            ? "browser.command.current-page-query"
            : "browser.command.query")
        if inputStyleChanged {
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
        if model.query != queryField.stringValue {
            model.query = queryField.stringValue
        }
        queryField.clearFocusSelectionRequest()
    }

    func control(_: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
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
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            model.submitSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)): model.dismiss()
            return true
        default: return false
        }
    }

    // MARK: Private

    private let model: BrowserCommandBarModel
    private let faviconCache: BrowserFaviconCache
    private var observations = Set<AnyCancellable>()
    private let panel = BrowserNativeMaterialPanel()
    private let symbol = NSImageView()
    private let divider = BrowserNativeSurface()
    private let scrollView = NSScrollView()
    private let table = BrowserCommandSuggestionTableView()
    private var style = BrowserCommandBarOverlayStyle.standard
    private var blockedLeadingInset: CGFloat = 0
    private var faviconCandidate: BrowserCommandBarFaviconCandidate?
    private var scrolledSelectionID: String?

    private func refresh() {
        let changed = displayedSuggestions != model.suggestions
        displayedSuggestions = model.suggestions
        panel.isHidden = !model.isPresented
        panel.cornerRadius = style.cornerRadius
        divider.isHidden = displayedSuggestions.isEmpty
        scrollView.isHidden = displayedSuggestions.isEmpty
        queryField.syncCommandPresentation(
            text: model.query,
            previewDisplayText: model.previewDisplayText,
            inlineCompletionSuffix: model.inlineCompletionSuffix,
            shouldFocus: model.isPresented,
            focusRequestID: model.focusRequestID,
            fontSize: style.fontSize,
            selectAllOnFocus: style.selectsTextOnFocus
        )
        if changed {
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
        } else {
            symbol.image = NSImage(
                systemSymbolName: model.selectedSuggestion?.systemImageName ?? "magnifyingglass",
                accessibilityDescription: nil
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
                    at: row
                )
            }
        }
    }

    private func configureRow(_ view: BrowserCommandSuggestionNSView, at index: Int) {
        let suggestion = displayedSuggestions[index]
        view.update(
            suggestion: suggestion,
            selected: model.selectedSuggestionID == suggestion.id,
            favicon: faviconCache.image(for: faviconCandidate?.faviconURL(for: suggestion))
        )
        view.onPress = { [weak model] in model?.submitSuggestion(id: suggestion.id) }
    }

    private func scrollSelectionIntoViewIfNeeded() {
        guard let id = model.selectedSuggestionID, id != scrolledSelectionID,
              let row = displayedSuggestions.firstIndex(where: { $0.id == id }) else { return }
        let rect = table.rect(ofRow: row)
        let height = scrollView.contentView.bounds.height
        let y = max(rect.midY - height / 2, -BrowserChromeLayout.commandBarSuggestionVerticalInset)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrolledSelectionID = id
    }
}

// MARK: - BrowserCommandSuggestionTableView

/// Arrow keys and typing stay with the command field, including after clicking row spacing.
private final class BrowserCommandSuggestionTableView: NSTableView {
    override var acceptsFirstResponder: Bool { false }
}
