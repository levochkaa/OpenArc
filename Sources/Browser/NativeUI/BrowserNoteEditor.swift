// BrowserNoteEditor.swift

import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - BrowserNoteEditorLayout

enum BrowserNoteEditorLayout {
    /// The text column's widest size; wider pages center it.
    static let columnWidth: CGFloat = 680
    static let minimumSideInset: CGFloat = 40
    static let topInset: CGFloat = 56
    static let titleGap: CGFloat = 14
    static let formatBarHeight: CGFloat = 32
    static let formatButtonWidth: CGFloat = 30
}

// MARK: - BrowserNoteEditorView

/// A note over its tab's page: a title field and the rich text under it, in a
/// centered column. Edits save on their own a moment after typing stops.
final class BrowserNoteEditorView: NSView, NSTextViewDelegate, NSTextFieldDelegate {
    override var isFlipped: Bool { true }

    // MARK: Internal

    let noteID: String
    let textView = BrowserNoteTextView(usingTextLayoutManager: true)
    let titleField = BrowserNoteTitleField()
    let formatBar = BrowserNoteFormatBar()

    /// Asked to open a clicked link: the URL.
    var onOpenLink: (URL) -> Void = { _ in }

    /// Asked to delete the note for good: its ID.
    var onDelete: (String) -> Void = { _ in }

    // MARK: Private

    private weak var store: BrowserNotesStore?
    private var storeCancellable: AnyCancellable?
    private let background = BrowserNativeSurface()
    private let scrollView = NSScrollView()
    private let missingView = BrowserNoteMissingView()
    private lazy var menuButton = BrowserNativeChromeButton(
        symbol: "ellipsis",
        title: BrowserStrings.noteMenuButton,
    ) { [weak self] in self?.showMenu() }

    private let undo = UndoManager()
    private let layoutDelegate = BrowserNoteLayoutDelegate()
    private var saveTimer: Timer?
    private var hasUnsavedText = false
    private var unsavedImages = [String: Data]()
    private var isApplyingEdit = false
    private var lastEdit: (range: NSRange, replacement: String?)?

    var isMissing: Bool {
        store?.note(id: noteID) == nil
    }

    /// The empty paragraph after the last line break, which has no character
    /// to hold its block: the typing attributes hold it.
    private var isAtTrailingParagraph: Bool {
        guard let storage = textView.textStorage else { return false }
        let string = storage.string as NSString
        let selection = textView.selectedRange()
        return selection.length == 0 && selection.location == string.length
            && (string.length == 0 || string.character(at: string.length - 1) == 10)
    }

    private var typingBlock: BrowserNoteBlock {
        (textView.typingAttributes[.browserNoteBlock] as? String).map(BrowserNoteBlock.init(rawValue:)) ?? .paragraph
    }

    init(noteID: String, store: BrowserNotesStore) {
        self.noteID = noteID
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("browser.note.editor")
        buildViews()
        load()
        self.storeCancellable = store.changes
            .filter { [noteID] in $0.noteID == noteID }
            .sink { [weak self] change in self?.storeDidChange(change) }
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit {
        saveTimer?.invalidate()
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        scrollView.frame = bounds
        missingView.frame = bounds
        layoutColumn()
        menuButton.frame = NSRect(x: bounds.width - 44, y: 12, width: 28, height: 28)
        positionFormatBar()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            close()
        }
    }

    /// Puts the keyboard in the note: the title while the note is empty or
    /// when asked, else the text.
    @discardableResult func focus(title: Bool = false) -> Bool {
        guard let window, !isMissing else { return false }
        if title || store?.note(id: noteID)?.isEmpty == true {
            return window.makeFirstResponder(titleField)
        }
        return window.makeFirstResponder(textView)
    }

