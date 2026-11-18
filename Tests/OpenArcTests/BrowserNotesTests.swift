// BrowserNotesTests.swift

import AppKit
import Foundation
import Testing

// MARK: - BrowserNoteMarkdownTests

@MainActor struct BrowserNoteMarkdownTests {
    private static func roundTrip(_ markdown: String) -> String {
        BrowserNoteMarkdown.markdown(from: BrowserNoteMarkdown.attributedString(fromMarkdown: markdown))
    }

    @Test func blocksAndMarksSurviveARoundTrip() {
        let markdown = """
        # Trip
        ## Days
        ### Morning
        Plain text with **bold**, *italic*, ~~gone~~ and <u>underlined</u> words.
        A [link](https://example.com/a) and ***both*** marks.
        - one
        - two
            - nested
        1. first
        2. second
            1. inner
        3. third
        
        After the list.
        """
        #expect(Self.roundTrip(markdown) == markdown)
    }

    @Test func blocksAndMarksBecomeAttributes() throws {
        let text = BrowserNoteMarkdown.attributedString(fromMarkdown: "# Title\nsome **bold** and *it*\n- item")
        #expect(BrowserNoteFormatting.block(in: text, at: 0) == .heading(1))
        let string = text.string as NSString
        let bold = string.range(of: "bold")
        #expect(text.attribute(.browserNoteBold, at: bold.location, effectiveRange: nil) as? Bool == true)
        let font = try #require(text.attribute(.font, at: bold.location, effectiveRange: nil) as? NSFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
        let italic = NSRange(location: string.range(of: "and it").location + 4, length: 2)
        #expect(text.attribute(.browserNoteItalic, at: italic.location, effectiveRange: nil) as? Bool == true)
        #expect(BrowserNoteFormatting.block(in: text, at: string.range(of: "item").location) == .bulleted(level: 0))
        #expect(!text.string.contains("#") && !text.string.contains("*"), "Marks leave the text: \(text.string)")
    }

    @Test func markCharactersInTextAreEscaped() {
        let text = NSAttributedString(
            string: "2 * 3 = 6, snake_case and [x]",
            attributes: BrowserNoteTextStyle
                .attributes(for: .paragraph),
        )
        let markdown = BrowserNoteMarkdown.markdown(from: text)
        #expect(markdown == "2 \\* 3 = 6, snake\\_case and \\[x\\]")
        #expect(BrowserNoteMarkdown.attributedString(fromMarkdown: markdown).string == text.string)
        let heading = NSAttributedString(
            string: "# not a heading",
            attributes: BrowserNoteTextStyle
                .attributes(for: .paragraph),
        )
        #expect(BrowserNoteMarkdown.markdown(from: heading) == "\\# not a heading")
    }

