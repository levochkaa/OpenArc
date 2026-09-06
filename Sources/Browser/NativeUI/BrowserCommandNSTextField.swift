import AppKit

// MARK: - BrowserCommandNSTextField

final class BrowserCommandNSTextField: NSTextField {
    // MARK: Lifecycle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        isEditable = true
        isSelectable = true
        applyFont()
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
        NSSize(width: NSView.noIntrinsicMetric, height: 28)
    }

    var focusPermission: () -> Bool = { true }
    var selectAllOnFocus = false
    var pendingFocus = false
    var lastFocusRequestID = -1
    var focusSelectionRequestID: Int?
    var committedText = ""
    var previewDisplayText: String?
    var inlineCompletionSuffix: String?

    private(set) var isApplyingPresentation = false

    var fontSize: CGFloat = 22 {
        didSet {
            guard fontSize != oldValue else {
                return
            }

            applyFont()
            applyEditorAppearance()
        }
    }

    var hasSuggestionPreview: Bool {
        guard previewDisplayText != nil else {
            return false
        }

        if let editor = currentEditor() as? NSTextView {
            return editor.string == desiredDisplayText
        }

        return stringValue == desiredDisplayText
    }

    var desiredDisplayText: String {
        previewDisplayText ?? committedText
    }

    var previewSelectionRange: NSRange? {
        guard let previewDisplayText, previewDisplayText != committedText else {
            return nil
        }

        if let inlineCompletionSuffix, !inlineCompletionSuffix.isEmpty {
            return NSRange(
                location: (committedText as NSString).length,
                length: (inlineCompletionSuffix as NSString).length
            )
        }

        return nil
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        applyEditorAppearance()
        return didBecomeFirstResponder
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if pendingFocus {
            syncFocus(true)
        }
    }

    func syncCommandPresentation(
        text: String,
        previewDisplayText: String?,
        inlineCompletionSuffix: String?,
        shouldFocus: Bool,
        focusRequestID: Int,
        fontSize: CGFloat,
        selectAllOnFocus: Bool
    ) {
        self.fontSize = fontSize
        self.selectAllOnFocus = selectAllOnFocus
        collapsePreviewSelection = self.previewDisplayText != nil && previewDisplayText == nil
        committedText = text
        self.previewDisplayText = previewDisplayText
        self.inlineCompletionSuffix = inlineCompletionSuffix
        pendingFocus = shouldFocus
        let shouldForceFocus = focusRequestID != lastFocusRequestID
        if shouldFocus, shouldForceFocus, selectAllOnFocus {
            focusSelectionRequestID = focusRequestID
        }
        lastFocusRequestID = focusRequestID
        syncDisplayedText()
        syncFocus(shouldFocus, force: shouldForceFocus)
    }

    func clearFocusSelectionRequest() {
        focusSelectionRequestID = nil
    }

    // MARK: Private

    private var collapsePreviewSelection = false

    private var activeTextColor: NSColor {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.92)
            : .labelColor
    }

    private func syncFocus(_ shouldFocus: Bool, force: Bool = false) {
        pendingFocus = shouldFocus

        guard let window else {
            return
        }

        let currentEditor = currentEditor()
        let isEditing = window.firstResponder === currentEditor || window.firstResponder === self

        if shouldFocus {
            guard force || !isEditing else {
                syncDisplayedText()
                applyEditorAppearance()
                return
            }

            requestFocusOnNextRunLoop()
            return
        }

        if isEditing {
            window.makeFirstResponder(nil)
        }
    }

    private func requestFocusOnNextRunLoop() {
        DispatchQueue.main.async { [weak self] in
            self?.focusIfPossible()

            DispatchQueue.main.async { [weak self] in
                self?.focusIfPossible()
            }
        }
    }

    private func focusIfPossible() {
        guard window != nil, pendingFocus, focusPermission() else {
            return
        }

        window?.makeKey()
        _ = window?.makeFirstResponder(self)
        syncDisplayedText()
        applyEditorAppearance()
    }

    private func syncDisplayedText() {
        let targetDisplayText = desiredDisplayText
        let targetSelectionRange = fullTextSelectionRange(for: targetDisplayText) ?? previewSelectionRange

        if let editor = currentEditor() as? NSTextView {
            guard !editor.hasMarkedText() else { return }
            let needsStringUpdate = editor.string != targetDisplayText || stringValue != targetDisplayText
            let needsPreviewSelection = targetSelectionRange != nil && editor.selectedRange() != targetSelectionRange
            let needsSelectionCollapse =
                collapsePreviewSelection && targetSelectionRange == nil &&
                editor.string == targetDisplayText &&
                editor.selectedRange().length > 0

            guard needsStringUpdate || needsPreviewSelection || needsSelectionCollapse else {
                collapsePreviewSelection = false
                applyEditorAppearance()
                return
            }

            isApplyingPresentation = true
            stringValue = targetDisplayText
            editor.string = targetDisplayText

            if let targetSelectionRange {
                editor.setSelectedRange(targetSelectionRange)
                focusSelectionRequestID = nil
            } else if needsStringUpdate || needsSelectionCollapse {
                editor.setSelectedRange(
                    NSRange(location: (targetDisplayText as NSString).length, length: 0)
                )
            }

            isApplyingPresentation = false
            collapsePreviewSelection = false
            applyEditorAppearance()
            return
        }

        guard stringValue != targetDisplayText else {
            return
        }

        isApplyingPresentation = true
        stringValue = targetDisplayText
        isApplyingPresentation = false
    }

    private func applyEditorAppearance() {
        guard let editor = currentEditor() as? NSTextView else {
            return
        }

        editor.insertionPointColor = activeTextColor
        editor.textColor = activeTextColor
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: fontSize, weight: .medium)
    }

    private func applyFont() {
        font = .systemFont(ofSize: fontSize, weight: .medium)
    }

    private func fullTextSelectionRange(for text: String) -> NSRange? {
        guard focusSelectionRequestID == lastFocusRequestID else {
            return nil
        }

        return NSRange(location: 0, length: (text as NSString).length)
    }
}
