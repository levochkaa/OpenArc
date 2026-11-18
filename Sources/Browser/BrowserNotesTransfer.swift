// BrowserNotesTransfer.swift

import AppKit
import Foundation

// MARK: - BrowserNotesExport

/// Export Notes: one Markdown file per note in a folder the user picks; the
/// title is the first line, as a heading, and images go to `attachments/`.
enum BrowserNotesExport {
    // MARK: Internal

    static let attachmentsFolder = "attachments"

    /// Writes the notes and returns the files written.
    @discardableResult static func export(
        _ notes: [BrowserNote],
        imageData: (String) -> Data?,
        to directory: URL,
        fileManager: FileManager = .default,
    ) throws -> [URL] {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var used = Set((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
        var written = [URL]()
        for note in notes {
            let name = uniqueName(fileName(for: note.displayTitle), extension: "md", used: &used)
            let file = directory.appendingPathComponent(name)
            var body = note.markdown
            for imageID in note.imageIDs {
                guard let data = imageData(imageID) else { continue }
                let folder = directory.appendingPathComponent(attachmentsFolder, isDirectory: true)
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                let imageFile = folder.appendingPathComponent("\(imageID).\(imageExtension(for: data))")
                try data.write(to: imageFile, options: .atomic)
                body = body.replacingOccurrences(
                    of: "(\(BrowserNoteMarkdownText.imageScheme):\(imageID))",
                    with: "(\(attachmentsFolder)/\(imageFile.lastPathComponent))",
                )
            }
            try document(title: note.displayTitle, body: body).write(to: file, atomically: true, encoding: .utf8)
            try? fileManager.setAttributes(
                [.creationDate: note.createdAt, .modificationDate: note.updatedAt],
                ofItemAtPath: file.path,
            )
            written.append(file)
        }
        return written
    }

    static func document(title: String, body: String) -> String {
        let heading = "# " + title.replacingOccurrences(of: "\n", with: " ")
        return body.isEmpty ? heading + "\n" : heading + "\n\n" + body + (body.hasSuffix("\n") ? "" : "\n")
    }

    /// A file name from a title: no path separators or leading dots, at most 100 characters.
    static func fileName(for title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.newlines).union(.controlCharacters)
        var name = title.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }.joined()
        name = name.trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") {
            name.removeFirst()
        }
        name = String(name.prefix(100)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? BrowserStrings.noteUntitled : name
    }

    // MARK: Private

    private static func uniqueName(_ base: String, extension pathExtension: String, used: inout Set<String>) -> String {
        var candidate = "\(base).\(pathExtension)"
        var number = 2
        while used.contains(candidate) {
            candidate = "\(base) \(number).\(pathExtension)"
            number += 1
        }
        used.insert(candidate)
        return candidate
    }

    private static func imageExtension(for data: Data) -> String {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xFF, 0xD8]) { return "jpg" }
        if bytes.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        return "png"
    }
}

// MARK: - BrowserNotesImport

/// Import Notes: Markdown, text and HTML files, folders of them, and zip
/// archives such as another browser's notes export.
enum BrowserNotesImport {
    // MARK: Internal

    struct ImportedNote: Equatable {
        var title: String
        var markdown: String
        var images = [String: Data]()
        var createdAt: Date?
        var updatedAt: Date?
    }

    static let fileExtensions: Set<String> = ["md", "markdown", "txt", "text", "html", "htm"]