    @Test func emphasisNeedsAClosingMarkAndWordBoundaries() {
        #expect(BrowserNoteInlineMarkdown.plainText("a * b") == "a * b")
        #expect(BrowserNoteInlineMarkdown.plainText("snake_case_name") == "snake_case_name")
        #expect(BrowserNoteInlineMarkdown.plainText("_it_ and __bold__") == "it and bold")
        #expect(BrowserNoteInlineMarkdown.plainText("![](note-image:abc) [t](https://x.y) <https://a.b>") ==
            " t https://a.b")
    }

    @Test func spacesStayOutsideMarks() {
        let text = NSMutableAttributedString(
            string: "say bold now",
            attributes: BrowserNoteTextStyle
                .attributes(for: .paragraph),
        )
        BrowserNoteFormatting.toggleMark(.bold, in: text, range: NSRange(location: 3, length: 6))
        #expect(BrowserNoteMarkdown.markdown(from: text) == "say **bold** now")
    }

    @Test func linePrefixesNameTheirBlocks() {
        #expect(BrowserNoteMarkdown.parseBlock("### h").0 == .heading(3))
        #expect(BrowserNoteMarkdown.parseBlock("#### deep").0 == .heading(3))
        #expect(BrowserNoteMarkdown.parseBlock("#tag").0 == .paragraph)
        #expect(BrowserNoteMarkdown.parseBlock("  - two spaces").0 == .bulleted(level: 1))
        #expect(BrowserNoteMarkdown.parseBlock("\t\t* tabs").0 == .bulleted(level: 2))
        #expect(BrowserNoteMarkdown.parseBlock("12) twelve").0 == .numbered(level: 0))
        #expect(BrowserNoteMarkdown.parseBlock("- [x] done").1 == "done")
        #expect(BrowserNoteMarkdown.parseBlock("2024. was a year").0 == .numbered(level: 0))
        #expect(BrowserNoteMarkdown.parseBlock("1.5 liters").0 == .paragraph)
    }

    @Test func imagesAreNamedInTheMarkdown() {
        let markdown = "before ![](note-image:ABC-1) after"
        #expect(BrowserNoteMarkdownText.imageIDs(inMarkdown: markdown) == ["ABC-1"])
        let text = BrowserNoteMarkdown.attributedString(fromMarkdown: markdown)
        let location = (text.string as NSString).range(of: "\u{FFFC}").location
        #expect(text.attribute(.browserNoteImageID, at: location, effectiveRange: nil) as? String == "ABC-1")
        #expect(BrowserNoteMarkdown.markdown(from: text) == markdown)
    }

    @Test func numberedItemsCountWithinTheirLevel() {
        let text = NSMutableAttributedString(attributedString: BrowserNoteMarkdown.attributedString(
            fromMarkdown: "1. one\n    1. two\n    2. three\n2. four\nmiddle\n1. five",
        ))
        BrowserNoteFormatting.renumberLists(in: text)
        let string = text.string as NSString
        func number(_ word: String) -> Int? {
            text.attribute(.browserNoteListNumber, at: string.range(of: word).location, effectiveRange: nil) as? Int
        }
        #expect([number("one"), number("two"), number("three"), number("four"), number("five")] == [1, 1, 2, 2, 1])
        #expect(BrowserNoteTextStyle.listMarker(for: .numbered(level: 1), number: 2) == "b.")
        #expect(BrowserNoteTextStyle.listMarker(for: .numbered(level: 2), number: 4) == "iv.")
        #expect(BrowserNoteTextStyle.listMarker(for: .bulleted(level: 1), number: 1) == "◦")
    }
}

// MARK: - BrowserNoteShortcutTests

@MainActor struct BrowserNoteShortcutTests {
    private static func typed(_ string: String) -> NSMutableAttributedString {
        NSMutableAttributedString(string: string, attributes: BrowserNoteTextStyle.attributes(for: .paragraph))
    }

    @Test(arguments: [
        ("# ", BrowserNoteBlock.heading(1)),
        ("## ", .heading(2)),
        ("### ", .heading(3)),
        ("- ", .bulleted(level: 0)),
        ("* ", .bulleted(level: 0)),
        ("1. ", .numbered(level: 0)),
        ("3) ", .numbered(level: 0)),
    ]) func aPrefixAndASpaceStartABlock(prefix: String, block: BrowserNoteBlock) {
        let text = Self.typed("first\n" + prefix)
        let caret = BrowserNoteFormatting.applyBlockShortcut(in: text, caret: text.length)
        #expect(caret == 6)
        #expect(text.string == "first\n")
        text.append(NSAttributedString(string: "x", attributes: text.attributes(at: 5, effectiveRange: nil)))
        // An empty paragraph at the end carries its block on the next typed text.
        #expect(BrowserNoteFormatting.applyBlockShortcut(in: Self.typed("#tag "), caret: 5) == nil)
        #expect(BrowserNoteFormatting.applyBlockShortcut(in: Self.typed("a # "), caret: 4) == nil)
        let inParagraph = Self.typed(prefix + "rest")
        _ = BrowserNoteFormatting.applyBlockShortcut(in: inParagraph, caret: prefix.utf16.count)
        #expect(inParagraph.string == "rest")
        #expect(BrowserNoteFormatting.block(in: inParagraph, at: 0) == block)
    }

