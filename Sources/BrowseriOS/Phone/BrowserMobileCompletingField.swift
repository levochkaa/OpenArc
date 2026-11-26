// BrowserMobileCompletingField.swift

import UIKit

/// A text field that fills in the rest of what is being typed and shows that
/// part highlighted, with no caret or selection handles. The next keystroke
/// replaces it, Delete removes it, and Go or a tap keeps it.
///
/// The highlight is a plate behind the text, not an attribute of it, so
/// keeping the filled-in part never rewrites the text: a rewrite under a
/// finger cancels the field's own touch handling, and the press that kept it
/// would then neither move the caret, nor select, nor bring up Paste.
final class BrowserMobileCompletingField: UITextField {
    static let completionHighlight = UIColor(red: 0.41, green: 0.51, blue: 1, alpha: 0.3)

    /// The filled-in part after the typed text, while it shows.
    private(set) var completion: String? {
        didSet {
            guard completion != oldValue else { return }
            completionPlate.isHidden = completion == nil
            setNeedsLayout()
        }
    }

    /// Whether the last edit removed text, so the next refresh fills nothing in.
    private(set) var lastEditDeleted = false

    private let completionPlate = UIView()
    /// The field is putting the filled-in part in, so the selection it sets
    /// is not the person's.
    private var isShowingCompletion = false

    /// The typed text as of the last edit the field accounted for.
    private var lastTyped = ""
    /// Delete was pressed since the last accounted edit.
    private var pressedDelete = false

    /// The text without the filled-in part.
    var typedText: String {
        let full = text ?? ""
        guard let completion, full.hasSuffix(completion) else { return full }
        return String(full.dropLast(completion.count))
    }

    /// Typing goes on at the end of the typed text: nothing is selected and
    /// the caret is there, or the field is not being edited.
    var isTypingAtEnd: Bool {
        guard isEditing, let selection = selectedTextRange else { return true }
        return selection.isEmpty && offset(from: beginningOfDocument, to: selection.start) == typedText.utf16.count
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        completionPlate.backgroundColor = Self.completionHighlight
        completionPlate.isUserInteractionEnabled = false
        completionPlate.isHidden = true
        insertSubview(completionPlate, at: 0)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        sendSubviewToBack(completionPlate)
        layoutCompletionPlate()
    }

    override func insertText(_ text: String) {
        lastEditDeleted = false
        dropCompletion()
        super.insertText(text)
    }

    /// Typing that arrives as a replacement of the caret's empty range, as
    /// synthesized keystrokes do, also replaces the filled-in part.
    override func replace(_ range: UITextRange, withText text: String) {
        guard completion != nil else {
            super.replace(range, withText: text)
            return
        }
        let start = offset(from: beginningOfDocument, to: range.start)
        let end = offset(from: beginningOfDocument, to: range.end)
        lastEditDeleted = false
        dropCompletion()
        let length = typedText.utf16.count
        guard let from = position(from: beginningOfDocument, offset: min(start, length)),
              let to = position(from: beginningOfDocument, offset: min(end, length)),
              let typedRange = textRange(from: from, to: to)
        else {
            super.replace(range, withText: text)
            return
        }
        super.replace(typedRange, withText: text)
    }

    override func deleteBackward() {
        lastEditDeleted = true
        pressedDelete = true
        guard completion != nil else {
            super.deleteBackward()
            return
        }
        dropCompletion()
        sendActions(for: .editingChanged)
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        dropCompletion()
        super.setMarkedText(markedText, selectedRange: selectedRange)
    }

    override func paste(_ sender: Any?) {
        lastEditDeleted = false
        dropCompletion()
        super.paste(sender)
    }

    override func caretRect(for position: UITextPosition) -> CGRect {
        completion == nil ? super.caretRect(for: position) : .zero
    }

    /// A touch keeps the filled-in part as it is and leaves the caret to the
    /// touch: a tap puts it where the finger lands, a hold brings up the
    /// loupe and the menu, a double tap selects a word.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        releaseCompletion()
        super.touchesBegan(touches, with: event)
    }

    @discardableResult override func resignFirstResponder() -> Bool {
        keepCompletion()
        return super.resignFirstResponder()
    }

    /// Accounts for an edit that reached the text directly, as keystrokes
    /// can, past `insertText` and `deleteBackward`: it went in before the
    /// filled-in part. Call on each change of the text, before reading it.
    func noteEdit() {
        let full = text ?? ""
        defer { pressedDelete = false }
        guard let completion else {
            lastEditDeleted = pressedDelete || full.count < lastTyped.count
            lastTyped = full
            return
        }
        guard full.hasSuffix(completion) else {
            self.completion = nil
            lastEditDeleted = pressedDelete || full.count < lastTyped.count
            lastTyped = full
            return
        }
        let typed = String(full.dropLast(completion.count))
        if typed.count < lastTyped.count, lastTyped.hasPrefix(typed) {
            // Delete takes away the filled-in part, not the typed text.
            self.completion = nil
            text = lastTyped
            lastEditDeleted = true
        } else {
            lastEditDeleted = false
            lastTyped = typed
        }
    }

    /// Keeps the filled-in part when the selection moves off the end of the
    /// typed text, as the space bar's trackpad or the arrow keys move it.
    /// Call on each change of the selection.
    func noteSelectionChange() {
        guard completion != nil, !isShowingCompletion, let selection = selectedTextRange else { return }
        let typedEnd = typedText.utf16.count
        guard !selection.isEmpty || offset(from: beginningOfDocument, to: selection.start) != typedEnd else { return }
        releaseCompletion()
    }

    /// Removes the filled-in part, if one shows.
    func dropCompletion() {
        guard completion != nil else { return }
        let typed = typedText
        completion = nil
        text = typed
        lastTyped = typed
    }

    /// Shows `suffix` after `typed`, highlighted.
    func showCompletion(_ suffix: String, after typed: String) {
        guard !suffix.isEmpty else {
            dropCompletion()
            return
        }
        isShowingCompletion = true
        defer { isShowingCompletion = false }
        text = typed + suffix
        completion = suffix
        lastTyped = typed
        if let end = position(from: beginningOfDocument, offset: typed.utf16.count) {
            selectedTextRange = textRange(from: end, to: end)
        }
        layoutIfNeeded()
        layoutCompletionPlate()
    }

    /// Makes the filled-in part ordinary text, with the caret after it.
    func keepCompletion() {
        guard completion != nil else { return }
        releaseCompletion()
        selectedTextRange = textRange(from: endOfDocument, to: endOfDocument)
    }

    /// Replaces the whole text, dropping any filled-in part.
    func replaceText(_ newText: String) {
        completion = nil
        text = newText
        lastTyped = newText
    }

    /// Makes the filled-in part ordinary text without touching the text or
    /// the selection.
    private func releaseCompletion() {
        guard completion != nil else { return }
        completion = nil
        lastTyped = text ?? ""
        // The caret was hidden while the part showed; ask for it again.
        setNeedsLayout()
    }

    /// Puts the plate behind the filled-in part, where the text shows now.
    private func layoutCompletionPlate() {
        guard let completion, let full = text, full.hasSuffix(completion),
              let start = position(from: beginningOfDocument, offset: full.utf16.count - completion.utf16.count),
              let range = textRange(from: start, to: endOfDocument)
        else {
            completionPlate.isHidden = true
            return
        }
        let plate = selectionRects(for: range)
            .map(\.rect)
            .filter { !$0.isEmpty && $0.width.isFinite }
            .reduce(CGRect.null) { $0.union($1) }
        completionPlate.isHidden = plate.isNull
        if !plate.isNull { completionPlate.frame = plate }
    }
}
