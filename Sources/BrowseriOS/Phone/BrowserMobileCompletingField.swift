// BrowserMobileCompletingField.swift

import UIKit

/// A text field that fills in the rest of what is being typed and shows that
/// part highlighted, with no caret or selection handles. The next keystroke
/// replaces it, Delete removes it, and Go or a tap keeps it.
final class BrowserMobileCompletingField: UITextField {
    static let completionHighlight = UIColor(red: 0.41, green: 0.51, blue: 1, alpha: 0.3)

    /// The filled-in part after the typed text, while it shows.
    private(set) var completion: String?

    /// Whether the last edit removed text, so the next refresh fills nothing in.
    private(set) var lastEditDeleted = false

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
        let length = typedText.count
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

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        keepCompletion()
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
        var attributes = defaultTextAttributes
        let shown = NSMutableAttributedString(string: typed, attributes: attributes)
        attributes[.backgroundColor] = Self.completionHighlight
        shown.append(NSAttributedString(string: suffix, attributes: attributes))
        attributedText = shown
        completion = suffix
        lastTyped = typed
        if let end = position(from: beginningOfDocument, offset: typed.count) {
            selectedTextRange = textRange(from: end, to: end)
        }
    }

    /// Makes the filled-in part ordinary text, with the caret after it.
    func keepCompletion() {
        guard completion != nil else { return }
        let full = text ?? ""
        completion = nil
        text = full
        lastTyped = full
        selectedTextRange = textRange(from: endOfDocument, to: endOfDocument)
    }

    /// Replaces the whole text, dropping any filled-in part.
    func replaceText(_ newText: String) {
        completion = nil
        text = newText
        lastTyped = newText
    }
}