    @Test(arguments: [
        ("say **bold**", BrowserNoteFormatting.InlineMark.bold, "say bold"),
        ("say *bold*", .bold, "say bold"),
        ("say _it_", .italic, "say it"),
        ("say ~~gone~~", .strikethrough, "say gone"),
        ("say ~gone~", .strikethrough, "say gone"),
        ("say -gone- ", .strikethrough, "say gone "),
    ])
    func closingMarksFormatTheWord(typed: String, mark: BrowserNoteFormatting.InlineMark, result: String) {
        let text = Self.typed(typed)
        let caret = BrowserNoteFormatting.applyInlineShortcut(in: text, caret: text.length)
        #expect(text.string == result)
        #expect(caret == (result as NSString).length)
        let word = (text.string as NSString).range(of: result.split(separator: " ")[1].description)
        #expect(BrowserNoteFormatting.hasMark(mark, in: text, range: word))
        #expect(!BrowserNoteFormatting.hasMark(mark, in: text, range: NSRange(location: 0, length: 3)))
    }

    @Test(arguments: ["2*3*", "a **", "x * y*", "well-known-", "snake_case_", "** b**", "a ****"])
    func otherTextStaysAsTyped(typed: String) {
        let text = Self.typed(typed)
        #expect(BrowserNoteFormatting.applyInlineShortcut(in: text, caret: text.length) == nil)
        #expect(text.string == typed)
    }

    @Test func blocksToggleAndListsIndent() {
        let text = NSMutableAttributedString(attributedString: BrowserNoteMarkdown.attributedString(
            fromMarkdown: "a\nb",
        ))
        let all = NSRange(location: 0, length: text.length)
        BrowserNoteFormatting.setBlock(.bulleted(level: 0), in: text, range: all)
        #expect(BrowserNoteMarkdown.markdown(from: text) == "- a\n- b")
        #expect(BrowserNoteFormatting.indentList(in: text, range: NSRange(location: 2, length: 0), by: 1))
        #expect(BrowserNoteMarkdown.markdown(from: text) == "- a\n    - b")
        BrowserNoteFormatting.setBlock(.numbered(level: 0), in: text, range: all)
        #expect(BrowserNoteMarkdown.markdown(from: text) == "1. a\n    1. b", "Kinds change, levels stay")
        BrowserNoteFormatting.setBlock(.numbered(level: 0), in: text, range: all)
        #expect(BrowserNoteMarkdown.markdown(from: text) == "a\nb", "The same kind again turns back into text")
        #expect(!BrowserNoteFormatting.indentList(in: text, range: all, by: 1), "Text has no levels")
        BrowserNoteFormatting.setBlock(.heading(2), in: text, range: NSRange(location: 0, length: 0))
        #expect(BrowserNoteMarkdown.markdown(from: text) == "## a\nb")
    }

    @Test func marksToggleOnAndOff() {
        let text = Self.typed("hello")
        let all = NSRange(location: 0, length: 5)
        for mark in BrowserNoteFormatting.InlineMark.allCases {
            BrowserNoteFormatting.toggleMark(mark, in: text, range: all)
            #expect(BrowserNoteFormatting.hasMark(mark, in: text, range: all))
        }
        #expect(BrowserNoteMarkdown.markdown(from: text) == "***~~<u>hello</u>~~***")
        for mark in BrowserNoteFormatting.InlineMark.allCases {
            BrowserNoteFormatting.toggleMark(mark, in: text, range: all)
        }
        #expect(BrowserNoteMarkdown.markdown(from: text) == "hello")
        let typing = BrowserNoteFormatting.toggledTypingAttributes(
            text.attributes(at: 0, effectiveRange: nil),
            mark: .bold,
        )
        #expect((typing[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }
}

// MARK: - BrowserNotesStoreTests

@MainActor struct BrowserNotesStoreTests {
    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OpenArcNotes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func notesAreFoundByTitleThenText() {
        var now = Date(timeIntervalSince1970: 100)
        let store = BrowserNotesStore(dateProvider: { now })
        let recipe = store.createNote(title: "Pancakes", markdown: "- flour\n- **milk**")
        now += 10
        let groceries = store.createNote(title: "Groceries", markdown: "Buy milk and eggs for the pancakes")
        now += 10
        store.createNote(title: "Unrelated", markdown: "nothing here")
        #expect(store.search("pancakes").map(\.id) == [recipe.id, groceries.id], "Title match first")
        #expect(store.search("MILK").map(\.id) == [groceries.id, recipe.id], "Then the latest edited")
        #expect(store.search("milk eggs").map(\.id) == [groceries.id], "Every word must match")
        #expect(store.search("   ").isEmpty)
        #expect(store.snippet(for: groceries, matching: "eggs")?.contains("eggs") == true)
        #expect(BrowserNote(id: "x", title: "", markdown: "", createdAt: now, updatedAt: now)
            .displayTitle == BrowserStrings.noteUntitled)
    }