    /// Focuses the note unless the keyboard is already in it.
    func focusIfOutside() {
        if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: self) {
            return
        }
        focus()
    }

    /// Saves now what a timer would save shortly, and drops images the note
    /// no longer shows.
    func close() {
        saveNow()
        store?.removeUnusedImages(noteID: noteID)
    }

    func saveNow() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard hasUnsavedText, let store, store.note(id: noteID) != nil else { return }
        hasUnsavedText = false
        normalizeAttachments()
        let markdown = BrowserNoteMarkdown.markdown(from: textView.textStorage ?? NSAttributedString())
        let referenced = Set(BrowserNoteMarkdownText.imageIDs(inMarkdown: markdown))
        let images = unsavedImages.filter { referenced.contains($0.key) }
        unsavedImages = unsavedImages.filter { !referenced.contains($0.key) }
        store.update(id: noteID, markdown: markdown, images: images, origin: self)
    }

    /// The note as Markdown, title first.
    func markdownDocument() -> String {
        saveNow()
        guard let note = store?.note(id: noteID) else { return "" }
        return BrowserNotesExport.document(title: note.displayTitle, body: note.markdown)
    }

    // MARK: Formatting

    func toggle(_ mark: BrowserNoteFormatting.InlineMark) {
        let range = textView.selectedRange()
        if range.length == 0 {
            textView.typingAttributes = BrowserNoteFormatting.toggledTypingAttributes(
                textView.typingAttributes,
                mark: mark,
            )
            formatBar.refresh(for: textView)
            return
        }
        edit(range: range) { text in
            BrowserNoteFormatting.toggleMark(mark, in: text, range: range)
            return nil
        }
    }

    func setBlock(_ block: BrowserNoteBlock) {
        let range = textView.selectedRange()
        if isAtTrailingParagraph {
            let current = typingBlock
            let target: BrowserNoteBlock = BrowserNoteFormatting.sameKind(current, block) && block != .paragraph
                ? .paragraph
                : block.isList && current.isList ? block.withListLevel(current.listLevel) : block
            setTypingBlock(target)
            return
        }
        edit(range: range) { text in
            BrowserNoteFormatting.setBlock(block, in: text, range: range)
            return nil
        }
        if let storage = textView.textStorage {
            let current = BrowserNoteFormatting.block(in: storage, at: textView.selectedRange().location)
            textView.typingAttributes = BrowserNoteTextStyle.attributes(for: storage.length == 0 ? block : current)
        }
    }

    /// Asks for an address and links the selection to it.
    func editLink() {
        let range = textView.selectedRange()
        guard range.length > 0, let storage = textView.textStorage, let window else { return }
        let current = storage.attribute(.link, at: range.location, effectiveRange: nil)
        let alert = NSAlert()
        alert.messageText = BrowserStrings.noteLinkPrompt
        alert.addButton(withTitle: BrowserStrings.noteLinkApply)
        alert.addButton(withTitle: BrowserStrings.noteCancelButton)
        if current != nil {
            alert.addButton(withTitle: BrowserStrings.noteLinkRemove)
        }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "https://"
        field.stringValue = (current as? URL)?.absoluteString ?? (current as? String) ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                let typed = field.stringValue.trimmingCharacters(in: .whitespaces)
                let url = URL(string: typed).flatMap { $0.scheme == nil ? URL(string: "https://" + typed) : $0 }
                guard let url, !typed.isEmpty else { return }
                edit(range: range) { text in
                    BrowserNoteFormatting.setLink(url, in: text, range: range)
                    return nil
                }
            case .alertThirdButtonReturn:
                edit(range: range) { text in
                    BrowserNoteFormatting.setLink(nil, in: text, range: range)
                    return nil
                }
            default:
                break
            }
            window.makeFirstResponder(textView)
        }
    }

    // MARK: NSTextViewDelegate

    func textView(
        _: NSTextView,
        shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?,
    ) -> Bool {
        lastEdit = (affectedCharRange, replacementString)
        return true
    }

    func textDidChange(_: Notification) {
        guard !isApplyingEdit else { return }
        if let edit = lastEdit, let storage = textView.textStorage {
            lastEdit = nil
            let caret = textView.selectedRange().location
            // Shortcuts apply after a typed character, never after a paste.
            if let typed = edit.replacement, typed.count == 1, edit.range.length == 0 {
                if typed == " ", let target = BrowserNoteFormatting.blockShortcutTarget(in: storage, caret: caret),
                   applyShortcut({ BrowserNoteFormatting.applyBlockShortcut(in: $0, caret: $1) }, caret: caret)
                {
                    textView.typingAttributes = BrowserNoteTextStyle.attributes(for: target)
                    return
                }
                if ["*", "_", "~", " "].contains(typed),
                   applyShortcut({ BrowserNoteFormatting.applyInlineShortcut(in: $0, caret: $1) }, caret: caret)
                {
                    return
                }
            }
            let length = (edit.replacement as NSString?)?.length ?? 0
            let touched = NSRange(location: min(edit.range.location, storage.length), length: length)
            storage.beginEditing()
            BrowserNoteFormatting.restyle(storage, in: touched)
            BrowserNoteFormatting.renumberLists(in: storage)
            storage.endEditing()
        }
        normalizeAttachments()
        textChanged()
    }

    func textViewDidChangeSelection(_: Notification) {
        positionFormatBar()
    }

    func textView(_: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let storage = textView.textStorage else { return false }
        let selection = textView.selectedRange()
        let trailing = isAtTrailingParagraph
        let paragraph = trailing
            ? NSRange(location: storage.length, length: 0)
            : (storage.string as NSString).paragraphRange(for: NSRange(location: selection.location, length: 0))
        let block = trailing ? typingBlock : BrowserNoteFormatting.block(in: storage, at: paragraph.location)
        let content = paragraphContent(paragraph, in: storage)
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            if block.isList, content.length == 0 {
                // Return on an empty item steps out of the list, one level at a time.
                stepOutOfList(block)
                return true
            }
            if case .heading = block, selection.location == NSMaxRange(content), selection.length == 0 {
                textView.insertNewline(nil)
                let next = (storage.string as NSString).paragraphRange(for: NSRange(
                    location: textView.selectedRange().location,
                    length: 0,
                ))
                if next.length > 0 {
                    storage.addAttribute(.browserNoteBlock, value: BrowserNoteBlock.paragraph.rawValue, range: next)
                    BrowserNoteFormatting.restyle(storage, in: next)
                }
                textView.typingAttributes = BrowserNoteTextStyle.attributes(for: .paragraph)
                return true
            }
            return false
        case #selector(NSResponder.insertBacktab(_:)), #selector(NSResponder.insertTab(_:)):
            guard block.isList else { return false }
            let offset = commandSelector == #selector(NSResponder.insertTab(_:)) ? 1 : -1
            if trailing {
                setTypingBlock(block.withListLevel(block.listLevel + offset))
                return true
            }
            edit(range: selection) { text in
                _ = BrowserNoteFormatting.indentList(in: text, range: selection, by: offset)
                return nil
            }
            return true
        case #selector(NSResponder.deleteBackward(_:)):
            guard selection.length == 0, selection.location == paragraph.location, block != .paragraph else {
                return false
            }
            // Backspace at the start of an item or heading turns it into text first.
            if block.isList {
                stepOutOfList(block)
            } else if trailing {
                setTypingBlock(.paragraph)
            } else {
                setBlock(block)
            }
            return true
        case #selector(NSResponder.moveUp(_:)):
            guard (storage.string as NSString)
                .paragraphRange(for: NSRange(location: selection.location, length: 0))
                .location == 0, isOnFirstLine()
            else { return false }
            window?.makeFirstResponder(titleField)
            return true
        default:
            return false
        }
    }

    func textView(_: NSTextView, clickedOnLink link: Any, at _: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url else { return false }
        onOpenLink(url)
        return true
    }

    func undoManager(for _: NSTextView) -> UndoManager? {
        undo
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_: Notification) {
        store?.update(id: noteID, title: titleField.stringValue, origin: self)
        // A longer title can take another line.
        needsLayout = true
    }

    func control(_: NSControl, textView _: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertTab(_:)),
             #selector(NSResponder.moveDown(_:)):
            window?.makeFirstResponder(textView)
            if commandSelector != #selector(NSResponder.moveDown(_:)) {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            }
            return true
        default:
            return false
        }
    }

    private func buildViews() {
        background.fillColor = BrowserChromeColors.contentBackground
        addSubview(background)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        addSubview(scrollView)

        textView.textLayoutManager?.delegate = layoutDelegate
        textView.delegate = self
        textView.drawsBackground = false
        textView.isRichText = true
        textView.importsGraphics = true
        textView.allowsUndo = true
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        textView.typingAttributes = BrowserNoteTextStyle.attributes(for: .paragraph)
        var placeholderAttributes = BrowserNoteTextStyle.attributes(for: .paragraph)
        placeholderAttributes[.foregroundColor] = NSColor.placeholderTextColor
        textView.placeholder = NSAttributedString(
            string: BrowserStrings.noteBodyPlaceholder,
            attributes: placeholderAttributes,
        )
        textView.editor = self
        textView.setAccessibilityIdentifier("browser.note.text")
        scrollView.documentView = textView

        titleField.delegate = self
        titleField.setAccessibilityIdentifier("browser.note.title")
        textView.addSubview(titleField)

        formatBar.editor = self
        formatBar.isHidden = true
        addSubview(formatBar)

        menuButton.setAccessibilityIdentifier("browser.note.menu")
        addSubview(menuButton)

        missingView.isHidden = true
        addSubview(missingView)
    }

    private func setTypingBlock(_ block: BrowserNoteBlock) {
        textView.typingAttributes = BrowserNoteTextStyle.attributes(for: block)
        textView.needsDisplay = true
        formatBar.refresh(for: textView)
    }

    /// One level out of a list, and out of the list from its first level.
    private func stepOutOfList(_ block: BrowserNoteBlock) {
        let target: BrowserNoteBlock = block.listLevel > 0 ? block.withListLevel(block.listLevel - 1) : .paragraph
        if isAtTrailingParagraph {
            setTypingBlock(target)
            return
        }
        let range = textView.selectedRange()
        edit(range: range) { text in
            if target == .paragraph {
                BrowserNoteFormatting.setBlock(block, in: text, range: range)
            } else {
                _ = BrowserNoteFormatting.indentList(in: text, range: range, by: -1)
            }
            return nil
        }
    }

    private func load() {
        guard let note = store?.note(id: noteID) else {
            missingView.isHidden = false
            scrollView.isHidden = true
            menuButton.isHidden = true
            return
        }
        missingView.isHidden = true
        scrollView.isHidden = false
        menuButton.isHidden = false
        titleField.stringValue = note.title
        let text = BrowserNoteMarkdown.attributedString(fromMarkdown: note.markdown) { [weak store] id in
            store?.imageData(id: id).flatMap(NSImage.init(data:))
        }
        isApplyingEdit = true
        textView.textStorage?.setAttributedString(text)
        isApplyingEdit = false
        if let storage = textView.textStorage, storage.length > 0 {
            textView.typingAttributes = storage.attributes(at: storage.length - 1, effectiveRange: nil)
                .filter { $0.key != .attachment && $0.key != .browserNoteImageID && $0.key != .link }
        }
        undo.removeAllActions()
        needsLayout = true
    }

    private func storeDidChange(_ change: BrowserNotesStore.Change) {
        switch change.kind {
        case .deleted:
            saveTimer?.invalidate()
            hasUnsavedText = false
            load()
        case .created, .updated:
            // Another window's editor changed it.
            guard change.origin != ObjectIdentifier(self), let note = store?.note(id: noteID) else { return }
            if titleField.stringValue != note.title, window?.firstResponder !== titleField.currentEditor() {
                titleField.stringValue = note.title
            }
            if !hasUnsavedText,
               BrowserNoteMarkdown.markdown(from: textView.textStorage ?? NSAttributedString()) != note.markdown
            {
                let selection = textView.selectedRange()
                load()
                let length = textView.textStorage?.length ?? 0
                textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            }
        }
    }

    private func textChanged() {
        hasUnsavedText = true
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        positionFormatBar()
        needsLayout = true
    }

    /// Runs an edit on a copy of the text and puts the changed paragraphs back
    /// as one undoable change. The closure returns where the caret goes.
    private func edit(range: NSRange, _ change: (NSMutableAttributedString) -> Int?) {
        guard let storage = textView.textStorage else { return }
        let copy = NSMutableAttributedString(attributedString: storage)
        let newCaret = change(copy)
        BrowserNoteFormatting.renumberLists(in: copy)
        let lengthChange = copy.length - storage.length
        // Paragraphs touched, widened to the whole text when numbering moved.
        var affected = BrowserNoteFormatting.paragraphRanges(in: storage, touching: range)
            .reduce(NSRange(location: min(range.location, storage.length), length: 0)) { NSUnionRange($0, $1) }
        if affected.length + lengthChange < 0 || numberingChanged(storage, copy, outside: affected, by: lengthChange) {
            affected = NSRange(location: 0, length: storage.length)
        }
        let replacementRange = NSRange(location: affected.location, length: affected.length + lengthChange)
        guard replacementRange.length >= 0, NSMaxRange(replacementRange) <= copy.length else { return }
        let replacement = copy.attributedSubstring(from: replacementRange)
        let selection = textView.selectedRange()
        guard textView.shouldChangeText(in: affected, replacementString: replacement.string) else { return }
        isApplyingEdit = true
        storage.beginEditing()
        storage.replaceCharacters(in: affected, with: replacement)
        storage.endEditing()
        textView.didChangeText()
        isApplyingEdit = false
        if let newCaret {
            textView.setSelectedRange(NSRange(location: min(newCaret, storage.length), length: 0))
        } else if lengthChange == 0 {
            textView.setSelectedRange(selection)
        }
        textChanged()
        formatBar.refresh(for: textView)
    }

    private func applyShortcut(_ shortcut: (NSMutableAttributedString, Int) -> Int?, caret: Int) -> Bool {
        guard let storage = textView.textStorage else { return false }
        let probe = NSMutableAttributedString(attributedString: storage)
        guard shortcut(probe, caret) != nil else { return false }
        let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(
            location: max(caret - 1, 0),
            length: 0,
        ))
        edit(range: paragraph) { text in shortcut(text, caret) }
        if let storage = textView.textStorage {
            let location = textView.selectedRange().location
            let block = BrowserNoteFormatting.block(in: storage, at: max(min(location, storage.length) - 1, 0))
            var attributes = BrowserNoteTextStyle.attributes(for: storage.length == 0 ? .paragraph : block)
            if location > 0, location <= storage.length {
                let previous = storage.attributes(at: location - 1, effectiveRange: nil)
                for key in [NSAttributedString.Key.browserNoteBold, .browserNoteItalic] where previous[key] != nil {
                    // Text typed after a shortcut's closing mark is plain again.
                    attributes.removeValue(forKey: key)
                }
            }
            textView.typingAttributes = attributes
        }
        return true
    }

    private func numberingChanged(
        _ old: NSAttributedString,
        _ new: NSAttributedString,
        outside range: NSRange,
        by lengthChange: Int,
    ) -> Bool {
        var changed = false
        old.enumerateAttribute(.browserNoteListNumber, in: NSRange(
            location: 0,
            length: old.length,
        )) { value, run, stop in
            guard NSIntersectionRange(run, range).length == 0 || run.location >= NSMaxRange(range) else { return }
            let location = run.location >= NSMaxRange(range) ? run.location + lengthChange : run.location
            guard location >= 0, location < new.length else { return }
            if (new.attribute(.browserNoteListNumber, at: location, effectiveRange: nil) as? Int) != value as? Int {
                changed = true
                stop.pointee = true
            }
        }
        return changed
    }

    private func paragraphContent(_ paragraph: NSRange, in text: NSAttributedString) -> NSRange {
        var content = paragraph
        if content.length > 0, (text.string as NSString).character(at: NSMaxRange(content) - 1) == 10 {
            content.length -= 1
        }
        return content
    }

    private func isOnFirstLine() -> Bool {
        guard let manager = textView.textLayoutManager,
              let first = manager.textLayoutFragment(for: manager.documentRange.location),
              let line = first.textLineFragments.first
        else { return true }
        let caret = textView.selectedRange().location
        return caret <= line.characterRange.length
    }

    /// Gives pasted and dropped pictures an ID, the note's size and its data.
    private func normalizeAttachments() {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let width = min(
            textView.textContainer?.size.width ?? BrowserNoteTextStyle.maximumImageWidth,
            BrowserNoteTextStyle
                .maximumImageWidth,
        )
        var updates = [(NSRange, String, NSImage?)]()
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            if storage.attribute(.browserNoteImageID, at: range.location, effectiveRange: nil) != nil { return }
            let data = attachment.fileWrapper?.regularFileContents ?? attachment.contents
            let image = attachment.image ?? data.flatMap(NSImage.init(data:))
            guard let image, let png = data.flatMap({ NSImage(data: $0) != nil ? $0 : nil })
                ?? BrowserNoteImages.pngData(for: image)
            else { return }
            let id = UUID().uuidString
            unsavedImages[id] = png
            updates.append((range, id, image))
        }
        guard !updates.isEmpty else { return }
        storage.beginEditing()
        for (range, id, image) in updates {
            let attachment = NSTextAttachment()
            attachment.image = image
            if let image {
                attachment.bounds = BrowserNoteImages.bounds(for: image.size, maximumWidth: width)
            }
            let block = BrowserNoteFormatting.block(in: storage, at: range.location)
            var attributes = BrowserNoteTextStyle.attributes(for: block)
            attributes[.attachment] = attachment
            attributes[.browserNoteImageID] = id
            storage.setAttributes(attributes, range: range)
        }
        storage.endEditing()
        hasUnsavedText = true
    }

    private func layoutColumn() {
        let width = scrollView.contentSize.width
        let side = max(BrowserNoteEditorLayout.minimumSideInset, (width - BrowserNoteEditorLayout.columnWidth) / 2)
        let columnWidth = max(width - side * 2, 100)
        let titleHeight = ceil(titleField.fittingHeight(width: columnWidth))
        let inset = NSSize(
            width: side,
            height: BrowserNoteEditorLayout.topInset + titleHeight + BrowserNoteEditorLayout.titleGap,
        )
        if textView.textContainerInset != inset {
            textView.textContainerInset = inset
        }
        textView.frame.size.width = width
        if textView.frame.height < scrollView.contentSize.height {
            textView.frame.size.height = scrollView.contentSize.height
        }
        titleField.frame = NSRect(x: side, y: BrowserNoteEditorLayout.topInset, width: columnWidth, height: titleHeight)
    }

    private func positionFormatBar() {
        let selection = textView.selectedRange()
        guard selection.length > 0, window?.firstResponder === textView,
              let rect = selectionRect(for: selection)
        else {
            formatBar.isHidden = true
            return
        }
        formatBar.refresh(for: textView)
        let size = formatBar.fittingSize
        let inSelf = convert(rect, from: textView)
        var origin = NSPoint(x: inSelf.midX - size.width / 2, y: inSelf.minY - size.height - 8)
        // Below the selection when above it would cover the title.
        let titleBottom = convert(titleField.frame, from: textView).maxY
        if origin.y < max(8, titleBottom + 4) {
            origin.y = inSelf.maxY + 8
        }
        origin.x = min(max(origin.x, 8), max(bounds.width - size.width - 8, 8))
        formatBar.frame = NSRect(origin: origin, size: size)
        formatBar.isHidden = false
    }

    private func selectionRect(for range: NSRange) -> NSRect? {
        guard let manager = textView.textLayoutManager, let content = manager.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end)
        else { return nil }
        var union: NSRect?
        manager.enumerateTextSegments(in: textRange, type: .selection, options: []) { _, frame, _, _ in
            union = union.map { $0.union(frame) } ?? frame
            return true
        }
        guard var rect = union else { return nil }
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        return rect
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(BrowserNativeMenuItem(BrowserStrings.noteCopyMarkdown) { [weak self] in
            guard let self else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(markdownDocument(), forType: .string)
        })
        menu.addItem(BrowserNativeMenuItem(BrowserStrings.noteExportMarkdown) { [weak self] in
            self?.exportMarkdown()
        })
        menu.addItem(.separator())
        menu.addItem(BrowserNativeMenuItem(BrowserStrings.noteDeleteMenu) { [weak self] in
            self?.confirmDelete()
        })
        menu.popUp(positioning: nil, at: NSPoint(x: menuButton.frame.minX, y: menuButton.frame.maxY + 4), in: self)
    }

    private func exportMarkdown() {
        guard let window, let note = store?.note(id: noteID) else { return }
        saveNow()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = BrowserNotesExport.fileName(for: note.displayTitle) + ".md"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self, let store, let note = store.note(id: noteID)
            else { return }
            let folder = url.deletingLastPathComponent()
            do {
                let written = try BrowserNotesExport.export([note], imageData: store.imageData(id:), to: folder)
                if let file = written.first, file != url {
                    _ = try? FileManager.default.replaceItemAt(url, withItemAt: file)
                }
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    private func confirmDelete() {
        guard let window, let note = store?.note(id: noteID) else { return }
        let alert = NSAlert()
        alert.messageText = String(format: BrowserStrings.noteDeleteConfirmTitle, note.displayTitle)
        alert.informativeText = BrowserStrings.noteDeleteConfirmMessage
        alert.alertStyle = .warning
        alert.addButton(withTitle: BrowserStrings.noteDeleteButton).hasDestructiveAction = true
        alert.addButton(withTitle: BrowserStrings.noteCancelButton)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            onDelete(noteID)
        }
    }
}

