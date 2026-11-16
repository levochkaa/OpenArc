// BrowserNativeChromeTests.swift

import AppKit
import Testing

// MARK: - BrowserNativeChromeTests

@Suite(.serialized)
@MainActor struct BrowserNativeChromeTests {
    // MARK: Internal

    /// Hiding the sidebar and closing a Peek card answer in the frame of the key; only
    /// showing the sidebar waits a moment.
    @Test func hidingTheSidebarAndClosingPeekStartAtOnce() {
        #expect(BrowserChromeLayout.sidebarHideDelay == 0)
        #expect(BrowserChromeLayout.peekCloseDelay == 0)
        #expect(BrowserChromeLayout.sidebarShowDelay > BrowserChromeLayout.sidebarHideDelay)
    }

    /// A sidebar resize stretches the drawn theme until its shape changes by 3%.
    @Test func aThemeRedrawsOnlyForAClearlyNewShape() {
        #expect(BrowserChromeBackgroundNSView.themeNeedsRender(aspect: 0.25, renderedAspect: 0))
        #expect(!BrowserChromeBackgroundNSView.themeNeedsRender(aspect: 0.2525, renderedAspect: 0.25))
        #expect(!BrowserChromeBackgroundNSView.themeNeedsRender(aspect: 0.2433, renderedAspect: 0.25))
        #expect(BrowserChromeBackgroundNSView.themeNeedsRender(aspect: 0.26, renderedAspect: 0.25))
        #expect(BrowserChromeBackgroundNSView.themeNeedsRender(aspect: 1.6, renderedAspect: 0.25))
    }