    @Test func editsPublishChangesAndKeepTheirOrigin() {
        let store = BrowserNotesStore()
        var changes = [BrowserNotesStore.Change]()
        let cancellable = store.changes.sink { changes.append($0) }
        let note = store.createNote()
        let origin = NSObject()
        store.update(id: note.id, title: "T", origin: origin)
        store.update(id: note.id, title: "T", origin: origin)
        store.delete(id: note.id)
        #expect(changes.map(\.kind) == [.created, .updated, .deleted], "An unchanged edit is not sent")
        #expect(changes[1].origin == ObjectIdentifier(origin))
        withExtendedLifetime(cancellable) {}
    }

    @Test func emptyNotesGoWhenNoWindowShowsThem() async throws {
        let store = BrowserNotesStore()
        store.emptyNoteGracePeriod = 0.01
        let first = NSObject()
        let second = NSObject()
        let empty = store.createNote()
        let written = store.createNote(title: "Kept")
        store.setOpenNoteIDs([empty.id, written.id], owner: first)
        store.setOpenNoteIDs([empty.id], owner: second)
        store.setOpenNoteIDs([], owner: first)
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.note(id: empty.id) != nil, "Another window still shows it")
        #expect(store.note(id: written.id) != nil)
        // A tab that leaves for a moment and comes back keeps its note.
        store.setOpenNoteIDs([], owner: second)
        store.setOpenNoteIDs([empty.id], owner: second)
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.note(id: empty.id) != nil)
        store.setOpenNoteIDs([], owner: second)
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.note(id: empty.id) == nil)
        #expect(store.note(id: written.id) != nil, "A note with text stays")
    }

    @Test func theSessionDatabaseKeepsNotesAndImages() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("OpenArc.sqlite")
        let image = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let noteID: String
        do {
            let database = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
            let store = BrowserNotesStore(persistence: database)
            let note = store.createNote(title: "Kept", markdown: "a ![](note-image:IMG-1)", images: ["IMG-1": image])
            store.update(id: note.id, markdown: "a ![](note-image:IMG-1) b", images: ["IMG-2": image])
            store.removeUnusedImages(noteID: note.id)
            noteID = note.id
            #expect(try database.loadNoteImage(id: "IMG-2") == nil, "An image the note does not show goes")
        }
        let reopened = try BrowserNotesStore(persistence: BrowserSQLiteSessionStore(databaseURL: databaseURL))
        let note = try #require(reopened.note(id: noteID))
        #expect(note.title == "Kept")
        #expect(note.markdown == "a ![](note-image:IMG-1) b")
        #expect(reopened.imageData(id: "IMG-1") == image)
        reopened.delete(id: noteID)
        let afterDelete = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        #expect(try afterDelete.loadNotes().isEmpty)
        #expect(try afterDelete.loadNoteImage(id: "IMG-1") == nil)
    }

    @Test func noteAddressesNameTheirNote() {
        let id = UUID().uuidString
        let url = BrowserNoteURL.urlString(forNoteID: id)
        #expect(url == "openarc://notes/\(id)")
        #expect(BrowserNoteURL.noteID(fromURLString: url) == id)
        #expect(BrowserNoteURL.noteID(fromURLString: "openarc://notes/../settings") == nil)
        #expect(BrowserNoteURL.noteID(fromURLString: "https://notes/\(id)") == nil)
        #expect(BrowserInternalURLNormalizer.canonicalURLString(for: url) == nil, "Chromium never gets it")
        #expect(BrowserFaviconFallbackStyle.webUISymbol(forPageURLString: url) == "note.text")
        #expect(BrowserFaviconFallbackStyle.style(forPageURLString: url) == .chromiumWebUI)
    }
}