// MARK: - BrowserNoteTextView

/// The note's text. It formats with the usual keys, pastes Markdown as rich
/// text, links a selection when an address is pasted over it, and copies
/// Markdown alongside rich text.
final class BrowserNoteTextView: NSTextView {
    // MARK: Internal

    static let markdownType = NSPasteboard.PasteboardType("com.openarc.note.markdown")

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [Self.markdownType] + super.readablePasteboardTypes
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [Self.markdownType, .string] + super.writablePasteboardTypes.filter { $0 != .string }
    }

    weak var editor: BrowserNoteEditorView?
    var placeholder: NSAttributedString?

    /// Where the placeholder sits: the first line, laid out as typed text is.
    private var placeholderRect: NSRect {
        NSRect(
            x: textContainerOrigin.x,
            y: textContainerOrigin.y,
            width: max(bounds.width - textContainerOrigin.x * 2, 1),
            height: (placeholder?.size().height ?? 20) * 2,
        )
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let editor else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (modifiers, key) {
        case ([.command], "b"): editor.toggle(.bold)
        case ([.command], "i"): editor.toggle(.italic)
        case ([.command], "u"): editor.toggle(.underline)
        case ([.command, .shift], "x"): editor.toggle(.strikethrough)
        case ([.command], "k"): editor.editLink()
        case ([.command, .option], "0"): editor.setBlock(.paragraph)
        case ([.command, .option], "1"): editor.setBlock(.heading(1))
        case ([.command, .option], "2"): editor.setBlock(.heading(2))
        case ([.command, .option], "3"): editor.setBlock(.heading(3))
        case ([.command, .shift], "7"): editor.setBlock(.numbered(level: 0))
        case ([.command, .shift], "8"): editor.setBlock(.bulleted(level: 0))
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else { return false }
        let selected = storage.attributedSubstring(from: range)
        switch type {
        case Self.markdownType:
            return pboard.setString(BrowserNoteMarkdown.markdown(from: selected), forType: type)
        case .string:
            return pboard.setString(selected.string.replacingOccurrences(of: "\u{FFFC}", with: ""), forType: type)
        default:
            return super.writeSelection(to: pboard, type: type)
        }
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if let markdown = pasteboard.string(forType: Self.markdownType) {
            insertNoteText(BrowserNoteMarkdown.attributedString(fromMarkdown: markdown))
            return
        }
        let range = selectedRange()
        if range.length > 0, let string = pasteboard.string(forType: .string)?.trimmingCharacters(
            in: .whitespacesAndNewlines,
        ), !string.contains(" "), let url = URL(string: string), url.scheme == "http" || url.scheme == "https" {
            // An address pasted over text links it.
            editor?.linkSelection(to: url)
            return
        }
        if pasteboard.canReadObject(forClasses: [NSImage.self], options: nil),
           pasteboard.string(forType: .string) == nil
        {
            super.paste(sender)
            return
        }
        if let string = pasteboard.string(forType: .string) {
            insertNoteText(BrowserNoteMarkdown.attributedString(fromMarkdown: string))
            return
        }
        super.paste(sender)
    }

    override func pasteAsPlainText(_: Any?) {
        guard let string = NSPasteboard.general.string(forType: .string) else { return }
        insertText(string, replacementRange: selectedRange())
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawPlaceholderIfEmpty()
        drawTrailingListMarker()
    }

    override func didChangeText() {
        super.didChangeText()
        // The placeholder and a trailing item's marker are drawn outside the text.
        setNeedsDisplay(placeholderRect)
        let string = (textStorage?.string ?? "") as NSString
        if string.length <= 1 || string.character(at: string.length - 1) == 10 {
            needsDisplay = true
        }
    }

    /// The title field sits inside the text view, which reports only its text.
    override func accessibilityChildren() -> [Any]? {
        (super.accessibilityChildren() ?? []) + subviews.filter { $0 is BrowserNoteTitleField }
    }

    // MARK: Private

    private func insertNoteText(_ text: NSAttributedString) {
        let range = selectedRange()
        guard let storage = textStorage else { return }
        let block = BrowserNoteFormatting.block(in: storage, at: range.location)
        let insertion = NSMutableAttributedString(attributedString: text)
        // One line keeps the paragraph it lands in.
        if !insertion.string.contains("\n"), insertion.length > 0 {
            insertion.addAttribute(.browserNoteBlock, value: block.rawValue, range: NSRange(
                location: 0,
                length: insertion.length,
            ))
            BrowserNoteFormatting.restyle(insertion, in: NSRange(location: 0, length: insertion.length))
        }
        insertText(insertion, replacementRange: range)
    }

    private func drawPlaceholderIfEmpty() {
        guard let placeholder, (textStorage?.length ?? 0) == 0 else { return }
        placeholder.draw(in: placeholderRect)
    }

    /// A list item with no text yet at the end of the note has no paragraph to
    /// draw its marker, so the view draws it at the caret.
    private func drawTrailingListMarker() {
        guard let storage = textStorage else { return }
        let string = storage.string as NSString
        guard string.length == 0 || string.character(at: string.length - 1) == 10 else { return }
        let block = (typingAttributes[.browserNoteBlock] as? String).map(BrowserNoteBlock.init(rawValue:)) ?? .paragraph
        guard block.isList, selectedRange().location == string.length else { return }
        var number = 1
        if case .numbered = block, string.length > 0 {
            let previous = BrowserNoteFormatting.block(in: storage, at: string.length - 1)
            if previous == block {
                number = (storage.attribute(
                    .browserNoteListNumber,
                    at: string.length - 1,
                    effectiveRange: nil,
                ) as? Int ??
                    0) + 1
            }
        }
        guard let marker = BrowserNoteTextStyle.listMarker(for: block, number: number) else { return }
        var caretRect = NSRect.zero
        if let manager = textLayoutManager {
            manager.enumerateTextSegments(
                in: NSTextRange(location: manager.documentRange.endLocation),
                type: .standard,
                options: [.rangeNotRequired],
            ) { _, frame, _, _ in
                caretRect = frame
                return false
            }
        }
        let font = BrowserNoteTextStyle.baseFont(for: block)
        let markerString = NSAttributedString(string: marker, attributes: [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let indent = BrowserNoteTextStyle.listIndent * CGFloat(block.listLevel + 1)
        let x = textContainerOrigin.x + indent - BrowserNoteLayoutFragment.markerGap - markerString.size().width
        let lineHeight = font.ascender - font.descender + font.leading
        let y = textContainerOrigin.y + caretRect.minY + max(caretRect.height - lineHeight, 0) / 2
        markerString.draw(at: NSPoint(x: x, y: y))
    }
}

// MARK: - BrowserNoteEditorView + Paste

extension BrowserNoteEditorView {
    func linkSelection(to url: URL) {
        let range = textView.selectedRange()
        guard range.length > 0 else { return }
        edit(range: range) { text in
            BrowserNoteFormatting.setLink(url, in: text, range: range)
            return nil
        }
    }
}

// MARK: - BrowserNoteTitleField

final class BrowserNoteTitleField: NSTextField {
    init() {
        super.init(frame: .zero)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        isEditable = true
        isSelectable = true
        usesSingleLineMode = false
        cell?.wraps = true
        cell?.isScrollable = false
        maximumNumberOfLines = 0
        lineBreakMode = .byWordWrapping
        font = .systemFont(ofSize: BrowserNoteTextStyle.titleSize, weight: .bold)
        textColor = .textColor
        placeholderAttributedString = NSAttributedString(
            string: BrowserStrings.noteTitlePlaceholder,
            attributes: [
                .font: NSFont.systemFont(ofSize: BrowserNoteTextStyle.titleSize, weight: .bold),
                .foregroundColor: NSColor.placeholderTextColor,
            ],
        )
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Internal

    func fittingHeight(width: CGFloat) -> CGFloat {
        let text = stringValue.isEmpty ? BrowserStrings.noteTitlePlaceholder : stringValue
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: max(width, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font ?? NSFont.systemFont(ofSize: BrowserNoteTextStyle.titleSize)],
        )
        return max(bounds.height + 4, 38)
    }
}

// MARK: - BrowserNoteFormatBar

/// Shown above selected text: the paragraph kind, emphasis, lists and a link.
final class BrowserNoteFormatBar: BrowserNativeSurface {
    // MARK: Private

    @MainActor private final class Button {
        let view: BrowserNativeChromeButton
        var isOn = false {
            didSet {
                view.layer?.backgroundColor = isOn ? BrowserChromeColors.chromeButtonPressedBackground.cgColor : nil
            }
        }

        init(symbol: String, title: String, identifier: String, action: @escaping () -> Void) {
            self.view = BrowserNativeChromeButton(symbol: symbol, title: title, action: action)
            view.wantsLayer = true
            view.layer?.cornerRadius = 5
            view.setAccessibilityIdentifier("browser.note.format.\(identifier)")
        }
    }

    override var fittingSize: NSSize {
        NSSize(
            width: CGFloat(buttons.count) * BrowserNoteEditorLayout.formatButtonWidth + 8 + 8,
            height: BrowserNoteEditorLayout.formatBarHeight,
        )
    }

    // MARK: Internal

    weak var editor: BrowserNoteEditorView?

    private lazy var buttons: [Button] = [
        Button(symbol: "textformat.size", title: BrowserStrings.noteFormatText, identifier: "paragraph") {
            [weak self] in self?.showParagraphMenu()
        },
        Button(symbol: "bold", title: BrowserStrings.noteFormatBold, identifier: "bold") { [weak self] in
            self?.editor?.toggle(.bold)
        },
        Button(symbol: "italic", title: BrowserStrings.noteFormatItalic, identifier: "italic") { [weak self] in
            self?.editor?.toggle(.italic)
        },
        Button(symbol: "underline", title: BrowserStrings.noteFormatUnderline, identifier: "underline") {
            [weak self] in self?.editor?.toggle(.underline)
        },
        Button(symbol: "strikethrough", title: BrowserStrings.noteFormatStrikethrough, identifier: "strikethrough") {
            [weak self] in self?.editor?.toggle(.strikethrough)
        },
        Button(symbol: "list.bullet", title: BrowserStrings.noteFormatBulletedList, identifier: "bulleted") {
            [weak self] in self?.editor?.setBlock(.bulleted(level: 0))
        },
        Button(symbol: "list.number", title: BrowserStrings.noteFormatNumberedList, identifier: "numbered") {
            [weak self] in self?.editor?.setBlock(.numbered(level: 0))
        },
        Button(symbol: "link", title: BrowserStrings.noteFormatLink, identifier: "link") { [weak self] in
            self?.editor?.editLink()
        },
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fillColor = BrowserChromeColors.commandBarPanelTint
        strokeColor = BrowserChromeColors.commandBarPanelBorder
        cornerRadius = 8
        shadow = {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 8
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
            return shadow
        }()
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityIdentifier("browser.note.format-bar")
        for button in buttons {
            addSubview(button.view)
        }
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    convenience init() {
        self.init(frame: .zero)
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 4
        for (index, button) in buttons.enumerated() {
            if index == 1 || index == 5 || index == 7 {
                x += 4
            }
            button.view.frame = NSRect(x: x, y: 3, width: BrowserNoteEditorLayout.formatButtonWidth - 2, height: 26)
            x += BrowserNoteEditorLayout.formatButtonWidth
        }
    }

    /// Shows which marks the selection has.
    func refresh(for textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        let block = BrowserNoteFormatting.block(in: storage, at: range.location)
        for (index, mark) in [BrowserNoteFormatting.InlineMark.bold, .italic, .underline, .strikethrough].enumerated() {
            buttons[index + 1].isOn = BrowserNoteFormatting.hasMark(mark, in: storage, range: range)
        }
        buttons[5].isOn =
            if case .bulleted = block {
                true
            } else {
                false
            }
        buttons[6].isOn =
            if case .numbered = block {
                true
            } else {
                false
            }
        buttons[7].isOn = range.length > 0 && storage.attribute(.link, at: range.location, effectiveRange: nil) != nil
    }

    private func showParagraphMenu() {
        let menu = NSMenu()
        let items: [(String, BrowserNoteBlock)] = [
            (BrowserStrings.noteFormatText, .paragraph),
            (BrowserStrings.noteFormatHeading1, .heading(1)),
            (BrowserStrings.noteFormatHeading2, .heading(2)),
            (BrowserStrings.noteFormatHeading3, .heading(3)),
        ]
        for (title, block) in items {
            menu.addItem(BrowserNativeMenuItem(title) { [weak self] in self?.editor?.setBlock(block) })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 4, y: bounds.maxY + 2), in: self)
    }
}

// MARK: - BrowserNoteMissingView

/// In place of a note this Mac does not have, as one opened from a synced tab.
final class BrowserNoteMissingView: NSView {
    // MARK: Internal

    override var isFlipped: Bool { true }

    // MARK: Private

    private let title = BrowserNativeControls.label(
        BrowserStrings.noteMissingTitle,
        size: 16,
        weight: .semibold,
        color: BrowserChromeColors.primaryText,
        wraps: true,
    )
    private let message = BrowserNativeControls.label(
        BrowserStrings.noteMissingMessage,
        size: 13,
        color: BrowserChromeColors.secondaryText,
        wraps: true,
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for label in [title, message] {
            label.alignment = .center
            label.maximumNumberOfLines = 0
            addSubview(label)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(BrowserStrings.noteMissingTitle)
        setAccessibilityIdentifier("browser.note.missing")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let width = min(max(bounds.width - 48, 0), 360)
        let x = (bounds.width - width) / 2
        title.frame = NSRect(x: x, y: bounds.midY - 30, width: width, height: 22)
        message.frame = NSRect(x: x, y: bounds.midY - 2, width: width, height: 36)
    }
}

// MARK: - BrowserNoteLayoutFragment

/// A paragraph that draws its list marker in the indent before it.
final class BrowserNoteLayoutFragment: NSTextLayoutFragment {
    static let markerGap: CGFloat = 7

    override var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        if marker != nil {
            bounds = bounds.union(CGRect(x: -indent, y: 0, width: indent, height: 1))
        }
        return bounds
    }

    var marker: NSAttributedString?
    var indent: CGFloat = 0

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        guard let marker, let line = textLineFragments.first else { return }
        let size = marker.size()
        let font = marker.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 15)
        // The line starts where its text does, past the paragraph's indent.
        let textStart = line.typographicBounds.minX + line.glyphOrigin.x
        let baseline = line.typographicBounds.minY + line.glyphOrigin.y
        let origin = CGPoint(
            x: point.x + textStart - Self.markerGap - size.width,
            y: point.y + baseline - font.ascender,
        )
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        marker.draw(at: origin)
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - BrowserNoteLayoutDelegate

/// Gives list paragraphs a fragment that draws their marker.
final class BrowserNoteLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(
        _: NSTextLayoutManager,
        textLayoutFragmentFor _: any NSTextLocation,
        in textElement: NSTextElement,
    ) -> NSTextLayoutFragment {
        let fragment = BrowserNoteLayoutFragment(textElement: textElement, range: textElement.elementRange)
        guard let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 else {
            return fragment
        }
        let text = paragraph.attributedString
        let block = (text.attribute(.browserNoteBlock, at: 0, effectiveRange: nil) as? String)
            .map(BrowserNoteBlock.init(rawValue:)) ?? .paragraph
        guard block.isList else { return fragment }
        let number = text.attribute(.browserNoteListNumber, at: 0, effectiveRange: nil) as? Int ?? 1
        guard let marker = BrowserNoteTextStyle.listMarker(for: block, number: number) else { return fragment }
        fragment.marker = NSAttributedString(string: marker, attributes: [
            .font: BrowserNoteTextStyle.baseFont(for: block),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        fragment.indent = BrowserNoteTextStyle.listIndent * CGFloat(block.listLevel + 1)
        return fragment
    }
}
