import AppKit
import Testing

@Suite(.serialized)
@MainActor struct BrowserNativeCommandBarTests {
    // MARK: Internal

    @Test func compactPanelUsesWindowAnchorAndClampsLongInput() {
        let anchor = CGRect(x: 220, y: 720, width: 400, height: 28)
        let anchored = BrowserCommandBarLayout(
            availableSize: CGSize(width: 1200, height: 800),
            style: .compact(
                anchorFrame: anchor,
                sidebarWidth: 240,
                matchesAnchorWidth: true
            ),
            displayText: "example.com",
            suggestionCount: 2
        )
        #expect(anchored.panelFrame.minX == 220)
        #expect(anchored.panelFrame.minY == 52)
        #expect(anchored.panelWidth == anchor.width)
        let growing = BrowserCommandBarLayout(
            availableSize: CGSize(width: 1200, height: 800),
            style: .compact(
                anchorFrame: anchor,
                sidebarWidth: 240,
                matchesAnchorWidth: false
            ),
            displayText: String(repeating: "long-input", count: 100),
            suggestionCount: 10
        )
        #expect(growing.panelWidth == 600)
        #expect(growing.visibleSuggestionCount == 5)
        let narrow = BrowserCommandBarLayout(
            availableSize: CGSize(width: 320, height: 480),
            style: .standard,
            displayText: "",
            suggestionCount: 0
        )
        #expect(narrow.panelFrame.minX >= 0)
        #expect(narrow.panelFrame.maxX <= 320)
    }

