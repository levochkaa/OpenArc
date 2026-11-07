// BrowserSidebarItemShortcutTests.swift

import AppKit
import Testing

// MARK: - BrowserSidebarItemShortcutTests

@Suite(.serialized)
@MainActor struct BrowserSidebarItemShortcutTests {
    @Test func sidebarItemsFollowTheVisibleSidebarOrder() {
        let f = SidebarDragFixture(
            pinned: [("a", nil), ("hidden", "folder"), ("b", nil)],
            temporary: ["x", "y"],
            apps: ["app"],
            folders: [.init(id: "folder", spaceID: "s", title: "Folder", isExpanded: false)],
        )
        // App tiles first; a collapsed folder hides its tabs.
        #expect(f.model.sidebarItemTabIDs == ["app", "a", "b", "x", "y"].map(f.id))
        // A tab the sidebar keeps visible in its collapsed folder counts too.
        f.model.sidebarRevealedPinnedTabIDsByFolderID = ["folder": [f.id("hidden")]]
        #expect(f.model.sidebarItemTabIDs == ["app", "a", "hidden", "b", "x", "y"].map(f.id))
        f.model.toggleActiveSpacePinnedSectionCollapsed()
        #expect(f.model.sidebarItemTabIDs == ["app", "x", "y"].map(f.id))
    }

    @Test func goToSidebarItemSelectsByPositionAndNextTabWraps() {
        let f = SidebarDragFixture(temporary: ["x", "y"])
        func selectedName() -> String? { f.model.tabs.first { $0.id == f.model.selectedTabID }?.userTitleOverride }
        #expect(f.model.selectSidebarItem(at: 1))
        #expect(selectedName() == "b")
        #expect(!f.model.selectSidebarItem(at: 4), "There is no fifth item")
        #expect(selectedName() == "b")
        #expect(f.model.selectLastSidebarItem())
        #expect(selectedName() == "y")
        #expect(f.model.selectAdjacentSidebarItem(offset: 1))
        #expect(selectedName() == "a", "Next Tab wraps to the first item")
        #expect(f.model.selectAdjacentSidebarItem(offset: -1))
        #expect(selectedName() == "y", "Previous Tab wraps to the last item")
        #expect(f.model.selectAdjacentSidebarItem(offset: -1))
        #expect(selectedName() == "x")
    }

    @Test func aSplitIsOneItemThatReturnsToItsFocusedPane() {
        let f = SidebarDragFixture(temporary: ["x", "y", "z"])
        f.model.selectTab(id: f.id("x"))
        #expect(f.model.openInSplitView(tabID: f.id("y")))
        #expect(f.model.selectedTabID == f.id("y"))
        #expect(f.model.sidebarItemTabIDs == ["a", "b", "x", "z"].map(f.id))
        #expect(f.model.selectAdjacentSidebarItem(offset: 1))
        #expect(f.model.selectedTabID == f.id("z"), "Next Tab leaves the split as one item")
        #expect(f.model.selectAdjacentSidebarItem(offset: -1))
        #expect(f.model.selectedTabID == f.id("y"), "The split comes back at its focused pane")
        #expect(f.model.selectSidebarItem(at: 2))
        #expect(f.model.selectedTabID == f.id("y"), "Selecting the split it is already in keeps the pane")
    }

    @Test func arrowShortcutsGoAheadOfAFocusedPage() {
        func command(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> BrowserLayoutIndependentShortcutCommand? {
            BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
                keyCode: keyCode,
                modifierFlags: flags.union([.numericPad, .function]),
                charactersIgnoringModifiers: "\u{F701}",
            )
        }
        #expect(command(125, [.command, .option]) == .selectNextTab)
        #expect(command(126, [.command, .option]) == .selectPreviousTab)
        #expect(command(124, [.command, .option]) == .selectNextSpace)
        #expect(command(125, [.command]) == nil, "Plain Command-Down stays with the page")
        #expect(command(125, []) == nil)
    }

