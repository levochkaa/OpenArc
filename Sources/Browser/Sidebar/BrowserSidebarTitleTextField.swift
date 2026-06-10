import AppKit
import QuartzCore
import SwiftUI

// MARK: - BrowserSidebarTitleTextField

struct BrowserSidebarTitleTextField: NSViewRepresentable {
    final class Coordinator: NSObject, NSTextFieldDelegate {
        // MARK: Lifecycle

        init(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void,
            onBlur: @escaping () -> Void
        ) {
            self.text = text
            self.onSubmit = onSubmit
            self.onCancel = onCancel
            self.onBlur = onBlur
        }

        // MARK: Internal

        var text: Binding<String>
        var onSubmit: () -> Void
        var onCancel: () -> Void
        var onBlur: () -> Void
        var suppressesNextBlur = false

        func update(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void,
            onBlur: @escaping () -> Void
        ) {
            self.text = text
            self.onSubmit = onSubmit
            self.onCancel = onCancel
            self.onBlur = onBlur
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else {
                return
            }

            if text.wrappedValue != textField.stringValue {
                text.wrappedValue = textField.stringValue
            }
        }

        func controlTextDidEndEditing(_: Notification) {
            if suppressesNextBlur {
                suppressesNextBlur = false
                return
            }

            onBlur()
        }

        func control(_: NSControl, textView _: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                suppressesNextBlur = true
                onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                suppressesNextBlur = true
                onCancel()
                return true
            default:
                return false
            }
        }
    }

    @Binding var text: String

    let isFocused: Bool
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onBlur: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onCancel: onCancel, onBlur: onBlur)
    }

    func makeNSView(context: Context) -> BrowserSidebarRenameNSTextField {
        let textField = BrowserSidebarRenameNSTextField()
        textField.delegate = context.coordinator
        textField.stringValue = text
        return textField
    }

    func updateNSView(_ nsView: BrowserSidebarRenameNSTextField, context: Context) {
        context.coordinator.update(text: $text, onSubmit: onSubmit, onCancel: onCancel, onBlur: onBlur)

        if nsView.stringValue != text {
            nsView.stringValue = text
        }

        nsView.syncFocus(isFocused)
    }
}

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
                guard let self, self.window != nil, pendingFocus else {
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