// MARK: - BrowserNotesTransferTests

@MainActor struct BrowserNotesTransferTests {
    private static let png: Data = {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        return BrowserNoteImages.pngData(for: image) ?? Data()
    }()

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OpenArcNotes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func exportWritesMarkdownFilesAndAttachments() throws {
        let folder = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = BrowserNotesStore()
        store.createNote(title: "Plans: 2026/Q1", markdown: "- a\n- b ![](note-image:P1)", images: ["P1": Self.png])
        store.createNote(title: "Plans: 2026/Q1", markdown: "second")
        store.createNote(title: "", markdown: "no title")
        let files = try BrowserNotesExport.export(store.notes, imageData: store.imageData(id:), to: folder)
        let names = Set(files.map(\.lastPathComponent))
        #expect(names == ["Plans- 2026-Q1.md", "Plans- 2026-Q1 2.md", BrowserStrings.noteUntitled + ".md"])
        let withImage = try files.map { try String(contentsOf: $0, encoding: .utf8) }.first { $0.contains("- a") }
        #expect(withImage == "# Plans: 2026/Q1\n\n- a\n- b ![](attachments/P1.png)\n")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("attachments/P1.png").path))
    }

    @Test func importReadsBackWhatExportWrote() throws {
        let folder = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = BrowserNotesStore()
        source.createNote(title: "Trip", markdown: "## Day 1\n1. **Walk**\n2. Eat ![](note-image:I1)", images: [
            "I1": Self.png,
        ])
        try BrowserNotesExport.export(source.notes, imageData: source.imageData(id:), to: folder)
        let imported = try BrowserNotesImport.notes(from: [folder])
        let note = try #require(imported.first)
        #expect(imported.count == 1)
        #expect(note.title == "Trip")
        let imageID = try #require(note.images.keys.first)
        #expect(note.markdown == "## Day 1\n1. **Walk**\n2. Eat ![](note-image:\(imageID))")
        #expect(note.images[imageID] == Self.png)
    }

    @Test func zipArchivesOfHTMLNotesImport() throws {
        let folder = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let notes = folder.appendingPathComponent("Export", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let html = """
        <html><head><title>Reading list</title></head><body>
        <h2>Books</h2>
        <p>Start with <b>Dune</b>, then <i>Hyperion</i> and <a href="https://example.com/book">this</a>.</p>
        <ul><li>one</li><li>two</li></ul>
        <ol><li>first</li></ol>
        </body></html>
        """
        try html.write(to: notes.appendingPathComponent("Reading.html"), atomically: true, encoding: .utf8)
        try "plain words".write(to: notes.appendingPathComponent("Other.txt"), atomically: true, encoding: .utf8)
        let archive = folder.appendingPathComponent("Notes-Export.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", notes.path, archive.path]
        try process.run()
        process.waitUntilExit()

        let imported = try BrowserNotesImport.notes(from: [archive])
        #expect(imported.map(\.title) == ["Other", "Reading list"])
        let reading = try #require(imported.last)
        #expect(reading.markdown.contains("## Books"), "\(reading.markdown)")
        #expect(reading.markdown.contains("**Dune**"))
        #expect(reading.markdown.contains("*Hyperion*"))
        #expect(reading.markdown.contains("[this](https://example.com/book)"))
        #expect(reading.markdown.contains("- one\n- two"))
        #expect(reading.markdown.contains("1. first"))
        #expect(imported.first?.markdown == "plain words")
    }

    @Test func fileNamesStayInTheirFolder() {
        #expect(BrowserNotesExport.fileName(for: "../../etc/passwd") == "-..-etc-passwd")
        #expect(BrowserNotesExport.fileName(for: "   ") == BrowserStrings.noteUntitled)
        #expect(BrowserNotesExport.fileName(for: String(repeating: "a", count: 300)).count == 100)
    }
}
