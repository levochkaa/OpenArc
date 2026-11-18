// BrowserNoteMarkdown.swift

import AppKit
import Foundation

// MARK: - BrowserNoteBlock

/// What a paragraph of a note is. Every character of a paragraph carries it.
enum BrowserNoteBlock: Hashable {
    case paragraph
    /// Levels 1 to 3.
    case heading(Int)
    case bulleted(level: Int)
    case numbered(level: Int)

    // MARK: Lifecycle

    init(rawValue: String) {
        let parts = rawValue.split(separator: ":")
        let number = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        switch parts.first {
        case "heading": self = .heading(min(max(number, 1), 3))
        case "bulleted": self = .bulleted(level: min(max(number, 0), Self.maximumLevel))
        case "numbered": self = .numbered(level: min(max(number, 0), Self.maximumLevel))
        default: self = .paragraph
        }
    }

    // MARK: Internal

    static let maximumLevel = 5

    var rawValue: String {
        switch self {
        case .paragraph: "paragraph"
        case .heading(let level): "heading:\(level)"
        case .bulleted(let level): "bulleted:\(level)"
        case .numbered(let level): "numbered:\(level)"
        }
    }

    var isList: Bool {
        switch self {
        case .bulleted, .numbered: true
        case .paragraph, .heading: false
        }
    }

    var listLevel: Int {
        switch self {
        case .bulleted(let level), .numbered(let level): level
        case .paragraph, .heading: 0
        }
    }

    /// The same kind of list one level in or out.
    func withListLevel(_ level: Int) -> Self {
        let clamped = min(max(level, 0), Self.maximumLevel)
        return switch self {
        case .bulleted: .bulleted(level: clamped)
        case .numbered: .numbered(level: clamped)
        case .paragraph, .heading: self
        }
    }
}

// MARK: - NSAttributedString.Key + Notes

extension NSAttributedString.Key {
    static let browserNoteBlock = NSAttributedString.Key("OpenArcNoteBlock")
    static let browserNoteBold = NSAttributedString.Key("OpenArcNoteBold")
    static let browserNoteItalic = NSAttributedString.Key("OpenArcNoteItalic")
    static let browserNoteImageID = NSAttributedString.Key("OpenArcNoteImageID")
    /// The number an item of a numbered list shows.
    static let browserNoteListNumber = NSAttributedString.Key("OpenArcNoteListNumber")
}

// MARK: - BrowserNoteTextStyle

/// Fonts, spacing and list indents of the note editor.
enum BrowserNoteTextStyle {
    static let bodySize: CGFloat = 15
    static let lineHeightMultiple: CGFloat = 1.25
    static let listIndent: CGFloat = 24
    static let titleSize: CGFloat = 30
    static let maximumImageWidth: CGFloat = 640

    static func baseFont(for block: BrowserNoteBlock) -> NSFont {
        switch block {
        case .heading(1): .systemFont(ofSize: 26, weight: .bold)
        case .heading(2): .systemFont(ofSize: 21, weight: .bold)
        case .heading: .systemFont(ofSize: 17, weight: .semibold)
        case .paragraph, .bulleted, .numbered: .systemFont(ofSize: bodySize)
        }
    }

    static func font(for block: BrowserNoteBlock, bold: Bool, italic: Bool) -> NSFont {
        var font = baseFont(for: block)
        if bold, !font.fontDescriptor.symbolicTraits.contains(.bold) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        if italic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    static func paragraphStyle(for block: BrowserNoteBlock) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeightMultiple
        switch block {
        case .heading(let level):
            style.paragraphSpacingBefore = level == 1 ? 14 : 10
            style.paragraphSpacing = 4
        case .bulleted(let level), .numbered(let level):
            let indent = listIndent * CGFloat(level + 1)
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            style.paragraphSpacing = 2
        case .paragraph:
            style.paragraphSpacing = 6
        }
        return style
    }

    /// Font, paragraph style and color for a run with these marks.
    static func attributes(for block: BrowserNoteBlock, bold: Bool = false, italic: Bool = false)
        -> [NSAttributedString.Key: Any]
    {
        var attributes: [NSAttributedString.Key: Any] = [
            .browserNoteBlock: block.rawValue,
            .font: font(for: block, bold: bold, italic: italic),
            .paragraphStyle: paragraphStyle(for: block),
            .foregroundColor: NSColor.textColor,
        ]
        if bold {
            attributes[.browserNoteBold] = true
        }
        if italic {
            attributes[.browserNoteItalic] = true
        }
        return attributes
    }

