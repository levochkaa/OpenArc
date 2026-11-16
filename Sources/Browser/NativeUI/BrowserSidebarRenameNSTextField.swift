// BrowserSidebarRenameNSTextField.swift

import AppKit

// MARK: - BrowserSidebarRenameNSTextField

final class BrowserSidebarRenameNSTextField: NSTextField {
    /// The field sits this much lower than the title and its editor lifts the text back by
    /// the same amount: the text stays where the title drew it, and the selection, which
    /// starts at the field's top and ends below the line, sits evenly around it.
    static let editorLineLift: CGFloat = 1

    // MARK: Internal

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 17)
    }

    var focusPermission: () -> Bool = { true }
    var pendingFocus = false
    var pendingSelectAll = false

    /// The inset of the window's shared field editor before this field changed it;
    /// AppKit sets the editor's size for each field itself.
    private var editorDefaultInset: NSSize?

    // MARK: Private

    private var activeTextColor: NSColor {
        if effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            NSColor.white.withAlphaComponent(0.92)
        } else {
            .labelColor
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        isEditable = true
        isSelectable = true
        font = .systemFont(ofSize: BrowserChromeLayout.sidebarRowFontSize)
        textColor = activeTextColor
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

    override func textDidEndEditing(_ notification: Notification) {
        if let editor = notification.object as? NSTextView, let editorDefaultInset {
            editor.textContainerInset = editorDefaultInset
        }
        editorDefaultInset = nil
        super.textDidEndEditing(notification)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if pendingFocus {
            syncFocus(true)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        keepEditorInsideTitleFrame()
    }

    func syncFocus(_ shouldFocus: Bool) {
        if shouldFocus, !pendingFocus {
            pendingSelectAll = true
        }

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

        rememberEditorDefaults(editor)
        editor.insertionPointColor = activeTextColor
        editor.textColor = activeTextColor
        editor.drawsBackground = false
        editor.font = font
        editor.textContainerInset = NSSize(width: editor.textContainerInset.width, height: 0.5 - Self.editorLineLift)
        keepEditorInsideTitleFrame()
    }

    private func rememberEditorDefaults(_ editor: NSTextView) {
        if editorDefaultInset == nil {
            editorDefaultInset = editor.textContainerInset
        }
    }

    /// AppKit widens the editor 3 pt to the left and 2 pt to the right of the field,
    /// and a title longer than the field scrolls its text into that margin, toward
    /// the icon. The editor keeps the field's frame and starts its text where the
    /// title draws it.
    private func keepEditorInsideTitleFrame() {
        guard let editor = currentEditor() as? NSTextView, let clip = editor.superview as? NSClipView,
              clip.superview === self
        else { return }
        rememberEditorDefaults(editor)
        var frame = clip.frame
        frame.origin.x = bounds.minX
        frame.size.width = bounds.width
        if clip.frame != frame {
            clip.frame = frame
        }
        // A short title's editor fills the field, so nothing scrolls it into the margin.
        if editor.minSize.width < bounds.width {
            editor.minSize.width = bounds.width
            editor.sizeToFit()
        }
        if clip.bounds.minX < 0 {
            clip.setBoundsOrigin(NSPoint(x: 0, y: clip.bounds.minY))
        }
        // The text container starts at the editor's edge, as the title's text starts at the field's.
        if editor.textContainerOrigin.x != 0 {
            editor.textContainerInset.width -= editor.textContainerOrigin.x
        }
    }
}
