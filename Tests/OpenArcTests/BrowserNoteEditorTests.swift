// BrowserNoteEditorTests.swift

import AppKit
import Foundation
import Testing

// MARK: - BrowserNotesModelTests

@MainActor struct BrowserNotesModelTests {
    private static func makeModel() -> (BrowserChromeModel, FakeBrowserTabDriver) {
        let driver = FakeBrowserTabDriver()
        let defaults = UserDefaults(suiteName: BrowserTestDefaults.suiteName("BrowserNotesModelTests"))!
        let model = BrowserChromeModel(
            tabDriver: driver,
            sessionSnapshotStore: InMemorySessionSnapshotStore(loadedSnapshot: BrowserTabSessionSnapshot(
                tabs: [.init(urlString: "https://example.com")],
            )),
            sessionPreferencesStore: InMemorySessionPreferencesStore(storedSelectedTabIndex: 0),
            commandBarSuggestionProvider: FakeSuggestionProvider(),
            userPreferencesStore: BrowserUserPreferencesStore(userDefaults: defaults),
            shortcutStore: BrowserShortcutStore(userDefaults: defaults),
            extensionManager: FakeBrowserExtensionManager(),
            windowTitleHandler: { _ in },
            allTabsClosedHandler: {},
        )
        model.notesStore = BrowserNotesStore()
        model.notesStore.emptyNoteGracePeriod = 0.01
        model.handleContextReady()
        driver.flushPendingCreateEvents()
        for tab in model.tabs {
            driver.emitTabCreationState(id: tab.id, state: .ready)
        }
        return (model, driver)
    }

    @Test func newNoteOpensATabAtTheTopOfToday() throws {
        let (model, driver) = Self.makeModel()
        #expect(model.isCommandBarActionAvailable(.newNote))
        #expect(!model.isCommandBarActionAvailable(.exportNotes), "Nothing to export yet")
        #expect(model.createNote())
        driver.flushPendingCreateEvents()
        let noteID = try #require(model.selectedNoteID)
        let tab = try #require(model.tabs.first { $0.id == model.selectedTabID })
        #expect(tab.urlString == "openarc://notes/\(noteID)")
        #expect(driver.createdTabRequests.last?.urlString == tab.urlString, "The engine loads the address as is")
        #expect(tab.displayTitle == BrowserStrings.noteUntitled)
        #expect(model.tabs.filter { $0.placement == .temporary }.first?.id == tab.id)

        model.notesStore.update(id: noteID, title: "Shopping")
        #expect(model.tabs.first { $0.id == tab.id }?.displayTitle == "Shopping", "The tab follows the note")
        // The engine reports the empty page's address as its title.
        driver.onTabUpdated?(tab.id, tab.urlString, tab.urlString, nil)
        #expect(model.tabs.first { $0.id == tab.id }?.displayTitle == "Shopping")
        #expect(model.isCommandBarActionAvailable(.exportNotes))
    }

    @Test func theCommandBarFindsNotesByTheirText() throws {
        let (model, driver) = Self.makeModel()
        let note = model.notesStore.createNote(title: "Ideas", markdown: "Build a **treehouse** in spring")
        let suggestions = model.noteSuggestions(for: "treehouse", maximumCount: 5)
        let suggestion = try #require(suggestions.first)
        #expect(suggestion.kind == .note)
        #expect(suggestion.displayText == "Ideas")
        #expect(suggestion.detailText?.contains("treehouse") == true)
        #expect(suggestion.systemImageName == "note.text")

        #expect(model.openNote(id: note.id))
        driver.flushPendingCreateEvents()
        let tabCount = model.tabs.count
        #expect(model.openNote(id: note.id), "An open note is selected again")
        #expect(model.tabs.count == tabCount)
    }

    @Test func closingAnEmptyNoteDeletesItAndDeletingANoteClosesItsTab() async throws {
        let (model, driver) = Self.makeModel()
        model.createNote()
        driver.flushPendingCreateEvents()
        let emptyID = try #require(model.selectedNoteID)
        let emptyTab = try #require(model.selectedTabID)
        // The window reports its notes on the next turn of the run loop.
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))
        model.closeTab(id: emptyTab, forceClose: true)
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.notesStore.note(id: emptyID) == nil)

        model.createNote()
        driver.flushPendingCreateEvents()
        let keptID = try #require(model.selectedNoteID)
        model.notesStore.update(id: keptID, markdown: "text")
        model.deleteNote(id: keptID)
        #expect(model.notesStore.note(id: keptID) == nil)
        #expect(!model.tabs.contains { BrowserNoteURL.noteID(fromURLString: $0.urlString) == keptID })
    }
}