    /// Refreshes set a surface's colors on every pass; only a new value redraws it.
    @Test func settingTheSameLookDoesNotRedrawASurface() {
        let surface = RedrawCountingSurface(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        surface.fillColor = .red
        surface.cornerRadius = 6
        let marks = surface.redrawRequests
        #expect(marks > 0, "A new look asks to redraw")
        surface.fillColor = .red
        surface.cornerRadius = 6
        surface.strokeWidth = 1
        surface.roundsTopLeadingCorner = true
        #expect(surface.redrawRequests == marks)
    }

    /// The split button's right-click menu is made as it opens, not on every refresh.
    @Test func aButtonBuildsItsMenuWhenItOpens() throws {
        var builds = 0
        let button = BrowserNativeChromeButton(symbol: "rectangle.split.2x1", title: "Split") {}
        button.menuProvider = {
            builds += 1
            let menu = NSMenu()
            menu.addItem(withTitle: "Add Split View", action: nil, keyEquivalent: "")
            return menu
        }
        #expect(builds == 0)
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1,
        ))
        #expect(button.menu(for: event)?.items.map(\.title) == ["Add Split View"])
        #expect(builds == 1)
    }

    /// A menu without shortcuts is filled when it opens, not while AppKit looks for the
    /// shortcut of each Command key press.
    @Test func aMenuWithoutShortcutsFillsOnlyWhenItOpens() throws {
        var fills = 0
        let delegate = BrowserOnOpenMenuDelegate { menu in
            fills += 1
            menu.removeAllItems()
            menu.addItem(withTitle: "Extension", action: nil, keyEquivalent: "")
        }
        let menu = NSMenu(title: "Extensions")
        menu.delegate = delegate
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "k",
            charactersIgnoringModifiers: "k",
            isARepeat: false,
            keyCode: 40,
        ))
        #expect(!menu.performKeyEquivalent(with: event))
        #expect(fills == 0)
        delegate.menuNeedsUpdate(menu)
        #expect(fills == 1 && menu.items.map(\.title) == ["Extension"])
    }

    /// A hovered row refreshes its tooltip with every sidebar redraw; the same tooltip in
    /// the same place stays as it is, and a new title lays it out again.
    @Test func refreshingAShownTooltipLeavesItAlone() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 300, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
        )
        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 100, height: 30))
        window.contentView?.addSubview(anchor)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let presenter = BrowserNativeTooltipPresenter.shared
        let id = UUID()
        defer { presenter.end(id: id, detached: true) }
        presenter.begin(id: id, anchor: anchor, title: "Tab")
        try await Task.sleep(for: .milliseconds(700))
        let shown = presenter.presentationCount
        #expect(shown > 0, "Shown after the hover delay")
        presenter.begin(id: id, anchor: anchor, title: "Tab")
        presenter.begin(id: id, anchor: anchor, title: "Tab")
        #expect(presenter.presentationCount == shown)
        presenter.begin(id: id, anchor: anchor, title: "Renamed tab")
        #expect(presenter.presentationCount == shown + 1)
    }

    /// Rows ask for their icons on every refresh and get the image made the first time.
    @Test func anIconIsMadeOnceForEachSizeAndWeight() throws {
        let first = try #require(BrowserIconImage.image(named: "globe", pointSize: 16, weight: .semibold))
        #expect(BrowserIconImage.image(named: "globe", pointSize: 16, weight: .semibold) === first)
        #expect(BrowserIconImage.image(named: "globe", pointSize: 16, weight: .regular) !== first)
        #expect(BrowserIconImage.image(named: "globe", pointSize: 12, weight: .semibold) !== first)
        let emoji = try #require(BrowserIconImage.image(named: BrowserIconImage.name(emoji: "🙂"), pointSize: 16))
        #expect(BrowserIconImage.image(named: BrowserIconImage.name(emoji: "🙂"), pointSize: 16) === emoji)
        #expect(BrowserIconImage.image(named: "no.such.symbol.name", pointSize: 16) == nil)
    }

    @Test func reconfiguringTheSameSymbolKeepsItsImage() throws {
        let button = BrowserNativeChromeButton(symbol: "xmark", title: "Close") {}
        let first = try #require(button.image)
        button.configureSymbol("xmark", title: "Close")
        #expect(button.image === first)
        button.configureSymbol("xmark", title: "Archive")
        #expect(button.image !== first)
        let renamed = try #require(button.image)
        button.configureSymbol("minus", title: "Archive")
        #expect(button.image !== renamed)
    }

    @Test func findActionsAndDisabledNavigation() {
        let view = BrowserFindBarNSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        var calls = [String]()
        view.onNext = { calls.append("next") }
        view.onPrevious = { calls.append("previous") }
        view.onDismiss = { calls.append("close") }
        view.update(
            query: "browser",
            isPresented: true,
            canStep: false,
            result: .matches(active: 1, count: 3),
            focusRequestID: 1,
            blockedLeadingInset: 240,
        )
        view.nextButton.performClick(nil)
        view.previousButton.performClick(nil)
        #expect(calls.isEmpty)
        view.update(
            query: "browser",
            isPresented: true,
            canStep: true,
            result: .matches(active: 1, count: 3),
            focusRequestID: 1,
            blockedLeadingInset: 240,
        )
        view.nextButton.performClick(nil)
        view.previousButton.performClick(nil)
        view.closeButton.performClick(nil)
        #expect(calls == ["next", "previous", "close"])
    }

    @Test func findEditingAndKeyboardRouting() {
        let view = BrowserFindBarNSView()
        var queries = [String]()
        var submitted = 0
        var dismissed = 0
        view.onQueryChanged = { queries.append($0) }
        view.onNext = { submitted += 1 }
        view.onDismiss = { dismissed += 1 }
        view.update(
            query: "initial",
            isPresented: true,
            canStep: true,
            result: .none,
            focusRequestID: 1,
            blockedLeadingInset: 0,
        )
        #expect(queries.isEmpty, "A model refresh must not issue a second engine search")
        view.queryField.stringValue = "edited"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: view.queryField))
        #expect(queries == ["edited"])
        let editor = NSTextView()
        #expect(view.control(view.queryField, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(view.control(
            view.queryField,
            textView: editor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:)),
        ))
        #expect(!view.control(view.queryField, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))))
        #expect(submitted == 1)
        #expect(dismissed == 1)
    }

    @Test func findDoesNotInterceptPageOrSidebarClicks() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let view = BrowserFindBarNSView(frame: root.bounds)
        root.addSubview(view)
        view.update(
            query: "",
            isPresented: true,
            canStep: false,
            result: .none,
            focusRequestID: 1,
            blockedLeadingInset: 240,
        )
        view.layoutSubtreeIfNeeded()
        #expect(view.hitTest(NSPoint(x: 20, y: 300)) == nil)
        #expect(view.hitTest(NSPoint(x: 500, y: 200)) == nil)
        let buttonPoint = view.closeButton.convert(NSPoint(x: 14, y: 14), to: root)
        #expect(view.hitTest(buttonPoint) === view.closeButton)
        view.update(
            query: "",
            isPresented: false,
            canStep: false,
            result: .none,
            focusRequestID: 1,
            blockedLeadingInset: 240,
        )
        #expect(view.hitTest(buttonPoint) == nil)
        #expect(!view.queryField.pendingFocus)
    }

    @Test func findShowsTheMatchCountOrNotFound() {
        let view = BrowserFindBarNSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        func show(_ query: String, _ result: BrowserFindBarNSView.Result) {
            view.update(
                query: query,
                isPresented: true,
                canStep: true,
                result: result,
                focusRequestID: 1,
                blockedLeadingInset: 0,
            )
            view.layoutSubtreeIfNeeded()
        }

        show("", .none)
        #expect(view.countLabel.isHidden && view.notFoundLabel.isHidden && view.divider.isHidden)
        #expect(view.previousButton.isHidden && view.nextButton.isHidden && !view.closeButton.isHidden)

        show("domain", .matches(active: 2, count: 5))
        #expect(view.countLabel.stringValue == "2/5" && !view.countLabel.isHidden)
        #expect(!view.previousButton.isHidden && !view.nextButton.isHidden && !view.divider.isHidden)
        #expect(view.countLabel.frame.maxX < view.previousButton.frame.minX)
        #expect(view.nextButton.frame.maxX < view.divider.frame.minX)
        #expect(view.divider.frame.maxX < view.closeButton.frame.minX)
        #expect(view.queryField.frame.maxX < view.countLabel.frame.minX)

        show("domainzz", .notFound)
        #expect(view.countLabel.isHidden && !view.notFoundLabel.isHidden)
        #expect(view.previousButton.isHidden && view.nextButton.isHidden)
        #expect(view.notFoundLabel.frame.maxX < view.divider.frame.minX)
    }

    @Test func findResultFollowsTheEngineCounts() {
        #expect(BrowserFindBarNSView.result(query: "", count: 4, active: 1) == .none)
        #expect(BrowserFindBarNSView.result(query: "a", count: nil, active: nil) == .none)
        #expect(BrowserFindBarNSView.result(query: "a", count: 0, active: nil) == .notFound)
        #expect(BrowserFindBarNSView.result(query: "a", count: 4, active: 3) == .matches(active: 3, count: 4))
        #expect(BrowserFindBarNSView.result(query: "a", count: 4, active: 9) == .matches(active: nil, count: 4))
    }

    @Test func findFocusRequestsSelectAllOnlyWhenRequested() {
        let field = BrowserFindNSTextField()
        field.sync(text: "browser", shouldFocus: true, focusRequestID: 1)
        #expect(field.pendingSelectAll)
        field.pendingSelectAll = false
        field.sync(text: "browser edited", shouldFocus: true, focusRequestID: 1)
        #expect(!field.pendingSelectAll, "Typing must not keep selecting the full query")
        field.sync(text: "browser edited", shouldFocus: true, focusRequestID: 2)
        #expect(field.pendingSelectAll)
        field.sync(text: "browser edited", shouldFocus: false, focusRequestID: 2)
        #expect(!field.pendingFocus)
    }

    @Test func tabSwitcherReusesCardsAndRemovesClosedTabs() {
        let view = BrowserTabSwitcherNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.update(state: .init(entries: [entry("a"), entry("b")], selectedTabID: "a", isVisible: true))
        let first = view.cards[0]
        #expect(first.isSelected)
        view.update(state: .init(entries: [entry("b"), entry("a")], selectedTabID: "b", isVisible: true))
        #expect(view.cards[1] === first)
        #expect(!first.isSelected)
        #expect(view.cards[0].isSelected)
        view.update(state: .init(entries: [entry("b")], selectedTabID: "b", isVisible: true))
        #expect(first.superview == nil)
        #expect(view.cards.count == 1)
        #expect(view.hitTest(.zero) == nil)
    }

    @Test func tabSwitcherKeepsSelectedCardVisibleInNarrowWindows() throws {
        let view = BrowserTabSwitcherNSView(frame: NSRect(x: 0, y: 0, width: 420, height: 400))
        view.update(state: .init(entries: (0..<12).map { entry(String($0)) }, selectedTabID: "11", isVisible: true))
        view.layoutSubtreeIfNeeded()
        let selected = try #require(view.cards.last)
        let container = try #require(selected.superview)
        #expect(container.visibleRect.contains(selected.frame))
        #expect(view.cards.allSatisfy { $0.frame.width >= 92 })
        view.update(state: .init(entries: [], selectedTabID: "", isVisible: false))
        #expect(view.cards.isEmpty)
    }

    @Test func aboutKeepsAllThreeCreditDestinationsAndRoutesClicks() {
        let credits = BrowserAboutView.creditsText()
        var urls = [URL]()
        credits.enumerateAttribute(.link, in: NSRange(location: 0, length: credits.length)) { value, _, _ in
            if let url = value as? URL {
                urls.append(url)
            }
        }
        #expect(urls == [
            BrowserAboutResources.chromiumProjectURL,
            BrowserAboutResources.chromiumCreditsLinkURL,
            BrowserAboutResources.openArcCreditsURL,
        ])
        var opened = [URL]()
        let view = BrowserAboutView(info: .init(
            applicationName: "OpenArc",
            applicationVersionText: "1.0",
            chromiumVersionText: "Chromium",
            copyrightText: "Copyright",
            icon: NSImage(),
        )) {
            opened.append($0)
        }
        for url in urls {
            #expect(view.textView(NSTextView(), clickedOnLink: url, at: 0))
        }
        #expect(opened == urls)
    }

    @Test func sharedPaletteResolvesLightAndDarkAppearances() throws {
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        var lightColor: NSColor?
        var darkColor: NSColor?
        light.performAsCurrentDrawingAppearance { lightColor = BrowserChromeColors.primaryText.usingColorSpace(.sRGB) }
        dark.performAsCurrentDrawingAppearance { darkColor = BrowserChromeColors.primaryText.usingColorSpace(.sRGB) }
        #expect(try #require(lightColor).redComponent < 0.1)
        #expect(try #require(darkColor).redComponent > 0.9)
    }

    @Test func menuActionStartsWithReleasedButton() {
        let button = BrowserNativeChromeButton(symbol: "ellipsis", title: "Space menu", action: {})
        var highlightedInsideAction: Bool?
        button.onAction = { highlightedInsideAction = button.isHighlighted }
        button.highlight(true)
        button.performClick(nil)
        #expect(highlightedInsideAction == false)
        #expect(!button.isHighlighted)
        button.onAction = {}
    }

    // MARK: Private

    private func entry(_ id: String) -> BrowserChromeModel.TabSwitcherEntry {
        .init(
            tab: .init(
                id: id,
                syncID: id,
                spaceID: "space",
                title: "Tab \(id)",
                urlString: "https://example.com/\(id)",
            ),
            previewImage: nil,
        )
    }
}

// MARK: - RedrawCountingSurface

private final class RedrawCountingSurface: BrowserNativeSurface {
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            if newValue {
                redrawRequests += 1
            }
            super.needsDisplay = newValue
        }
    }

    private(set) var redrawRequests = 0

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        redrawRequests += 1
        super.setNeedsDisplay(invalidRect)
    }
}
