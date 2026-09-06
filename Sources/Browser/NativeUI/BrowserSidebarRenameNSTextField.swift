import AppKit

// MARK: - BrowserSidebarRenameNSTextField

final class BrowserSidebarRenameNSTextField: NSTextField {
    // MARK: Lifecycle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        isEditable = true
        isSelectable = true
        font = .systemFont(ofSize: 12.5, weight: .medium)
        textColor = activeTextColor
        cell?.usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
        cell?.lineBreakMode = .byClipping
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Internal

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 17)
    }

    var focusPermission: () -> Bool = { true }
    var pendingFocus = false
    var pendingSelectAll = false

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

    // MARK: Private

    private var activeTextColor: NSColor {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.92)
            : .labelColor
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

        editor.insertionPointColor = activeTextColor
        editor.textColor = activeTextColor
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 12.5, weight: .medium)
        editor.textContainerInset = NSSize(width: 0, height: 0.5)
    }
}
