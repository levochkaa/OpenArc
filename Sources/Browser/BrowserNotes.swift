// BrowserNotes.swift

import Combine
import Foundation

// MARK: - BrowserNote

/// A rich-text note. Its body is kept as Markdown; images live beside it and
/// the Markdown names them as `note-image:<id>`.
struct BrowserNote: Codable, Equatable, Identifiable {
    // MARK: Internal

    let id: String
    var title: String
    var markdown: String
    var createdAt: Date
    var updatedAt: Date

    /// The title, or "Untitled" for a note without one.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? BrowserStrings.noteUntitled : trimmed
    }

    /// The body without Markdown marks, for search and previews.
    var plainText: String {
        BrowserNoteMarkdownText.plainText(fromMarkdown: markdown)
    }

    /// No title and no text: closing it deletes it.
    var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Image IDs the body shows, in order.
    var imageIDs: [String] {
        BrowserNoteMarkdownText.imageIDs(inMarkdown: markdown)
    }
}

// MARK: - BrowserNoteURL

/// A note opens in a tab at `openarc://notes/<id>`; the sidebar, folders,
/// pinning, Split View and Archive treat it as any other tab.
enum BrowserNoteURL {
    static let host = BrowserInternalURLNormalizer.notesHost
    /// A note's icon in the sidebar, the command bar and menus.
    static let symbolName = "note.text"

    static func urlString(forNoteID noteID: String) -> String {
        "\(BrowserInternalURLNormalizer.canonicalScheme)://\(host)/\(noteID)"
    }

    /// The note a tab address shows, if it is a note address.
    static func noteID(fromURLString urlString: String?) -> String? {
        guard
            let urlString,
            let components = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
            components.scheme?.lowercased() == BrowserInternalURLNormalizer.canonicalScheme,
            components.host?.lowercased() == host
        else {
            return nil
        }

        let id = components.path.split(separator: "/").first.map(String.init) ?? ""
        return isValidNoteID(id) ? id : nil
    }

    static func isNoteURLString(_ urlString: String?) -> Bool {
        noteID(fromURLString: urlString) != nil
    }

    /// IDs are UUIDs; a hand-made address with anything else opens no note.
    static func isValidNoteID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
            && id.allSatisfy(\.isASCII)
    }
}

// MARK: - BrowserNotesPersisting

/// Where a profile's notes are kept. The session database keeps them, so
/// restore points include them.
protocol BrowserNotesPersisting: AnyObject {
    func loadNotes() throws -> [BrowserNote]
    func saveNote(_ note: BrowserNote) throws
    func deleteNote(id: String) throws
    func loadNoteImage(id: String) throws -> Data?
    func saveNoteImages(_ images: [String: Data], noteID: String) throws
    /// Drops the note's images its body no longer shows.
    func deleteNoteImages(noteID: String, keeping imageIDs: Set<String>) throws
}

// MARK: - BrowserInMemoryNotesPersistence

/// Notes for windows without a session database, and for tests.
final class BrowserInMemoryNotesPersistence: BrowserNotesPersisting {
    // MARK: Internal

    private(set) var notes = [String: BrowserNote]()
    private(set) var images = [String: (noteID: String, data: Data)]()

    func loadNotes() -> [BrowserNote] {
        Array(notes.values)
    }

    func saveNote(_ note: BrowserNote) {
        notes[note.id] = note
    }

    func deleteNote(id: String) {
        notes.removeValue(forKey: id)
        images = images.filter { $0.value.noteID != id }
    }

    func loadNoteImage(id: String) -> Data? {
        images[id]?.data
    }

    func saveNoteImages(_ newImages: [String: Data], noteID: String) {
        for (id, data) in newImages {
            images[id] = (noteID, data)
        }
    }

    func deleteNoteImages(noteID: String, keeping imageIDs: Set<String>) {
        images = images.filter { $0.value.noteID != noteID || imageIDs.contains($0.key) }
    }
}

// MARK: - BrowserNotesStore

/// A profile's notes, shared by its windows. Every change is written at once.
@MainActor final class BrowserNotesStore {
    // MARK: Internal

    struct Change: Equatable {
        enum Kind: Equatable {
            case created
            case updated
            case deleted
        }

        let noteID: String
        let kind: Kind
        /// The editor that made the change, which already shows it.
        let origin: ObjectIdentifier?
    }

    let changes = PassthroughSubject<Change, Never>()