    /// The marker drawn before a list item.
    static func listMarker(for block: BrowserNoteBlock, number: Int) -> String? {
        switch block {
        case .bulleted(let level): ["•", "◦", "▪︎"][level % 3]
        case .numbered(let level):
            level % 3 == 1 ? "\(letters(number))." : level % 3 == 2 ? "\(roman(number))." : "\(number)."
        case .paragraph, .heading: nil
        }
    }

    private static func letters(_ number: Int) -> String {
        var value = max(number, 1)
        var result = ""
        while value > 0 {
            value -= 1
            result = String(UnicodeScalar(UInt8(97 + value % 26))) + result
            value /= 26
        }
        return result
    }

    private static func roman(_ number: Int) -> String {
        let table: [(Int, String)] = [
            (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
            (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i"),
        ]
        var value = min(max(number, 1), 3999)
        var result = ""
        for (amount, letters) in table {
            while value >= amount {
                result += letters
                value -= amount
            }
        }
        return result
    }
}

// MARK: - BrowserNoteInlineMarkdown

/// Emphasis, links and images inside one line of Markdown.
enum BrowserNoteInlineMarkdown {
    // MARK: Internal

    /// The line as rich text: the block's attributes plus the marks.
    /// Images become attachment characters named by `browserNoteImageID`.
    static func attributedString(
        _ line: String,
        block: BrowserNoteBlock = .paragraph,
        image: @escaping (String) -> NSImage? = { _ in nil },
    ) -> NSAttributedString {
        var parser = Parser(characters: Array(line), block: block, image: image)
        parser.parse(until: nil)
        return parser.output
    }

    /// The text of a line without marks, and without images.
    static func plainText(_ line: String) -> String {
        attributedString(line).string.replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    /// One paragraph's rich text as Markdown, without the paragraph's own prefix.
    static func markdown(from text: NSAttributedString) -> String {
        let string = text.string as NSString
        guard string.length > 0 else { return "" }

        struct Mark: Equatable {
            var bold = false
            var italic = false
            var underline = false
            var strike = false
        }

        // Each character's marks; spaces take the marks both neighbors share, so
        // delimiters always touch text.
        var marks = [Mark]()
        var links = [String?]()
        var images = [String?]()
        marks.reserveCapacity(string.length)
        for index in 0 ..< string.length {
            let attributes = text.attributes(at: index, effectiveRange: nil)
            let block = (attributes[.browserNoteBlock] as? String).map(BrowserNoteBlock.init(rawValue:)) ??
                .paragraph
            let isHeading = if case .heading = block { true } else { false }
            marks.append(Mark(
                bold: (attributes[.browserNoteBold] as? Bool ?? false) && !isHeading,
                italic: attributes[.browserNoteItalic] as? Bool ?? false,
                underline: (attributes[.underlineStyle] as? Int ?? 0) != 0,
                strike: (attributes[.strikethroughStyle] as? Int ?? 0) != 0,
            ))
            links.append(linkString(attributes[.link]))
            images.append(attributes[.browserNoteImageID] as? String)
        }
        let characters = Array(text.string.utf16)
        func isSpace(_ index: Int) -> Bool {
            characters[index] == 32 || characters[index] == 9
        }
        var index = 0
        while index < marks.count {
            guard isSpace(index) else {
                index += 1
                continue
            }
            var end = index
            while end < marks.count, isSpace(end) {
                end += 1
            }
            let before = index > 0 ? marks[index - 1] : Mark()
            let after = end < marks.count ? marks[end] : Mark()
            let shared = Mark(
                bold: before.bold && after.bold,
                italic: before.italic && after.italic,
                underline: before.underline && after.underline,
                strike: before.strike && after.strike,
            )
            for space in index ..< end {
                marks[space] = shared
            }
            index = end
        }

        var output = ""
        var open = [String]()
        func close(to depth: Int) {
            while open.count > depth {
                output += closing(open.removeLast())
            }
        }
        func wanted(_ mark: Mark) -> [String] {
            var result = [String]()
            if mark.bold { result.append("**") }
            if mark.italic { result.append("*") }
            if mark.strike { result.append("~~") }
            if mark.underline { result.append("<u>") }
            return result
        }
        func apply(_ mark: Mark) {
            let desired = wanted(mark)
            var keep = 0
            while keep < open.count, keep < desired.count, open[keep] == desired[keep] {
                keep += 1
            }
            // A mark that ends closes those opened after it, which reopen.
            let stillWanted = Set(desired)
            if open.dropFirst(keep).contains(where: { !stillWanted.contains($0) }) || desired.count < open.count {
                close(to: keep)
            }
            for delimiter in desired.dropFirst(open.count) {
                output += delimiter
                open.append(delimiter)
            }
        }

        var position = 0
        while position < marks.count {
            if let imageID = images[position] {
                close(to: 0)
                output += "![](\(BrowserNoteMarkdownText.imageScheme):\(imageID))"
                position += 1
                continue
            }
            if let link = links[position] {
                var end = position
                while end < marks.count, links[end] == link, images[end] == nil {
                    end += 1
                }
                close(to: 0)
                output += "["
                for inner in position ..< end {
                    apply(marks[inner])
                    output += escaped(string.substring(with: NSRange(location: inner, length: 1)), atLineStart: false)
                }
                close(to: 0)
                output += "](\(link.replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: ")", with: "%29")))"
                position = end
                continue
            }
            apply(marks[position])
            let character = string.substring(with: NSRange(location: position, length: 1))
            if character != "\u{FFFC}" {
                output += escaped(character, atLineStart: position == 0)
            }
            position += 1
        }
        close(to: 0)
        return output
    }

    // MARK: Private

    private struct Parser {
        let characters: [Character]
        let block: BrowserNoteBlock
        let image: (String) -> NSImage?
        var index = 0
        var bold = false
        var italic = false
        var underline = false
        var strike = false
        var link: String?
        let output = NSMutableAttributedString()

        init(characters: [Character], block: BrowserNoteBlock, image: @escaping (String) -> NSImage?) {
            self.characters = characters
            self.block = block
            self.image = image
        }

        mutating func parse(until terminator: Character?) {
            while index < characters.count {
                let character = characters[index]
                if let terminator, character == terminator {
                    return
                }
                if character == "\\", index + 1 < characters.count, Self.escapable.contains(characters[index + 1]) {
                    append(String(characters[index + 1]))
                    index += 2
                    continue
                }
                if starts(with: "<u>") {
                    underline = true
                    index += 3
                    continue
                }
                if starts(with: "</u>") {
                    underline = false
                    index += 4
                    continue
                }
                if character == "!", index + 1 < characters.count, characters[index + 1] == "[",
                   parseImage()
                {
                    continue
                }
                if character == "[", parseLink() {
                    continue
                }
                if character == "<", parseAutolink() {
                    continue
                }
                if starts(with: "**") || starts(with: "__") {
                    let delimiter = String(characters[index ..< index + 2])
                    if bold || hasClosing(delimiter, from: index + 2) {
                        bold.toggle()
                        index += 2
                        continue
                    }
                }
                if starts(with: "~~") {
                    if strike || hasClosing("~~", from: index + 2) {
                        strike.toggle()
                        index += 2
                        continue
                    }
                }
                if character == "*" || character == "_" {
                    if italic, closesEmphasis(at: index) {
                        italic = false
                        index += 1
                        continue
                    }
                    if !italic, opensEmphasis(at: index), hasClosing(String(character), from: index + 1) {
                        italic = true
                        index += 1
                        continue
                    }
                }
                append(String(character))
                index += 1
            }
        }

        private static let escapable: Set<Character> = [
            "\\", "*", "_", "~", "[", "]", "(", ")", "<", ">", "#", "-", "+", "!", "`", ".",
        ]

        private func starts(with text: String) -> Bool {
            let needle = Array(text)
            guard index + needle.count <= characters.count else { return false }
            return Array(characters[index ..< index + needle.count]) == needle
        }

        private func hasClosing(_ delimiter: String, from start: Int) -> Bool {
            let needle = Array(delimiter)
            guard start < characters.count, !characters[start].isWhitespace else { return false }
            var position = start + 1
            while position + needle.count <= characters.count {
                if characters[position] == "\\" {
                    position += 2
                    continue
                }
                if Array(characters[position ..< position + needle.count]) == needle,
                   !characters[position - 1].isWhitespace
                {
                    if needle.count == 1, needle[0] == "_" {
                        let next = position + 1
                        if next < characters.count, characters[next].isLetter || characters[next].isNumber {
                            position += 1
                            continue
                        }
                    }
                    return true
                }
                position += 1
            }
            return false
        }

        private func opensEmphasis(at position: Int) -> Bool {
            guard position + 1 < characters.count, !characters[position + 1].isWhitespace else { return false }
            if characters[position] == "_", position > 0 {
                let previous = characters[position - 1]
                return !(previous.isLetter || previous.isNumber)
            }
            return true
        }

        private func closesEmphasis(at position: Int) -> Bool {
            guard position > 0, !characters[position - 1].isWhitespace else { return false }
            if characters[position] == "_", position + 1 < characters.count {
                let next = characters[position + 1]
                return !(next.isLetter || next.isNumber)
            }
            return true
        }

        /// `[text](address)`.
        private mutating func parseLink() -> Bool {
            guard let close = matchingBracket(from: index),
                  close + 1 < characters.count, characters[close + 1] == "(",
                  let end = characters[(close + 2)...].firstIndex(of: ")")
            else { return false }
            let address = String(characters[(close + 2) ..< end]).trimmingCharacters(in: .whitespaces)
            guard !address.isEmpty else { return false }
            let saved = link
            link = address.replacingOccurrences(of: "%20", with: " ").replacingOccurrences(of: "%29", with: ")")
            index += 1
            var inner = Parser(characters: Array(characters[index ..< close]), block: block, image: image)
            inner.bold = bold
            inner.italic = italic
            inner.underline = underline
            inner.strike = strike
            inner.link = link
            inner.parse(until: nil)
            output.append(inner.output)
            link = saved
            index = end + 1
            return true
        }

        /// `![alt](note-image:id)`; another image address becomes a link with its alt text.
        private mutating func parseImage() -> Bool {
            guard let close = matchingBracket(from: index + 1),
                  close + 1 < characters.count, characters[close + 1] == "(",
                  let end = characters[(close + 2)...].firstIndex(of: ")")
            else { return false }
            let alt = String(characters[(index + 2) ..< close])
            let address = String(characters[(close + 2) ..< end]).trimmingCharacters(in: .whitespaces)
            let prefix = BrowserNoteMarkdownText.imageScheme + ":"
            if address.hasPrefix(prefix) {
                let id = String(address.dropFirst(prefix.count))
                let attachment = NSTextAttachment()
                if let picture = image(id) {
                    attachment.image = picture
                    attachment.bounds = BrowserNoteImages.bounds(for: picture.size)
                }
                let attachmentString = NSMutableAttributedString(attachment: attachment)
                attachmentString.addAttributes(
                    BrowserNoteTextStyle.attributes(for: block),
                    range: NSRange(location: 0, length: attachmentString.length),
                )
                attachmentString.addAttribute(
                    .browserNoteImageID,
                    value: id,
                    range: NSRange(location: 0, length: attachmentString.length),
                )
                output.append(attachmentString)
            } else {
                let saved = link
                link = address
                append(alt.isEmpty ? address : alt)
                link = saved
            }
            index = end + 1
            return true
        }

        /// `<https://example.com>`.
        private mutating func parseAutolink() -> Bool {
            guard let end = characters[index...].firstIndex(of: ">") else { return false }
            let address = String(characters[(index + 1) ..< end])
            guard address.contains("://") || address.hasPrefix("mailto:"), !address.contains(" ") else { return false }
            let saved = link
            link = address
            append(address)
            link = saved
            index = end + 1
            return true
        }

        private func matchingBracket(from start: Int) -> Int? {
            var depth = 0
            var position = start
            while position < characters.count {
                switch characters[position] {
                case "\\": position += 1
                case "[": depth += 1
                case "]":
                    depth -= 1
                    if depth == 0 { return position }
                default: break
                }
                position += 1
            }
            return nil
        }

        private func append(_ text: String) {
            var attributes = BrowserNoteTextStyle.attributes(for: block, bold: bold, italic: italic)
            if underline {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if strike {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link, let url = URL(string: link) {
                attributes[.link] = url
            }
            output.append(NSAttributedString(string: text, attributes: attributes))
        }
    }

    private static func closing(_ delimiter: String) -> String {
        delimiter == "<u>" ? "</u>" : delimiter
    }

    private static func linkString(_ value: Any?) -> String? {
        if let url = value as? URL {
            return url.absoluteString
        }
        return value as? String
    }

    private static func escaped(_ character: String, atLineStart: Bool) -> String {
        if ["\\", "*", "_", "~", "[", "]", "<", ">", "`"].contains(character) {
            return "\\" + character
        }
        if atLineStart, ["#", "-", "+"].contains(character) {
            return "\\" + character
        }
        return character
    }
}

// MARK: - BrowserNoteImages

enum BrowserNoteImages {
    /// An image is shown at its size, narrowed to the column.
    static func bounds(for size: CGSize, maximumWidth: CGFloat = BrowserNoteTextStyle.maximumImageWidth) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(1, maximumWidth / size.width)
        return CGRect(x: 0, y: 0, width: floor(size.width * scale), height: floor(size.height * scale))
    }

    /// PNG data for a pasted or dropped image.
    static func pngData(for image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - BrowserNoteMarkdown

/// A note's body as rich text and back. One paragraph is one line.
enum BrowserNoteMarkdown {
    // MARK: Internal

    static func attributedString(
        fromMarkdown markdown: String,
        image: @escaping (String) -> NSImage? = { _ in nil },
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").split(
            separator: "\n",
            omittingEmptySubsequences: false,
        )
        for (index, line) in lines.enumerated() {
            let (block, content) = parseBlock(String(line))
            result.append(BrowserNoteInlineMarkdown.attributedString(content, block: block, image: image))
            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: BrowserNoteTextStyle.attributes(for: block)))
            }
        }
        BrowserNoteFormatting.renumberLists(in: result)
        return result
    }

    /// The text as Markdown, one line per paragraph.
    static func markdown(from text: NSAttributedString) -> String {
        var lines = [String]()
        var counters = [Int](repeating: 0, count: BrowserNoteBlock.maximumLevel + 1)
        let string = text.string as NSString
        var location = 0
        repeat {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            var content = range
            if content.length > 0, string.character(at: NSMaxRange(content) - 1) == 10 {
                content.length -= 1
            }
            let block = BrowserNoteFormatting.block(in: text, at: range.location)
            let inline = BrowserNoteInlineMarkdown.markdown(from: text.attributedSubstring(from: content))
            switch block {
            case .paragraph:
                counters = counters.map { _ in 0 }
                lines.append(escapingListNumber(inline))
            case .heading(let level):
                counters = counters.map { _ in 0 }
                lines.append(String(repeating: "#", count: level) + " " + inline)
            case .bulleted(let level):
                for deeper in (level + 1) ..< counters.count {
                    counters[deeper] = 0
                }
                lines.append(String(repeating: "    ", count: level) + "- " + inline)
            case .numbered(let level):
                for deeper in (level + 1) ..< counters.count {
                    counters[deeper] = 0
                }
                counters[level] += 1
                lines.append(String(repeating: "    ", count: level) + "\(counters[level]). " + inline)
            }
            location = NSMaxRange(range)
        } while location < string.length
        if string.length > 0, string.character(at: string.length - 1) == 10 {
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Text that starts like a numbered item ("1. ") keeps its number as text.
    static func escapingListNumber(_ line: String) -> String {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return line }
        let rest = line.dropFirst(digits.count)
        guard let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().hasPrefix(" ") else { return line }
        return digits + "\\" + rest
    }

    /// A line's block and the text after its prefix.
    static func parseBlock(_ line: String) -> (BrowserNoteBlock, String) {
        var indent = 0
        var rest = Substring(line)
        while let first = rest.first, first == " " || first == "\t" {
            indent += first == "\t" ? 4 : 1
            rest = rest.dropFirst()
        }
        let level = min(Int((Double(indent) / 4).rounded()), BrowserNoteBlock.maximumLevel)
        if indent < 4 {
            for (prefix, level) in [("### ", 3), ("## ", 2), ("# ", 1)] where rest.hasPrefix(prefix) {
                return (.heading(level), String(rest.dropFirst(prefix.count)))
            }
            if rest.hasPrefix("#### ") || rest.hasPrefix("##### ") || rest.hasPrefix("###### ") {
                return (.heading(3), String(rest.drop { $0 == "#" }.dropFirst()))
            }
        }
        for prefix in ["- ", "* ", "+ "] where rest.hasPrefix(prefix) {
            var content = rest.dropFirst(prefix.count)
            // A task item keeps its text; the box is not part of a note.
            for box in ["[ ] ", "[x] ", "[X] "] where content.hasPrefix(box) {
                content = content.dropFirst(box.count)
            }
            return (.bulleted(level: level), String(content))
        }
        if let marker = rest.firstIndex(where: { $0 == "." || $0 == ")" }), !rest[..<marker].isEmpty,
           rest[..<marker].count <= 9, rest[..<marker].allSatisfy(\.isASCII), rest[..<marker].allSatisfy(\.isNumber),
           rest[rest.index(after: marker)...].hasPrefix(" ")
        {
            return (.numbered(level: level), String(rest[rest.index(marker, offsetBy: 2)...]))
        }
        return (.paragraph, indent > 0 && indent < 4 ? String(rest) : line)
    }
}

// MARK: - BrowserNoteFormatting

/// Edits on a note's rich text that the editor, its menus and its Markdown
/// shortcuts share. Each works on any mutable attributed string, so tests run
/// them without a view.
enum BrowserNoteFormatting {
    // MARK: Internal

    enum InlineMark: CaseIterable {
        case bold
        case italic
        case underline
        case strikethrough
    }

    static func block(in text: NSAttributedString, at location: Int) -> BrowserNoteBlock {
        guard text.length > 0 else { return .paragraph }
        let index = min(max(location, 0), text.length - 1)
        return (text.attribute(.browserNoteBlock, at: index, effectiveRange: nil) as? String)
            .map(BrowserNoteBlock.init(rawValue:)) ?? .paragraph
    }

    /// Paragraph ranges, newline included, that touch a range.
    static func paragraphRanges(in text: NSAttributedString, touching range: NSRange) -> [NSRange] {
        let string = text.string as NSString
        guard string.length > 0 else { return [NSRange(location: 0, length: 0)] }
        var ranges = [NSRange]()
        var location = min(range.location, string.length)
        let end = min(NSMaxRange(range), string.length)
        repeat {
            let paragraph = string.paragraphRange(for: NSRange(location: min(location, string.length), length: 0))
            ranges.append(paragraph)
            location = NSMaxRange(paragraph)
        } while location < end
        return ranges
    }

    /// Restores fonts and paragraph styles from the marks, paragraph by
    /// paragraph; a paragraph takes the block of its first character.
    static func restyle(_ text: NSMutableAttributedString, in range: NSRange) {
        guard text.length > 0 else { return }
        for paragraph in paragraphRanges(in: text, touching: range) where paragraph.length > 0 {
            let block = block(in: text, at: paragraph.location)
            text.addAttribute(.browserNoteBlock, value: block.rawValue, range: paragraph)
            text.addAttribute(.paragraphStyle, value: BrowserNoteTextStyle.paragraphStyle(for: block), range: paragraph)
            text.enumerateAttributes(in: paragraph) { attributes, run, _ in
                let bold = attributes[.browserNoteBold] as? Bool ?? false
                let italic = attributes[.browserNoteItalic] as? Bool ?? false
                text.addAttribute(
                    .font,
                    value: BrowserNoteTextStyle.font(for: block, bold: bold, italic: italic),
                    range: run,
                )
                if attributes[.foregroundColor] == nil {
                    text.addAttribute(.foregroundColor, value: NSColor.textColor, range: run)
                }
            }
        }
    }

    /// Gives each numbered item its number: items count up within a level and
    /// start over after a paragraph or heading.
    static func renumberLists(in text: NSMutableAttributedString) {
        var counters = [Int](repeating: 0, count: BrowserNoteBlock.maximumLevel + 1)
        for paragraph in paragraphRanges(in: text, touching: NSRange(location: 0, length: text.length))
            where paragraph.length > 0
        {
            let block = block(in: text, at: paragraph.location)
            switch block {
            case .numbered(let level):
                for deeper in (level + 1) ..< counters.count {
                    counters[deeper] = 0
                }
                counters[level] += 1
                let current = text.attribute(.browserNoteListNumber, at: paragraph.location, effectiveRange: nil) as? Int
                if current != counters[level] {
                    text.addAttribute(.browserNoteListNumber, value: counters[level], range: paragraph)
                }
            case .bulleted(let level):
                for deeper in (level + 1) ..< counters.count {
                    counters[deeper] = 0
                }
                counters[level] = 0
            case .paragraph, .heading:
                counters = counters.map { _ in 0 }
            }
        }
    }

    /// Makes every paragraph the range touches one kind; choosing the kind the
    /// paragraphs already are turns them back into text.
    static func setBlock(_ block: BrowserNoteBlock, in text: NSMutableAttributedString, range: NSRange) {
        let paragraphs = paragraphRanges(in: text, touching: range)
        let toggledOff = paragraphs.allSatisfy { paragraph in
            sameKind(self.block(in: text, at: paragraph.location), block)
        } && block != .paragraph
        for paragraph in paragraphs where paragraph.length > 0 {
            let current = self.block(in: text, at: paragraph.location)
            let target: BrowserNoteBlock = toggledOff ? .paragraph : block.isList && current.isList
                ? block.withListLevel(current.listLevel)
                : block
            text.addAttribute(.browserNoteBlock, value: target.rawValue, range: paragraph)
        }
        restyle(text, in: range)
        renumberLists(in: text)
    }

    /// Moves list items in or out by one level.
    static func indentList(in text: NSMutableAttributedString, range: NSRange, by offset: Int) -> Bool {
        let paragraphs = paragraphRanges(in: text, touching: range).filter { $0.length > 0 }
        guard !paragraphs.isEmpty,
              paragraphs.allSatisfy({ block(in: text, at: $0.location).isList })
        else { return false }
        for paragraph in paragraphs {
            let current = block(in: text, at: paragraph.location)
            text.addAttribute(
                .browserNoteBlock,
                value: current.withListLevel(current.listLevel + offset).rawValue,
                range: paragraph,
            )
        }
        restyle(text, in: range)
        renumberLists(in: text)
        return true
    }

    /// Whether every character in the range has the mark.
    static func hasMark(_ mark: InlineMark, in text: NSAttributedString, range: NSRange) -> Bool {
        guard range.length > 0 else { return false }
        var all = true
        text.enumerateAttribute(key(for: mark), in: range) { value, _, stop in
            if !isOn(value) {
                all = false
                stop.pointee = true
            }
        }
        return all
    }

    /// Adds the mark to the range, or removes it when the whole range has it.
    static func toggleMark(_ mark: InlineMark, in text: NSMutableAttributedString, range: NSRange) {
        guard range.length > 0 else { return }
        let remove = hasMark(mark, in: text, range: range)
        if remove {
            text.removeAttribute(key(for: mark), range: range)
        } else {
            text.addAttribute(key(for: mark), value: value(for: mark), range: range)
        }
        restyle(text, in: range)
    }

    /// The typing attributes with a mark turned on or off.
    static func toggledTypingAttributes(
        _ attributes: [NSAttributedString.Key: Any],
        mark: InlineMark,
    ) -> [NSAttributedString.Key: Any] {
        var result = attributes
        let key = key(for: mark)
        if isOn(attributes[key]) {
            result.removeValue(forKey: key)
        } else {
            result[key] = value(for: mark)
        }
        let block = (result[.browserNoteBlock] as? String).map(BrowserNoteBlock.init(rawValue:)) ?? .paragraph
        result[.font] = BrowserNoteTextStyle.font(
            for: block,
            bold: isOn(result[.browserNoteBold]),
            italic: isOn(result[.browserNoteItalic]),
        )
        return result
    }

    static func setLink(_ url: URL?, in text: NSMutableAttributedString, range: NSRange) {
        guard range.length > 0 else { return }
        if let url {
            text.addAttribute(.link, value: url, range: range)
        } else {
            text.removeAttribute(.link, range: range)
        }
    }

    // MARK: Markdown shortcuts

    /// A change the editor makes after a keystroke: replace a range with
    /// text and put the caret at a location.
    struct ShortcutEdit: Equatable {
        let range: NSRange
        let replacement: NSAttributedString
        let selection: Int
        let block: BrowserNoteBlock?
    }

    /// The block a typed prefix asks for when the user types a space after it
    /// at the start of a paragraph: "#", "##", "###", "-", "*", "1.".
    static func blockShortcut(forPrefix prefix: String, current: BrowserNoteBlock) -> BrowserNoteBlock? {
        switch prefix {
        case "#": return .heading(1)
        case "##": return .heading(2)
        case "###": return .heading(3)
        case "-", "*", "+", "•": return .bulleted(level: current.listLevel)
        default:
            if prefix.count <= 4, prefix.hasSuffix(".") || prefix.hasSuffix(")"),
               prefix.dropLast().allSatisfy(\.isNumber), !prefix.dropLast().isEmpty
            {
                return .numbered(level: current.listLevel)
            }
            return nil
        }
    }

    /// The block a shortcut typed before the caret asks for, if any.
    static func blockShortcutTarget(in text: NSAttributedString, caret: Int) -> BrowserNoteBlock? {
        let string = text.string as NSString
        guard caret > 0, caret <= string.length else { return nil }
        let paragraph = string.paragraphRange(for: NSRange(location: caret - 1, length: 0))
        let typed = string.substring(with: NSRange(location: paragraph.location, length: caret - paragraph.location))
        guard typed.hasSuffix(" ") else { return nil }
        let prefix = String(typed.dropLast())
        guard !prefix.isEmpty, !prefix.contains(" ") else { return nil }
        return blockShortcut(forPrefix: prefix, current: block(in: text, at: paragraph.location))
    }

    /// Applies a block shortcut when the paragraph holding the caret starts with
    /// one and the caret sits right after it. Returns the caret's new location.
    /// An empty last paragraph has no character to hold its block, so the
    /// editor gives it to the typing attributes.
    static func applyBlockShortcut(in text: NSMutableAttributedString, caret: Int) -> Int? {
        guard let target = blockShortcutTarget(in: text, caret: caret) else { return nil }
        let string = text.string as NSString
        let paragraph = string.paragraphRange(for: NSRange(location: caret - 1, length: 0))
        let typed = string.substring(with: NSRange(location: paragraph.location, length: caret - paragraph.location))
        text.replaceCharacters(in: NSRange(location: paragraph.location, length: typed.utf16.count), with: "")
        let updated = (text.string as NSString).paragraphRange(for: NSRange(location: paragraph.location, length: 0))
        if updated.length > 0 {
            text.addAttribute(.browserNoteBlock, value: target.rawValue, range: updated)
            restyle(text, in: updated)
        }
        renumberLists(in: text)
        return paragraph.location
    }

    /// Inline shortcuts, checked after each typed character: `**bold**` and
    /// `*bold*`, `_italic_`, `~~strike~~`, `~strike~` and `-strike-` after a space.
    /// Returns the caret's new location when one applied.
    static func applyInlineShortcut(in text: NSMutableAttributedString, caret: Int) -> Int? {
        let string = text.string as NSString
        guard caret > 1, caret <= string.length else { return nil }
        let paragraph = string.paragraphRange(for: NSRange(location: caret - 1, length: 0))
        let before = string.substring(with: NSRange(location: paragraph.location, length: caret - paragraph.location))
        let rules: [(String, InlineMark, Bool)] = [
            ("**", .bold, false),
            ("~~", .strikethrough, false),
            ("*", .bold, false),
            ("_", .italic, false),
            ("~", .strikethrough, false),
            ("-", .strikethrough, true),
        ]
        for (delimiter, mark, needsSpaceAfter) in rules {
            var candidate = before
            var trailing = ""
            if needsSpaceAfter {
                guard candidate.hasSuffix(" ") else { continue }
                candidate.removeLast()
                trailing = " "
            }
            guard candidate.hasSuffix(delimiter) else { continue }
            let body = candidate.dropLast(delimiter.count)
            guard let open = body.range(of: delimiter, options: .backwards) else { continue }
            let inner = body[open.upperBound...]
            let beforeOpen = body[..<open.lowerBound]
            guard
                !inner.isEmpty, !inner.hasPrefix(" "), !inner.hasSuffix(" "),
                !inner.contains(delimiter),
                beforeOpen.isEmpty || beforeOpen.last?.isWhitespace == true,
                // "**" is not a pair of "*", and "~~" not a pair of "~".
                !(delimiter.count == 1 && (beforeOpen.hasSuffix(delimiter) || inner.hasPrefix(delimiter)))
            else { continue }
            let openLocation = paragraph.location + (beforeOpen as Substring).utf16.count
            let innerLength = (inner as Substring).utf16.count
            let delimiterLength = delimiter.utf16.count
            let innerRange = NSRange(location: openLocation + delimiterLength, length: innerLength)
            let content = NSMutableAttributedString(attributedString: text.attributedSubstring(from: innerRange))
            content.addAttribute(key(for: mark), value: value(for: mark), range: NSRange(
                location: 0,
                length: content.length,
            ))
            restyle(content, in: NSRange(location: 0, length: content.length))
            if !trailing.isEmpty {
                var attributes = text.attributes(at: max(caret - 1, 0), effectiveRange: nil)
                attributes.removeValue(forKey: key(for: mark))
                content.append(NSAttributedString(string: trailing, attributes: attributes))
            }
            let replaced = NSRange(location: openLocation, length: caret - openLocation)
            text.replaceCharacters(in: replaced, with: content)
            return openLocation + content.length
        }
        return nil
    }

    // MARK: Private

    static func sameKind(_ lhs: BrowserNoteBlock, _ rhs: BrowserNoteBlock) -> Bool {
        switch (lhs, rhs) {
        case (.paragraph, .paragraph), (.bulleted, .bulleted), (.numbered, .numbered): true
        case (.heading(let a), .heading(let b)): a == b
        default: false
        }
    }

    private static func key(for mark: InlineMark) -> NSAttributedString.Key {
        switch mark {
        case .bold: .browserNoteBold
        case .italic: .browserNoteItalic
        case .underline: .underlineStyle
        case .strikethrough: .strikethroughStyle
        }
    }

    private static func value(for mark: InlineMark) -> Any {
        switch mark {
        case .bold, .italic: true
        case .underline, .strikethrough: NSUnderlineStyle.single.rawValue
        }
    }

    private static func isOn(_ value: Any?) -> Bool {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? Int {
            return number != 0
        }
        return false
    }
}
