// BrowserSQLiteSessionStore+Notes.swift

import Foundation
import GRDB

// MARK: - BrowserSQLiteSessionStore + BrowserNotesPersisting

extension BrowserSQLiteSessionStore: BrowserNotesPersisting {
    func loadNotes() throws -> [BrowserNote] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, title, markdown, created_at, updated_at FROM browser_notes").map { row in
                BrowserNote(
                    id: row["id"],
                    title: row["title"],
                    markdown: row["markdown"],
                    createdAt: Date(timeIntervalSince1970: row["created_at"]),
                    updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
                )
            }
        }
    }

    func saveNote(_ note: BrowserNote) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO browser_notes (id, title, markdown, created_at, updated_at) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET title = excluded.title, markdown = excluded.markdown,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    note.id,
                    note.title,
                    note.markdown,
                    note.createdAt.timeIntervalSince1970,
                    note.updatedAt.timeIntervalSince1970,
                ],
            )
        }
    }

    func deleteNote(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM browser_notes WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM browser_note_images WHERE note_id = ?", arguments: [id])
        }
    }

    func loadNoteImage(id: String) throws -> Data? {
        try dbQueue.read { db in
            try Data.fetchOne(db, sql: "SELECT data FROM browser_note_images WHERE id = ?", arguments: [id])
        }
    }

    func saveNoteImages(_ images: [String: Data], noteID: String) throws {
        guard !images.isEmpty else { return }
        try dbQueue.write { db in
            for (id, data) in images {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO browser_note_images (id, note_id, data) VALUES (?, ?, ?)",
                    arguments: [id, noteID, data],
                )
            }
        }
    }

    func deleteNoteImages(noteID: String, keeping imageIDs: Set<String>) throws {
        try dbQueue.write { db in
            let stored = try String.fetchAll(
                db,
                sql: "SELECT id FROM browser_note_images WHERE note_id = ?",
                arguments: [noteID],
            )
            for id in stored where !imageIDs.contains(id) {
                try db.execute(sql: "DELETE FROM browser_note_images WHERE id = ?", arguments: [id])
            }
        }
    }
}