    /// How long a note must stay closed before an empty one is deleted. A
    /// tab can leave a window's list for a moment while its page restarts or
    /// moves, so the check waits.
    var emptyNoteGracePeriod: TimeInterval = 1

    // MARK: Private

    private let persistence: BrowserNotesPersisting
    private let dateProvider: () -> Date
    private var notesByID = [String: BrowserNote]()
    private var imageCache = [String: Data?]()
    private var openNoteIDsByOwner = [ObjectIdentifier: Set<String>]()

    /// Every note, the latest edited first.
    var notes: [BrowserNote] {
        notesByID.values.sorted { lhs, rhs in
            lhs.updatedAt == rhs.updatedAt ? lhs.id < rhs.id : lhs.updatedAt > rhs.updatedAt
        }
    }

    init(persistence: BrowserNotesPersisting? = nil, dateProvider: @escaping () -> Date = Date.init) {
        self.persistence = persistence ?? BrowserInMemoryNotesPersistence()
        self.dateProvider = dateProvider
        do {
            for note in try self.persistence.loadNotes() {
                notesByID[note.id] = note
            }
        } catch {
            NSLog("OpenArc notes: loading failed: \(error)")
        }
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    func note(id: String) -> BrowserNote? {
        notesByID[id]
    }

    @discardableResult func createNote(title: String = "", markdown: String = "", images: [String: Data] = [:])
        -> BrowserNote
    {
        let now = dateProvider()
        let note = BrowserNote(
            id: UUID().uuidString,
            title: title,
            markdown: markdown,
            createdAt: now,
            updatedAt: now,
        )
        notesByID[note.id] = note
        write(note, images: images)
        changes.send(Change(noteID: note.id, kind: .created, origin: nil))
        return note
    }

    /// Saves an edit; nil leaves that part as it is. An unchanged note is not written.
    func update(
        id: String,
        title: String? = nil,
        markdown: String? = nil,
        images: [String: Data] = [:],
        origin: AnyObject? = nil,
    ) {
        guard var note = notesByID[id] else { return }
        let newTitle = title ?? note.title
        let newMarkdown = markdown ?? note.markdown
        guard newTitle != note.title || newMarkdown != note.markdown || !images.isEmpty else { return }
        note.title = newTitle
        note.markdown = newMarkdown
        note.updatedAt = max(dateProvider(), note.updatedAt)
        notesByID[id] = note
        write(note, images: images)
        changes.send(Change(noteID: id, kind: .updated, origin: origin.map(ObjectIdentifier.init)))
    }

    /// Drops images the note no longer shows; its editor calls this when it
    /// closes, so Undo can bring an image back while it is open.
    func removeUnusedImages(noteID: String) {
        guard let note = notesByID[noteID] else { return }
        do {
            try persistence.deleteNoteImages(noteID: noteID, keeping: Set(note.imageIDs))
        } catch {
            NSLog("OpenArc notes: removing images failed: \(error)")
        }
    }

    func delete(id: String) {
        guard let note = notesByID.removeValue(forKey: id) else { return }
        for imageID in note.imageIDs {
            imageCache.removeValue(forKey: imageID)
        }
        do {
            try persistence.deleteNote(id: id)
        } catch {
            NSLog("OpenArc notes: deleting failed: \(error)")
        }
        changes.send(Change(noteID: id, kind: .deleted, origin: nil))
    }

    /// The notes a window shows in its tabs. A note that stays closed and
    /// empty everywhere is deleted.
    func setOpenNoteIDs(_ ids: Set<String>, owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        let previous = openNoteIDsByOwner[key] ?? []
        guard previous != ids else { return }
        openNoteIDsByOwner[key] = ids.isEmpty ? nil : ids
        let closed = previous.subtracting(ids).filter { notesByID[$0]?.isEmpty == true }
        guard !closed.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + emptyNoteGracePeriod) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                for id in closed where !self.isOpen(noteID: id) && self.note(id: id)?.isEmpty == true {
                    self.delete(id: id)
                }
            }
        }
    }

    func isOpen(noteID: String) -> Bool {
        openNoteIDsByOwner.values.contains { $0.contains(noteID) }
    }

    func imageData(id: String) -> Data? {
        if let cached = imageCache[id] {
            return cached
        }
        let data = try? persistence.loadNoteImage(id: id)
        imageCache[id] = data
        return data
    }

    /// Notes whose title or text contain every word of the query; title
    /// matches first, then the latest edited.
    func search(_ query: String, limit: Int = 20) -> [BrowserNote] {
        let words = Self.folded(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, limit > 0 else { return [] }
        var titleMatches = [BrowserNote]()
        var textMatches = [BrowserNote]()
        for note in notes {
            let title = Self.folded(note.displayTitle)
            if words.allSatisfy(title.contains) {
                titleMatches.append(note)
                continue
            }
            let text = title + " " + Self.folded(note.plainText)
            if words.allSatisfy(text.contains) {
                textMatches.append(note)
            }
        }
        return Array((titleMatches + textMatches).prefix(limit))
    }

    /// A line of the note's text around the first match, for a result's detail.
    func snippet(for note: BrowserNote, matching query: String, length: Int = 80) -> String? {
        let text = note.plainText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let word = Self.folded(query).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard
            !word.isEmpty,
            let range = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive])
        else {
            return String(text.prefix(length))
        }
        let start = text.index(range.lowerBound, offsetBy: -min(24, text.distance(
            from: text.startIndex,
            to: range.lowerBound,
        )))
        let end = text.index(start, offsetBy: min(length, text.distance(from: start, to: text.endIndex)))
        return (start == text.startIndex ? "" : "…") + text[start..<end] + (end == text.endIndex ? "" : "…")
    }

    private func write(_ note: BrowserNote, images: [String: Data]) {
        for (id, data) in images {
            imageCache[id] = data
        }
        do {
            try persistence.saveNote(note)
            if !images.isEmpty {
                try persistence.saveNoteImages(images, noteID: note.id)
            }
        } catch {
            NSLog("OpenArc notes: saving failed: \(error)")
        }
    }
}

