// BrowserFindNSTextField.swift

import AppKit

// MARK: - BrowserFindNSTextField

final class BrowserFindNSTextField: NSTextField {
    // MARK: Internal

    static let textFont = NSFont.systemFont(ofSize: 13)

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 18)
    }

    var focusPermission: () -> Bool = { true }
    var pendingFocus = false
    var pendingSelectAll = false
    var lastFocusRequestID = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        isEditable = true
        isSelectable = true
        font = Self.textFont
        textColor = BrowserChromeColors.findBarText
        cell?.usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
        cell?.lineBreakMode = .byClipping
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        applyEditorAppearance()
        selectAllTextIfNeeded()
        return didBecomeFirstResponder
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if pendingFocus {
            syncFocus(true)
        }
    }

    func sync(text: String, shouldFocus: Bool, focusRequestID: Int) {
        if stringValue != text {
            stringValue = text
        }

        if focusRequestID != lastFocusRequestID {
            lastFocusRequestID = focusRequestID
            pendingSelectAll = shouldFocus
        }

        if shouldFocus, !pendingFocus {
            pendingSelectAll = true
        }

        pendingFocus = shouldFocus
        syncFocus(shouldFocus)
    }

    private func syncFocus(_ shouldFocus: Bool) {
        pendingFocus = shouldFocus

        guard let window else {
            return
        }

        let currentEditor = currentEditor()
        let isEditing = window.firstResponder === currentEditor || window.firstResponder === self

        if shouldFocus {
            guard !isEditing else {
                applyEditorAppearance()
                selectAllTextIfNeeded()
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, pendingFocus, focusPermission() else {
                    return
                }

                _ = self.window?.makeFirstResponder(self)
                applyEditorAppearance()
                selectAllTextIfNeeded()
            }
            return
        }

        pendingSelectAll = false

        if isEditing {
            window.makeFirstResponder(nil)
        }
    }

    private func selectAllTextIfNeeded() {
        guard pendingSelectAll else {
            return
        }

        if let editor = currentEditor() as? NSTextView {
            editor.selectAll(nil)
            pendingSelectAll = false
            return
        }

        if window?.firstResponder === self {
            selectText(nil)
            pendingSelectAll = false
        }
    }

    private func applyEditorAppearance() {
        guard let editor = currentEditor() as? NSTextView else {
            return
        }

        editor.insertionPointColor = .controlAccentColor
        editor.textColor = BrowserChromeColors.findBarText
        editor.drawsBackground = false
        editor.font = Self.textFont
        editor.textContainerInset = NSSize(width: 0, height: 1)
    }
}