    @Test func arrowShortcutsSwitchSpacesAndTabs() {
        #expect(BrowserCommands.selectNextSpace.shortcut.displayText == "\u{2325}\u{2318}\u{2192}")
        #expect(
            BrowserCommands.selectPreviousTab.shortcut.displayText == "\u{2325}\u{2318}\u{2191}",
            "The menu shows the arrow",
        )
        #expect(BrowserCommandID.selectNextTabAlternate.layoutIndependentCommand == .selectNextTab)
        let f = SidebarDragFixture(temporary: ["x"])
        func commands(_ query: String) -> [BrowserCommandID] {
            f.model.presentCommandBar()
            f.model.commandBarModel.query = query
            defer { f.model.dismissCommandBar() }
            return f.model.commandBarModel.suggestions.compactMap(\.commandID)
        }
        #expect(commands("next space").contains(.selectNextSpace))
        #expect(!commands("next tab").contains(.selectNextTabAlternate), "Next Tab is listed once")
        #expect(f.model.selectedSpaceID == "s")
        f.model.selectNextSpace()
        #expect(f.model.selectedSpaceID == "t")
    }

    @Test func revealCurrentTabOpensItsPinnedSectionAndAsksForTheSidebar() {
        let f = SidebarDragFixture()
        f.model.selectTab(id: f.id("a"))
        f.model.toggleActiveSpacePinnedSectionCollapsed()
        #expect(f.model.isActiveSpacePinnedSectionCollapsed)
        var reveals = 0
        f.model.onRevealSidebar = { reveals += 1 }
        let request = f.model.sidebarRevealRequestID
        #expect(BrowserCommands.revealCurrentTab.shortcut == .unassigned, "Control-Space switches input sources")
        #expect(f.model.revealSelectedTabInSidebar())
        #expect(!f.model.isActiveSpacePinnedSectionCollapsed)
        #expect(reveals == 1)
        #expect(f.model.sidebarRevealRequestID == request + 1)
    }

    @Test func openExtensionsUsesTheWindowControlCenter() {
        let f = SidebarDragFixture(temporary: ["x"])
        f.model.selectTab(id: f.id("x"))
        #expect(BrowserCommands.openExtensions.shortcut == BrowserKeyboardShortcut("e"))
        #expect(!f.model.canOpenExtensions, "Only a window with URL controls offers it")
        #expect(!f.model.openExtensionsControlCenter())
        var opens = 0
        f.model.onOpenExtensions = { opens += 1 }
        #expect(f.model.openExtensionsControlCenter())
        #expect(opens == 1)
        // A layout that types another character on the E key still opens them.
        #expect(BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
            keyCode: 14,
            modifierFlags: [.command],
            charactersIgnoringModifiers: "у",
        ) == .openExtensions)
    }

    @Test func markdownLinksEscapeTheTitleAndURL() {
        #expect(BrowserMarkdownLink
            .text(title: "Example", urlString: "https://example.com") == "[Example](https://example.com)")
        #expect(
            BrowserMarkdownLink
                .text(title: "A [b] c", urlString: "https://e.com/a_(b)") == "[A \\[b\\] c](https://e.com/a_%28b%29)",
        )
        #expect(BrowserMarkdownLink.text(title: "  ", urlString: "https://e.com") == "[https://e.com](https://e.com)")
        #expect(BrowserCommands.copyLinkAsMarkdown.shortcut == BrowserKeyboardShortcut(
            "c",
            modifiers: [.command, .option, .shift],
        ))
    }

    @Test func quoteLinksHighlightTheSelectedText() {
        let page = "https://example.com/a?b=1"
        #expect(BrowserQuoteLink.urlString(pageURLString: page, quote: "  Hello,   world - again & more ")
            == "https://example.com/a?b=1#:~:text=Hello%2C%20world%20%2D%20again%20%26%20more")
        // The page's own fragment stays; an earlier highlight is replaced.
        #expect(BrowserQuoteLink.urlString(pageURLString: "https://e.com/#intro:~:text=old", quote: "new")
            == "https://e.com/#intro:~:text=new")
        // Long quotes and quotes across paragraphs keep their first and last words.
        let long = Array(repeating: "word", count: 80).joined(separator: " ") + " the very end"
        #expect(BrowserQuoteLink.urlString(pageURLString: page, quote: "One two three four five\nsix seven")
            == "https://example.com/a?b=1#:~:text=One%20two%20three%20four,six%20seven")
        #expect(BrowserQuoteLink.urlString(pageURLString: page, quote: long)?
            .hasSuffix("#:~:text=word%20word%20word%20word,word%20the%20very%20end") == true)
        // Text without spaces splits into words too, and long ends keep whole words.
        let japanese = String(repeating: "日本語のテキスト", count: 60)
        let cjk = BrowserQuoteLink.urlString(pageURLString: page, quote: japanese)
        #expect(cjk?.contains(",") == true && (cjk?.count ?? 1000) < 400)
        let longWords = (1...6)
            .lazy
            .map { index in String(repeating: "x", count: 25) + "\(index)" }
            .joined(separator: " ")
        #expect(BrowserQuoteLink.urlString(pageURLString: page, quote: longWords + "\nend")
            == "\(page)#:~:text=\(String(repeating: "x", count: 25))1%20\(String(repeating: "x", count: 25))2,end")
        #expect(BrowserQuoteLink.urlString(pageURLString: page, quote: " \n ") == nil)
        #expect(BrowserQuoteLink.urlString(pageURLString: "openarc://settings", quote: "x") == nil)
        #expect(BrowserCommands.copyLinkAsQuote.shortcut == BrowserKeyboardShortcut(
            "c",
            modifiers: [.command, .control, .shift],
        ))
    }

    @Test func copyURLAsQuoteCopiesALinkToTheSelection() async {
        let f = SidebarDragFixture(temporary: ["x"])
        f.model.selectTab(id: f.id("x"))
        #expect(f.model.canCopySelectedTextAsQuoteLink)
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        } ?? []
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(saved.map { types in
                let item = NSPasteboardItem()
                for (type, data) in types {
                    item.setData(data, forType: type)
                }
                return item
            })
        }
        f.driver.selectedText = "Example text"
        #expect(await f.model.copySelectedTextAsQuoteLink())
        #expect(pasteboard.string(forType: .string) == "https://x.example#:~:text=Example%20text")
        #expect(pasteboard.string(forType: .URL) == "https://x.example#:~:text=Example%20text")
        f.driver.selectedText = ""
        #expect(await !f.model.copySelectedTextAsQuoteLink())
    }

    @Test func openLocationEditsTheFocusedPaneURL() {
        let f = SidebarDragFixture(temporary: ["x", "y"])
        #expect(BrowserCommands.openLocation.shortcut == BrowserKeyboardShortcut("l"))
        f.model.selectTab(id: f.id("x"))
        #expect(f.model.openInSplitView(tabID: f.id("y")))
        f.model.selectTab(id: f.id("x"))
        #expect(f.model.canOpenLocation)
        f.model.presentCurrentPageCommandBar()
        #expect(f.model.currentPageCommandBarModel.isPresented)
        #expect(f.model.currentPageCommandBarModel.query == "https://x.example")
    }

    @Test func commandsUseTheirDefaultsAndAreOfferedOnlyForExistingItems() {
        #expect(BrowserCommandID.goToSidebarItem1.defaultDescriptor.shortcut == BrowserKeyboardShortcut("1"))
        #expect(BrowserCommandID.goToSidebarItem8.defaultDescriptor.shortcut == BrowserKeyboardShortcut("8"))
        #expect(BrowserCommandID.goToLastSidebarItem.defaultDescriptor.shortcut == BrowserKeyboardShortcut("9"))
        #expect(BrowserCommands.selectNextTabAlternate.shortcut == BrowserKeyboardShortcut(
            "]",
            modifiers: [.command, .shift],
        ))
        #expect(BrowserCommands.toggleSiteToolbar.shortcut == BrowserKeyboardShortcut(
            "d",
            modifiers: [.command, .shift],
        ))
        // Shift turns ] into }, so the physical-key monitor dispatches Next Tab.
        #expect(BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
            keyCode: 30,
            modifierFlags: [.command, .shift],
            charactersIgnoringModifiers: "}",
        ) == .selectNextTab)
        // A layout that types another character on the 7 key still reaches item 7.
        #expect(BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
            keyCode: 26,
            modifierFlags: [.command],
            charactersIgnoringModifiers: "è",
        ) == .goToSidebarItem(6))
        let defaults = BrowserCommandID.allCases.map(\.defaultDescriptor.shortcut).filter(\.isAssigned)
        #expect(Set(defaults).count == defaults.count, "Default shortcuts stay unique")

        let f = SidebarDragFixture(temporary: ["x"])
        func commands(_ query: String) -> [BrowserCommandID] {
            f.model.presentCommandBar()
            f.model.commandBarModel.query = query
            defer { f.model.dismissCommandBar() }
            return f.model.commandBarModel.suggestions.compactMap(\.commandID)
        }
        #expect(commands("sidebar item 3").contains(.goToSidebarItem3))
        #expect(!commands("sidebar item 4").contains(.goToSidebarItem4), "Only existing items are offered")
        #expect(!commands("downloads").contains(.viewDownloads), "Only a window with a downloads list offers it")
        #expect(!f.model.toggleDownloads())
        var toggles = 0
        f.model.onToggleDownloads = { toggles += 1 }
        #expect(commands("downloads").contains(.viewDownloads))
        #expect(f.model.toggleDownloads())
        #expect(toggles == 1)
        #expect(BrowserCommands.viewDownloads.shortcut == BrowserKeyboardShortcut("j", modifiers: [.command, .shift]))
        #expect(f.model.siteToolbarToggleTitle == BrowserStrings.menuShowToolbar)
        f.model.userPreferencesStore.siteURLToolbarEnabled = true
        #expect(f.model.siteToolbarToggleTitle == BrowserStrings.menuHideToolbar)
    }
}
