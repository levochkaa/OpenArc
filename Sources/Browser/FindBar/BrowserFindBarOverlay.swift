import AppKit
import QuartzCore
import SwiftUI

// MARK: - BrowserFindBarOverlay

struct BrowserFindBarOverlay: View {
    @ObservedObject var model: BrowserChromeModel

    let blockedLeadingInset: CGFloat

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: blockedLeadingInset)
                    .allowsHitTesting(false)

                ZStack(alignment: .topTrailing) {
                    if model.isFindBarPresented {
                        BrowserFindBarPanel(model: model)
                            .padding(.top, BrowserChromeLayout.findBarTopInset)
                            .padding(.trailing, BrowserChromeLayout.findBarTrailingInset)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .frame(
                    width: max(proxy.size.width - blockedLeadingInset, 0),
                    height: proxy.size.height,
                    alignment: .topTrailing
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(model.isFindBarPresented)
        .animation(.easeOut(duration: 0.12), value: model.isFindBarPresented)
    }
}

// MARK: - BrowserFindBarPanel

struct BrowserFindBarPanel: View {
    @ObservedObject var model: BrowserChromeModel

    var canStepThroughMatches: Bool {
        model.canStepThroughFindMatches
    }

    var body: some View {
        HStack(spacing: BrowserChromeLayout.findBarContentSpacing) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: BrowserChromeLayout.findBarSymbolSize, weight: .semibold))
                .foregroundStyle(BrowserChromePalette.secondaryText)
                .frame(width: BrowserChromeLayout.commandBarSymbolWidth)

            ZStack(alignment: .leading) {
                if model.findQuery.isEmpty {
                    Text(BrowserStrings.findBarPlaceholder)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(BrowserChromePalette.findBarPlaceholder)
                        .allowsHitTesting(false)
                }

                BrowserFindQueryTextField(
                    text: $model.findQuery,
                    isFocused: model.isFindBarPresented,
                    focusRequestID: model.findBarFocusRequest,
                    onSubmit: model.findNextInPage,
                    onCancel: model.dismissFindBar
                )
            }
            .padding(.horizontal, 8)
            .frame(width: BrowserChromeLayout.findBarFieldWidth)
            .frame(height: BrowserChromeLayout.chromeButtonSize)
            .background(
                RoundedRectangle(cornerRadius: BrowserChromeLayout.findBarFieldCornerRadius, style: .continuous)
                    .fill(BrowserChromePalette.findBarFieldTint)
            )

            BrowserChromeControlButton(
                systemImageName: "chevron.up",
                tooltipTitle: BrowserStrings.findBarPreviousMatch,
                tooltipShortcut: nil,
                isEnabled: canStepThroughMatches,
                pressEffect: .moveUp,
                action: model.findPreviousInPage
            )

            BrowserChromeControlButton(
                systemImageName: "chevron.down",
                tooltipTitle: BrowserStrings.findBarNextMatch,
                tooltipShortcut: nil,
                isEnabled: canStepThroughMatches,
                pressEffect: .moveDown,
                action: model.findNextInPage
            )

            BrowserChromeControlButton(
                systemImageName: "xmark",
                tooltipTitle: BrowserStrings.findBarClose,
                tooltipShortcut: nil,
                pressEffect: .compress,
                action: model.dismissFindBar
            )
        }
        .padding(.horizontal, BrowserChromeLayout.findBarHorizontalPadding)
        .frame(width: BrowserChromeLayout.findBarWidth, height: BrowserChromeLayout.findBarHeight)
        .background(panelBackground)
        .overlay(panelBorder)
        .shadow(color: Color.black.opacity(0.24), radius: 18, y: 8)
    }

    var panelBackground: some View {
        RoundedRectangle(cornerRadius: BrowserChromeLayout.findBarCornerRadius, style: .continuous)
            .fill(BrowserChromePalette.findBarPanelTint)
            .background(
                BrowserVisualEffectView(material: .hudWindow)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: BrowserChromeLayout.findBarCornerRadius,
                            style: .continuous
                        )
                    )
            )
    }

    var panelBorder: some View {
        RoundedRectangle(cornerRadius: BrowserChromeLayout.findBarCornerRadius, style: .continuous)
            .stroke(BrowserChromePalette.findBarPanelBorder, lineWidth: 1)
    }
}

// MARK: - BrowserFindQueryTextField

struct BrowserFindQueryTextField: NSViewRepresentable {
    final class Coordinator: NSObject, NSTextFieldDelegate {
        // MARK: Lifecycle

        init(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.text = text
            self.onSubmit = onSubmit
            self.onCancel = onCancel
        }

        // MARK: Internal

        var text: Binding<String>
        var onSubmit: () -> Void
        var onCancel: () -> Void

        func update(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.text = text
            self.onSubmit = onSubmit
            self.onCancel = onCancel
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? BrowserFindNSTextField else {
                return
            }

            if text.wrappedValue != textField.stringValue {
                text.wrappedValue = textField.stringValue
            }
        }

        func control(_: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                onCancel()
                return true
            case #selector(NSResponder.selectAll(_:)):
                textView.selectAll(nil)
                return true
            default:
                return false
            }
        }
    }

    @Binding var text: String

    let isFocused: Bool
    let focusRequestID: Int
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> BrowserFindNSTextField {
        let textField = BrowserFindNSTextField()
        textField.delegate = context.coordinator
        textField.stringValue = text
        return textField
    }

    func updateNSView(_ nsView: BrowserFindNSTextField, context: Context) {
        context.coordinator.update(text: $text, onSubmit: onSubmit, onCancel: onCancel)
        nsView.sync(text: text, shouldFocus: isFocused, focusRequestID: focusRequestID)
    }
}

// MARK: - BrowserFindNSTextField

final class BrowserFindNSTextField: NSTextField {
    // MARK: Lifecycle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        isEditable = true
        isSelectable = true
        font = .systemFont(ofSize: 13, weight: .medium)
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
        NSSize(width: NSView.noIntrinsicMetric, height: 18)
    }

    var pendingFocus = false
    var pendingSelectAll = false
    var lastFocusRequestID = 0

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

    // MARK: Private

    private var activeTextColor: NSColor {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.92)
            : .labelColor
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
        editor.font = .systemFont(ofSize: 13, weight: .medium)
        editor.textContainerInset = NSSize(width: 0, height: 1)
    }
}