// MARK: - BrowserNoteMarkdownText

/// Reads the Markdown a note keeps without building rich text.
enum BrowserNoteMarkdownText {
    static let imageScheme = "note-image"

    static func imageIDs(inMarkdown markdown: String) -> [String] {
        let pattern = "!\\[[^\\]]*\\]\\(\(imageScheme):([A-Za-z0-9-]+)\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let string = markdown as NSString
        return regex.matches(in: markdown, range: NSRange(location: 0, length: string.length)).map {
            string.substring(with: $0.range(at: 1))
        }
    }

    /// The text a reader sees: no heading, list or emphasis marks, link text
    /// without its address, no images.
    static func plainText(fromMarkdown markdown: String) -> String {
        markdown.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                BrowserNoteInlineMarkdown.plainText(BrowserNoteMarkdown.parseBlock(String(line)).1)
            }
            .joined(separator: "\n")
    }
}

// MARK: - BrowserStrings + Notes

extension BrowserStrings {
    static let noteUntitled = NSLocalizedString(
        "browser.notes.untitled",
        comment: "Title of a note the user has not named.",
    )
    static let noteTitlePlaceholder = NSLocalizedString(
        "browser.notes.title_placeholder",
        comment: "Placeholder of a note's title field.",
    )
    static let noteBodyPlaceholder = NSLocalizedString(
        "browser.notes.body_placeholder",
        comment: "Placeholder of an empty note's text.",
    )
    static let menuNewNote = NSLocalizedString(
        "browser.menu.new_note",
        comment: "Menu, command and sidebar plus menu: create a note in a new tab.",
    )
    static let menuNewNoteInSplitView = NSLocalizedString(
        "browser.menu.new_note_in_split",
        comment: "Menu and command: create a note beside the page on screen.",
    )
    static let menuExportNotes = NSLocalizedString(
        "browser.menu.export_notes",
        comment: "Menu and command: save every note as Markdown files in a folder.",
    )
    static let menuImportNotes = NSLocalizedString(
        "browser.menu.import_notes",
        comment: "Menu and command: add notes from Markdown, text, HTML or zip files.",
    )
    static let notesExportPanelPrompt = NSLocalizedString(
        "browser.notes.export_prompt",
        comment: "Button of the folder panel of Export Notes.",
    )
    static let notesExportPanelMessage = NSLocalizedString(
        "browser.notes.export_message",
        comment: "Message of the folder panel of Export Notes.",
    )
    static let notesImportPanelMessage = NSLocalizedString(
        "browser.notes.import_message",
        comment: "Message of the open panel of Import Notes.",
    )
    static let notesImportPanelPrompt = NSLocalizedString(
        "browser.notes.import_prompt",
        comment: "Button of the open panel of Import Notes.",
    )
    static let notesNothingToImport = NSLocalizedString(
        "browser.notes.nothing_to_import",
        comment: "Alert after Import Notes found nothing.",
    )
    static let notesTransferFailed = NSLocalizedString(
        "browser.notes.transfer_failed",
        comment: "Alert title when Export or Import Notes fails.",
    )
    static let noteDeleteMenu = NSLocalizedString(
        "browser.notes.delete",
        comment: "Note menu: delete the note for good.",
    )
    static let noteDeleteConfirmTitle = NSLocalizedString(
        "browser.notes.delete_confirm_title",
        comment: "Alert title before deleting a note; the argument is its title.",
    )
    static let noteDeleteConfirmMessage = NSLocalizedString(
        "browser.notes.delete_confirm_message",
        comment: "Alert message before deleting a note.",
    )
    static let noteDeleteButton = NSLocalizedString(
        "browser.notes.delete_button",
        comment: "Alert button: delete the note.",
    )
    static let noteCancelButton = NSLocalizedString(
        "browser.notes.cancel_button",
        comment: "Alert button: keep the note.",
    )
    static let noteCopyMarkdown = NSLocalizedString(
        "browser.notes.copy_markdown",
        comment: "Note menu: copy the whole note as Markdown.",
    )
    static let noteExportMarkdown = NSLocalizedString(
        "browser.notes.export_markdown",
        comment: "Note menu: save this note as a Markdown file.",
    )
    static let noteMenuButton = NSLocalizedString(
        "browser.notes.menu_button",
        comment: "Accessibility label of the note's menu button.",
    )
    static let noteFormatText = NSLocalizedString(
        "browser.notes.format.text",
        comment: "Format bar: plain paragraph.",
    )
    static let noteFormatHeading1 = NSLocalizedString(
        "browser.notes.format.heading1",
        comment: "Format bar: large heading.",
    )
    static let noteFormatHeading2 = NSLocalizedString(
        "browser.notes.format.heading2",
        comment: "Format bar: medium heading.",
    )
    static let noteFormatHeading3 = NSLocalizedString(
        "browser.notes.format.heading3",
        comment: "Format bar: small heading.",
    )
    static let noteFormatBold = NSLocalizedString(
        "browser.notes.format.bold",
        comment: "Format bar button.",
    )
    static let noteFormatItalic = NSLocalizedString(
        "browser.notes.format.italic",
        comment: "Format bar button.",
    )
    static let noteFormatUnderline = NSLocalizedString(
        "browser.notes.format.underline",
        comment: "Format bar button.",
    )
    static let noteFormatStrikethrough = NSLocalizedString(
        "browser.notes.format.strikethrough",
        comment: "Format bar button.",
    )
    static let noteFormatBulletedList = NSLocalizedString(
        "browser.notes.format.bulleted_list",
        comment: "Format bar button.",
    )
    static let noteFormatNumberedList = NSLocalizedString(
        "browser.notes.format.numbered_list",
        comment: "Format bar button.",
    )
    static let noteFormatLink = NSLocalizedString(
        "browser.notes.format.link",
        comment: "Format bar button: add or edit a link.",
    )
    static let noteLinkPrompt = NSLocalizedString(
        "browser.notes.link_prompt",
        comment: "Title of the panel that asks for a link's address.",
    )
    static let noteLinkApply = NSLocalizedString(
        "browser.notes.link_apply",
        comment: "Button that adds the typed link.",
    )
    static let noteLinkRemove = NSLocalizedString(
        "browser.notes.link_remove",
        comment: "Button that removes the selection's link.",
    )
    static let noteMissingTitle = NSLocalizedString(
        "browser.notes.missing_title",
        comment: "Shown in place of a note kept on another computer or deleted.",
    )
    static let noteMissingMessage = NSLocalizedString(
        "browser.notes.missing_message",
        comment: "Detail under the missing note title.",
    )
    static func notesExported(_ count: Int) -> String {
        count == 1
            ? NSLocalizedString("browser.notes.exported_one", comment: "Alert after Export Notes with one note.")
            : String(
                format: NSLocalizedString(
                    "browser.notes.exported",
                    comment: "Alert after Export Notes; the argument is the number of notes.",
                ),
                count,
            )
    }

    static func notesImported(_ count: Int) -> String {
        count == 1
            ? NSLocalizedString("browser.notes.imported_one", comment: "Alert after Import Notes with one note.")
            : String(
                format: NSLocalizedString(
                    "browser.notes.imported",
                    comment: "Alert after Import Notes; the argument is the number of notes.",
                ),
                count,
            )
    }
}
