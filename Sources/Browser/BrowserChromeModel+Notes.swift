// BrowserChromeModel+Notes.swift

import AppKit
import Combine
import Foundation

// MARK: - BrowserChromeModel + Notes

/// Notes open in tabs at `openarc://notes/<id>`; the window's content view
/// draws the note's editor over the tab's empty page.
extension BrowserChromeModel {
    // MARK: Internal

    /// Incognito and web-app windows keep no notes.
    var supportsNotes: Bool {
        !isIncognito && !isWebApp
    }

    var canCreateNote: Bool {
        supportsNotes && canCreateTab
    }

    var canExportNotes: Bool {
        supportsNotes && !notesStore.notes.isEmpty
    }

    var selectedNoteID: String? {
        noteID(forTabID: selectedTabID)
    }

    func noteID(forTabID tabID: String?) -> String? {
        guard let tabID, let tab = tabs.first(where: { $0.id == tabID }) else { return nil }
        return BrowserNoteURL.noteID(fromURLString: tab.urlString)
    }

    /// The title a tab showing a note takes.
    func noteTitle(forURLString urlString: String?) -> String? {
        BrowserNoteURL.noteID(fromURLString: urlString).map { noteID in
            notesStore.note(id: noteID)?.displayTitle ?? BrowserStrings.noteUntitled
        }
    }

    /// A note address whose note has nothing in it, or is gone.
    func isEmptyNote(urlString: String) -> Bool {
        guard let noteID = BrowserNoteURL.noteID(fromURLString: urlString) else { return false }
        return notesStore.note(id: noteID)?.isEmpty ?? true
    }

    /// New Note: an empty note in a new tab at the top of Today, or beside the
    /// page on screen in a Split View.
    @discardableResult func createNote(inSplitView: Bool = false) -> Bool {
        guard canCreateNote else { return false }
        let note = notesStore.createNote()
        return showNote(id: note.id, inSplitView: inSplitView)
    }

    /// Opens a note in this window: its tab when one shows it, else a new tab.
    @discardableResult func openNote(id: String, inSplitView: Bool = false) -> Bool {
        guard supportsNotes, notesStore.note(id: id) != nil else { return false }
        if !inSplitView, selectTab(showingNoteID: id) {
            return true
        }
        return showNote(id: id, inSplitView: inSplitView)
    }

    /// Selects this window's tab showing the note, if there is one.
    @discardableResult func selectTab(showingNoteID noteID: String) -> Bool {
        let showing = tabs.filter { BrowserNoteURL.noteID(fromURLString: $0.urlString) == noteID }
        guard let tab = showing.first(where: { $0.spaceID == selectedSpaceID }) ?? showing.first else {
            return false
        }
        selectTab(id: tab.id)
        return true
    }

    /// Deletes a note for good; every tab showing it closes.
    func deleteNote(id: String) {
        closeTabs(showingNoteID: id)
        notesStore.delete(id: id)
    }

    /// Puts the keyboard in the selected tab's note. False when it shows no note.
    @discardableResult func focusSelectedNote() -> Bool {
        guard let noteID = selectedNoteID else { return false }
        return onFocusNote?(noteID, false) ?? false
    }

    /// Notes whose title or text match the query, for the command bar.
    func noteSuggestions(for query: String, maximumCount: Int) -> [BrowserCommandSuggestion] {
        guard supportsNotes, maximumCount > 0 else { return [] }
        return notesStore.search(query, limit: maximumCount).map { note in
            BrowserCommandSuggestion(
                kind: .note,
                displayText: note.displayTitle,
                detailText: notesStore.snippet(for: note, matching: query),
                resolvedURLString: BrowserNoteURL.urlString(forNoteID: note.id),
            )
        }
    }

    /// Follows the notes: titles of tabs showing an edited note, tabs of a
    /// deleted one, and which notes this window shows.
    func observeNotes() {
        notesCancellables.removeAll()
        notesStore.changes
            .sink { [weak self] change in
                guard let self else { return }
                switch change.kind {
                case .created, .updated:
                    refreshNoteTabTitles(noteID: change.noteID)
                case .deleted:
                    closeTabs(showingNoteID: change.noteID)
                }
            }
            .store(in: &notesCancellables)
        $tabs
            .map { tabs in Set(tabs.compactMap { BrowserNoteURL.noteID(fromURLString: $0.urlString) }) }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] ids in
                guard let self else { return }
                notesStore.setOpenNoteIDs(ids, owner: self)
            }
            .store(in: &notesCancellables)
    }

    // MARK: Private

    private func showNote(id: String, inSplitView: Bool) -> Bool {
        guard let url = URL(string: BrowserNoteURL.urlString(forNoteID: id)) else { return false }
        if inSplitView, canAddSplitView, openURLInSplitView(url) {
            refreshNoteTabTitles(noteID: id)
            return true
        }
        openURLInNewTab(url, atTop: true)
        refreshNoteTabTitles(noteID: id)
        return true
    }

    private func refreshNoteTabTitles(noteID: String) {
        guard let title = notesStore.note(id: noteID)?.displayTitle else { return }
        for tab in tabs where BrowserNoteURL.noteID(fromURLString: tab.urlString) == noteID && tab.title != title {
            applyNoteTitle(title, toTabID: tab.id)
        }
    }

    private func closeTabs(showingNoteID noteID: String) {
        for tab in tabs where BrowserNoteURL.noteID(fromURLString: tab.urlString) == noteID {
            closeTab(id: tab.id, forceClose: true, registersUndo: false)
        }
    }
}