    @Test func nativeKeyboardNavigationPreviewsWithoutChangingCommittedQuery() async throws {
        let model = BrowserCommandBarModel(
            suggestionProvider: FakeSuggestionProvider(suggestionsByQuery: ["browser": ["browser command bar"]]),
            suggestionDebounceNanoseconds: 0,
            submitHandler: { _ in }
        )
        let view = BrowserCommandBarNSView(model: model, faviconCache: BrowserFaviconCache(dataLoader: { _ in nil }))
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        model.present(initialQuery: "browser")
        await model.waitForPendingSuggestionLoad()
        try await waitUntil { view.displayedSuggestions == model.suggestions }
        let editor = NSTextView()
        for _ in 0..<2 {
            #expect(view.control(view.queryField, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        }
        try await waitUntil { view.queryField.previewDisplayText == "browser command bar" }
        #expect(model.query == "browser")
        #expect(view.queryField.stringValue == "browser command bar")
        #expect(view.control(view.queryField, textView: editor, doCommandBy: #selector(NSResponder.moveRight(_:))))
        #expect(model.query == "browser command bar")
        #expect(view.control(
            view.queryField,
            textView: editor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        ))
        #expect(!model.isPresented)
    }

    @Test func overlayPassesSidebarClicksThroughAndDismissesFromPageBackdrop() {
        let model = BrowserCommandBarModel(suggestionProvider: FakeSuggestionProvider(), submitHandler: { _ in })
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let view = BrowserCommandBarNSView(model: model)
        root.addSubview(view)
        view.frame = root.bounds
        model.present()
        view.configure(blockedLeadingInset: 240, style: .standard, faviconCandidate: nil)
        view.layoutSubtreeIfNeeded()
        #expect(view.hitTest(NSPoint(x: 20, y: 20)) == nil)
        #expect(view.hitTest(NSPoint(x: 980, y: 20)) === view)
        model.dismiss()
        #expect(view.hitTest(NSPoint(x: 980, y: 20)) == nil)
    }

    @Test func delayedFocusCannotReclaimResponderAfterPresentationIsRevoked() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        window.contentView = root
        let field = BrowserCommandNSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        let other = NSTextField(frame: NSRect(x: 0, y: 50, width: 200, height: 28))
        root.addSubview(field)
        root.addSubview(other)
        defer { window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
        }
        var permission = true
        field.focusPermission = { permission }
        field.syncCommandPresentation(
            text: "example",
            previewDisplayText: nil,
            inlineCompletionSuffix: nil,
            shouldFocus: true,
            focusRequestID: 1,
            fontSize: 22,
            selectAllOnFocus: false
        )
        permission = false
        #expect(window.makeFirstResponder(other))
        try await Task.sleep(for: .milliseconds(25))
        #expect(window.firstResponder === other || window.firstResponder === other.currentEditor())
    }

    @Test func completionSelectionUsesUTF16OffsetsAndDoesNotCommitPreview() {
        let field = BrowserCommandNSTextField()
        field.syncCommandPresentation(
            text: "😀",
            previewDisplayText: "😀example",
            inlineCompletionSuffix: "example",
            shouldFocus: false,
            focusRequestID: 0,
            fontSize: 22,
            selectAllOnFocus: false
        )
        #expect(field.previewSelectionRange == NSRange(location: 2, length: 7))
        #expect(field.committedText == "😀")
        #expect(field.stringValue == "😀example")
    }

    @Test func unrelatedRefreshPreservesSelectionAndAcceptingPreviewCollapsesOnlyItsSuffix() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let field = BrowserCommandNSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        field.focusPermission = { false }
        field.stringValue = "abcdef"
        window.contentView = field
        defer { window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
        }
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 2, length: 2))
        field.syncCommandPresentation(
            text: "abcdef",
            previewDisplayText: nil,
            inlineCompletionSuffix: nil,
            shouldFocus: true,
            focusRequestID: 1,
            fontSize: 22,
            selectAllOnFocus: false
        )
        #expect(editor.selectedRange() == NSRange(location: 2, length: 2))
        field.syncCommandPresentation(
            text: "abc",
            previewDisplayText: "abcdef",
            inlineCompletionSuffix: "def",
            shouldFocus: true,
            focusRequestID: 1,
            fontSize: 22,
            selectAllOnFocus: false
        )
        #expect(editor.selectedRange() == NSRange(location: 3, length: 3))
        field.syncCommandPresentation(
            text: "abcdef",
            previewDisplayText: nil,
            inlineCompletionSuffix: nil,
            shouldFocus: true,
            focusRequestID: 1,
            fontSize: 22,
            selectAllOnFocus: false
        )
        #expect(editor.selectedRange() == NSRange(location: 6, length: 0))
    }

    @Test func suggestionRefreshDoesNotReplaceActiveInputMethodComposition() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let field = BrowserCommandNSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        field.focusPermission = { false }
        window.contentView = field
        defer { window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
        }
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.setMarkedText(
            "に",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(editor.hasMarkedText())
        field.syncCommandPresentation(
            text: "に",
            previewDisplayText: "日本",
            inlineCompletionSuffix: nil,
            shouldFocus: true,
            focusRequestID: 1,
            fontSize: 22,
            selectAllOnFocus: false
        )
        #expect(editor.string == "に")
        #expect(editor.hasMarkedText())
        editor.unmarkText()
    }

    @Test func shortSuggestionTitlesAndShortcutBadgesFitWithoutEllipses() throws {
        let row = BrowserCommandSuggestionNSView(frame: NSRect(x: 0, y: 0, width: 704, height: 42))
        row.update(
            suggestion: .init(kind: .search, displayText: "find", shortcut: BrowserKeyboardShortcut("f")),
            selected: true,
            favicon: nil
        )
        row.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for label in descendants(row).compactMap({ $0 as? NSTextField })
            where ["find", "⌘F"].contains(label.stringValue)
        {
            let drawingRect = try #require(label.cell).drawingRect(forBounds: label.bounds)
            let width = try (label.stringValue as NSString).size(withAttributes: [.font: #require(label.font)]).width
            #expect(drawingRect.width >= ceil(width))
            #expect(row.bounds.contains(label.convert(label.bounds, to: row)))
        }
        #expect(row.title == "find")
    }

    @Test func alreadyPresentedCompactEditorStillRequestsInitialSelectAll() {
        let model = BrowserCommandBarModel(suggestionProvider: FakeSuggestionProvider(), submitHandler: { _ in })
        model.present(initialQuery: "https://example.com")
        let view = BrowserCommandBarNSView(model: model)
        view.configure(
            blockedLeadingInset: 0,
            style: .compact(anchorFrame: nil, sidebarWidth: 240, matchesAnchorWidth: false),
            faviconCandidate: nil
        )
        #expect(view.queryField.selectAllOnFocus)
        #expect(view.queryField.focusSelectionRequestID == model.focusRequestID)
    }

    @Test func keyboardSelectionRevealsRowsWithoutCenteringOrLeavingABottomGap() async throws {
        let suggestions = (0..<9).map { "browser suggestion \($0)" }
        let model = BrowserCommandBarModel(
            suggestionProvider: FakeSuggestionProvider(suggestionsByQuery: ["browser": suggestions]),
            suggestionDebounceNanoseconds: 0, submitHandler: { _ in }
        )
        let view = BrowserCommandBarNSView(model: model, faviconCache: BrowserFaviconCache(dataLoader: { _ in nil }))
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        model.present(initialQuery: "browser")
        await model.waitForPendingSuggestionLoad()
        try await waitUntil { view.displayedSuggestions == model.suggestions }
        view.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let scroll = try #require(descendants(view).compactMap { $0 as? NSScrollView }.first)
        let table = try #require(scroll.documentView as? NSTableView)
        let initialOrigin = scroll.contentView.bounds.minY
        model.moveSelection(by: 2)
        try await waitUntil { table.selectedRow == model.selectedSuggestionIndex }
        view.layoutSubtreeIfNeeded()
        #expect(scroll.contentView.bounds.minY == initialOrigin)
        model.moveSelection(by: 100)
        try await waitUntil { table.selectedRow == model.selectedSuggestionIndex }
        view.layoutSubtreeIfNeeded()
        let last = table.rect(ofRow: table.numberOfRows - 1)
        let viewport = scroll.contentView.bounds
        #expect(viewport.contains(last.insetBy(dx: 1, dy: 1)))
        #expect(viewport.maxY - last.maxY <= BrowserChromeLayout.commandBarSuggestionVerticalInset + 1)
    }

    @Test(arguments: [0, 1, 3])
    func keyboardSelectionKeepsFullyVisibleSuggestionsInPlace(providerSuggestionCount: Int) async throws {
        let suggestions = (0..<providerSuggestionCount).map { "browser suggestion \($0)" }
        let model = BrowserCommandBarModel(
            suggestionProvider: FakeSuggestionProvider(suggestionsByQuery: ["browser": suggestions]),
            suggestionDebounceNanoseconds: 0, submitHandler: { _ in }
        )
        let view = BrowserCommandBarNSView(model: model, faviconCache: BrowserFaviconCache(dataLoader: { _ in nil }))
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        model.present(initialQuery: "browser")
        await model.waitForPendingSuggestionLoad()
        try await waitUntil { view.displayedSuggestions == model.suggestions }
        try #require((2...BrowserCommandBarModel.maximumVisibleSuggestions).contains(model.suggestions.count))
        view.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let scroll = try #require(descendants(view).compactMap { $0 as? NSScrollView }.first)
        let table = try #require(scroll.documentView as? NSTableView)
        let initialOrigin = scroll.contentView.bounds.minY
        for _ in 1..<model.suggestions.count {
            model.moveSelection(by: 1)
            try await waitUntil { table.selectedRow == model.selectedSuggestionIndex }
            view.layoutSubtreeIfNeeded()
            #expect(scroll.contentView.bounds.minY == initialOrigin)
        }
        let first = table.rect(ofRow: 0).insetBy(dx: 0, dy: BrowserChromeLayout.commandBarSuggestionSpacing / 2)
        let last = table.rect(ofRow: table.numberOfRows - 1)
            .insetBy(dx: 0, dy: BrowserChromeLayout.commandBarSuggestionSpacing / 2)
        let viewport = scroll.contentView.bounds
        #expect(first.minY - viewport.minY == BrowserChromeLayout.commandBarSuggestionVerticalInset)
        #expect(viewport.maxY - last.maxY == BrowserChromeLayout.commandBarSuggestionVerticalInset)
    }

    // MARK: Private

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(predicate())
    }
}