// MARK: - BrowserNoteEditorTests

@MainActor struct BrowserNoteEditorTests {
    private static let sample = """
    ## Weekend
    Pick up **paint** and *brushes*, then [call](https://example.com) the shop.
    - Living room
        - ceiling
    - Kitchen
    1. Sand
    2. Prime
    3. Paint
    """

    private static func window(for view: NSView, size: NSSize, dark: Bool = false) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
        )
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return window
    }

    /// Draws the view offscreen; OPENARC_NOTE_SNAPSHOTS names a folder for the PNG.
    @discardableResult private static func render(_ view: NSView, name: String) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        if let folder = ProcessInfo.processInfo.environment["OPENARC_NOTE_SNAPSHOTS"] {
            let directory = URL(fileURLWithPath: folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try rep.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("\(name).png"))
        }
        return rep
    }

    @Test func theEditorCentersAColumnUnderTheTitle() throws {
        let store = BrowserNotesStore()
        let note = store.createNote(title: "Painting", markdown: Self.sample)
        let editor = BrowserNoteEditorView(noteID: note.id, store: store)
        let window = Self.window(for: editor, size: NSSize(width: 1100, height: 700))
        #expect(editor.titleField.stringValue == "Painting")
        #expect(editor.titleField.frame.width == BrowserNoteEditorLayout.columnWidth)
        #expect(editor.titleField.frame.minX == (1100 - BrowserNoteEditorLayout.columnWidth) / 2)
        #expect(editor.textView.textContainerInset.width == editor.titleField.frame.minX)
        #expect(try BrowserNoteMarkdown.markdown(from: #require(editor.textView.textStorage)) == Self.sample)
        let rep = try Self.render(editor, name: "note-light")
        let corner = try #require(rep.colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB))
        #expect(corner.redComponent > 0.95, "The page is white in light appearance")

        let dark = BrowserNoteEditorView(noteID: note.id, store: store)
        let darkWindow = Self.window(for: dark, size: NSSize(width: 700, height: 700), dark: true)
        #expect(
            dark.titleField.frame.minX == BrowserNoteEditorLayout.minimumSideInset,
            "A narrow pane keeps its margin",
        )
        try Self.render(dark, name: "note-dark")
        withExtendedLifetime((window, darkWindow)) {}
    }

    @Test func typingMarkdownFormatsAndSaves() throws {
        let store = BrowserNotesStore()
        let note = store.createNote()
        let editor = BrowserNoteEditorView(noteID: note.id, store: store)
        let window = Self.window(for: editor, size: NSSize(width: 900, height: 600))
        let text = editor.textView
        window.makeFirstResponder(text)
        for character in "# Plan" {
            text.insertText(String(character), replacementRange: text.selectedRange())
        }
        text.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        for character in "- buy **milk**" {
            text.insertText(String(character), replacementRange: text.selectedRange())
        }
        text.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        for character in "eggs" {
            text.insertText(String(character), replacementRange: text.selectedRange())
        }
        text.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        text.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        for character in "done" {
            text.insertText(String(character), replacementRange: text.selectedRange())
        }
        editor.saveNow()
        #expect(store.note(id: note.id)?.markdown == "# Plan\n- buy **milk**\n- eggs\ndone")

        text.setSelectedRange(NSRange(location: 0, length: 0))
        editor.titleField.stringValue = "Errands"
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(store.note(id: note.id)?.title == "Errands")
        try Self.render(editor, name: "note-typed")
        withExtendedLifetime(window) {}
    }

    @Test func aDeletedOrForeignNoteShowsWhyItIsEmpty() throws {
        let store = BrowserNotesStore()
        let editor = BrowserNoteEditorView(noteID: UUID().uuidString, store: store)
        let window = Self.window(for: editor, size: NSSize(width: 600, height: 400))
        #expect(editor.isMissing)
        #expect(!editor.focus())
        try Self.render(editor, name: "note-missing")
        withExtendedLifetime(window) {}
    }
}