    /// Reads every note in these files, folders and archives.
    @MainActor static func notes(from urls: [URL], fileManager: FileManager = .default) throws -> [ImportedNote] {
        var result = [ImportedNote]()
        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                result += try notes(inDirectory: url, fileManager: fileManager)
            } else if url.pathExtension.lowercased() == "zip" {
                let unpacked = fileManager.temporaryDirectory
                    .appendingPathComponent("OpenArc-Notes-\(UUID().uuidString)", isDirectory: true)
                defer { try? fileManager.removeItem(at: unpacked) }
                try unzip(url, to: unpacked)
                result += try notes(inDirectory: unpacked, fileManager: fileManager)
            } else if fileExtensions.contains(url.pathExtension.lowercased()) {
                if let note = try note(fromFile: url) {
                    result.append(note)
                }
            }
        }
        return result
    }

    /// A Markdown note: the first line's heading is its title, else the file's name.
    static func note(fromMarkdown text: String, fallbackTitle: String, baseURL: URL? = nil) -> ImportedNote {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var title = fallbackTitle
        if let first = lines.first, first.hasPrefix("# ") {
            title = String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            lines.removeFirst()
            if lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                lines.removeFirst()
            }
        }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }
        var markdown = lines.joined(separator: "\n")
        var images = [String: Data]()
        if let baseURL {
            (markdown, images) = embeddingLocalImages(in: markdown, baseURL: baseURL)
        }
        return ImportedNote(title: title, markdown: markdown, images: images)
    }

    /// An HTML note: its `<title>` or first heading names it.
    @MainActor static func note(fromHTML data: Data, fallbackTitle: String) -> ImportedNote? {
        guard let html = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8
                .rawValue],
            documentAttributes: nil,
        ) else { return nil }
        var title = htmlTitle(in: data) ?? ""
        let rich = noteText(fromHTMLText: html)
        var images = [String: Data]()
        let body = NSMutableAttributedString(attributedString: rich)
        // Embedded pictures become the note's images.
        body.enumerateAttribute(.attachment, in: NSRange(location: 0, length: body.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            let data = attachment.fileWrapper?.regularFileContents
                ?? attachment.image.flatMap(BrowserNoteImages.pngData(for:))
            guard let data else { return }
            let id = UUID().uuidString
            images[id] = data
            body.addAttribute(.browserNoteImageID, value: id, range: range)
        }
        var markdown = BrowserNoteMarkdown.markdown(from: body)
        if title.isEmpty || markdown.hasPrefix("# \(title)") {
            let lines = markdown.components(separatedBy: "\n")
            if let first = lines.first, first.hasPrefix("# ") {
                title = title.isEmpty ? String(first.dropFirst(2)) : title
                markdown = lines.dropFirst().drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
                    .joined(separator: "\n")
            }
        }
        markdown = markdown.trimmingCharacters(in: .newlines)
        return ImportedNote(title: title.isEmpty ? fallbackTitle : title, markdown: markdown, images: images)
    }

    /// Rich text from elsewhere in the note's terms: bold, italic, underline,
    /// strikethrough and links stay; large bold text becomes headings and
    /// list paragraphs become list items.
    static func noteText(fromHTMLText text: NSAttributedString) -> NSAttributedString {
        let source = text.string as NSString
        let result = NSMutableAttributedString()
        var location = 0
        while location < source.length {
            let paragraph = source.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            var content = paragraph
            while content.length > 0, [10, 13, 0x2029].contains(source.character(at: NSMaxRange(content) - 1)) {
                content.length -= 1
            }
            let style = text.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
            var block = BrowserNoteBlock.paragraph
            if let lists = style?.textLists, let list = lists.last {
                let level = min(lists.count - 1, BrowserNoteBlock.maximumLevel)
                block = list.isOrdered ? .numbered(level: level) : .bulleted(level: level)
                // Drop the marker the HTML reader put in the text ("\t•\t", "\t1.\t").
                let marker = source.substring(with: content)
                if marker.hasPrefix("\t"), let tab = marker.dropFirst().firstIndex(of: "\t") {
                    let markerLength = marker[...tab].utf16.count
                    content.location += markerLength
                    content.length -= markerLength
                }
            } else if content.length > 0, let font = text.attribute(.font, at: content.location, effectiveRange: nil)
                as? NSFont, font.fontDescriptor.symbolicTraits.contains(.bold)
            {
                block = font.pointSize >= 22 ? .heading(1) : font.pointSize >= 17 ? .heading(2) : font
                    .pointSize >= 14.5 ? .heading(3) : .paragraph
            }
            let line = NSMutableAttributedString()
            text.enumerateAttributes(in: content) { attributes, range, _ in
                var mapped = BrowserNoteTextStyle.attributes(for: block)
                if let font = attributes[.font] as? NSFont {
                    let traits = font.fontDescriptor.symbolicTraits
                    if traits.contains(.bold), block == .paragraph || block.isList {
                        mapped[.browserNoteBold] = true
                    }
                    if traits.contains(.italic) {
                        mapped[.browserNoteItalic] = true
                    }
                }
                for key in [NSAttributedString.Key.underlineStyle, .strikethroughStyle, .link, .attachment] {
                    if let value = attributes[key] {
                        mapped[key] = value
                    }
                }
                // A link's underline is the link's, not the text's.
                if attributes[.link] != nil {
                    mapped.removeValue(forKey: .underlineStyle)
                }
                line.append(NSAttributedString(string: source.substring(with: range), attributes: mapped))
            }
            BrowserNoteFormatting.restyle(line, in: NSRange(location: 0, length: line.length))
            result.append(line)
            if location < source.length {
                result.append(NSAttributedString(string: "\n", attributes: BrowserNoteTextStyle.attributes(for: block)))
            }
        }
        return result
    }

    // MARK: Private

    @MainActor private static func notes(inDirectory directory: URL, fileManager: FileManager) throws
        -> [ImportedNote]
    {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
        ) else { return [] }
        var files = [URL]()
        for case let file as URL in enumerator where fileExtensions.contains(file.pathExtension.lowercased()) {
            files.append(file)
        }
        return try files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .compactMap { try note(fromFile: $0) }
    }

    @MainActor private static func note(fromFile file: URL) throws -> ImportedNote? {
        let data = try Data(contentsOf: file)
        let name = file.deletingPathExtension().lastPathComponent
        let values = try? file.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        var note: ImportedNote?
        switch file.pathExtension.lowercased() {
        case "html", "htm":
            note = Self.note(fromHTML: data, fallbackTitle: name)
        default:
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            else { return nil }
            note = Self.note(fromMarkdown: text, fallbackTitle: name, baseURL: file.deletingLastPathComponent())
        }
        note?.createdAt = values?.creationDate
        note?.updatedAt = values?.contentModificationDate
        return note
    }

    /// Pictures next to a Markdown file become the note's own.
    private static func embeddingLocalImages(in markdown: String, baseURL: URL) -> (String, [String: Data]) {
        guard let regex = try? NSRegularExpression(pattern: "!\\[([^\\]]*)\\]\\(([^)\\s]+)\\)") else {
            return (markdown, [:])
        }
        var result = markdown
        var images = [String: Data]()
        let string = markdown as NSString
        for match in regex.matches(in: markdown, range: NSRange(location: 0, length: string.length)).reversed() {
            let path = string.substring(with: match.range(at: 2))
            guard !path.contains("://"), !path.hasPrefix(BrowserNoteMarkdownText.imageScheme + ":") else { continue }
            let decoded = path.removingPercentEncoding ?? path
            let file = baseURL.appendingPathComponent(decoded).standardizedFileURL
            guard file.path.hasPrefix(baseURL.standardizedFileURL.path), let data = try? Data(contentsOf: file),
                  NSImage(data: data) != nil
            else { continue }
            let id = UUID().uuidString
            images[id] = data
            let replacement = "![](\(BrowserNoteMarkdownText.imageScheme):\(id))"
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return (result, images)
    }

    private static func htmlTitle(in data: Data) -> String? {
        guard let html = String(data: data, encoding: .utf8),
              let start = html.range(of: "<title>", options: .caseInsensitive),
              let end = html.range(of: "</title>", options: .caseInsensitive, range: start.upperBound ..< html.endIndex)
        else { return nil }
        let title = String(html[start.upperBound ..< end.lowerBound])
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private static func unzip(_ archive: URL, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: archive.path])
        }
    }
}

// MARK: - BrowserNotesStore + Transfer

extension BrowserNotesStore {
    /// Adds imported notes and returns how many there were.
    @discardableResult func add(_ imported: [BrowserNotesImport.ImportedNote]) -> Int {
        for note in imported {
            createNote(title: note.title, markdown: note.markdown, images: note.images)
        }
        return imported.count
    }
}
