import AppKit
import QuartzCore
import SwiftUI

// MARK: - BrowserCommandBarOverlayStyle

enum BrowserCommandBarOverlayStyle {
    case standard
    case compact(anchorFrame: CGRect?, sidebarWidth: CGFloat, matchesAnchorWidth: Bool)

    // MARK: Internal

    var fontSize: CGFloat {
        switch self {
        case .standard:
            22
        case .compact:
            BrowserChromeLayout.compactCommandBarFontSize
        }
    }

    var symbolSize: CGFloat {
        switch self {
        case .standard:
            BrowserChromeLayout.commandBarSymbolSize
        case .compact:
            BrowserChromeLayout.compactCommandBarSymbolSize
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .standard:
            BrowserChromeLayout.commandBarCornerRadius
        case .compact:
            BrowserChromeLayout.compactCommandBarCornerRadius
        }
    }

    var fieldHeight: CGFloat {
        switch self {
        case .standard:
            BrowserChromeLayout.commandBarFieldHeight
        case .compact:
            BrowserChromeLayout.compactCommandBarFieldHeight
        }
    }

    var textFieldVerticalOffset: CGFloat {
        switch self {
        case .standard:
            0
        case .compact:
            BrowserChromeLayout.compactCommandBarTextFieldVerticalOffset
        }
    }

    var selectsTextOnFocus: Bool {
        switch self {
        case .standard:
            false
        case .compact:
            true
        }
    }
}

// MARK: - BrowserCommandBarTextWidthMeasurer

enum BrowserCommandBarTextWidthMeasurer {
    static func width(for text: String, fontSize: CGFloat) -> CGFloat {
        let measuredText = text.isEmpty ? BrowserStrings.commandBarPlaceholder : text
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
        ]

        return ceil((measuredText as NSString).size(withAttributes: attributes).width)
    }
}

// MARK: - BrowserCommandBarFaviconCandidate

struct BrowserCommandBarFaviconCandidate: Equatable {
    // MARK: Lifecycle

    init(tab: BrowserChromeModel.Tab) {
        self.pageURLString = tab.urlString
        self.faviconURL = tab.faviconURL
    }

    // MARK: Internal

    let pageURLString: String
    let faviconURL: URL?

    func faviconURL(for suggestion: BrowserCommandSuggestion?) -> URL? {
        guard
            let suggestion,
            suggestion.kind == .url,
            Self.matchesPageURL(suggestion.resolvedURLString, pageURLString)
        else {
            return nil
        }

        return faviconURL
    }

    // MARK: Private

    private static func matchesPageURL(_ lhs: String, _ rhs: String) -> Bool {
        normalizedPageURLString(lhs) == normalizedPageURLString(rhs)
    }

    private static func normalizedPageURLString(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString) else {
            return urlString
        }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path == "/" {
            components.path = ""
        }

        return components.url?.absoluteString ?? urlString
    }
}

// MARK: - BrowserCommandBarOverlay

struct BrowserCommandBarOverlay: View {
    // MARK: Internal

    @EnvironmentObject var faviconCache: BrowserFaviconCache
    @ObservedObject var model: BrowserCommandBarModel

    let blockedLeadingInset: CGFloat
    let style: BrowserCommandBarOverlayStyle
    let faviconCandidate: BrowserCommandBarFaviconCandidate?

    var leadingSymbolName: String {
        model.selectedSuggestion?.systemImageName ?? "magnifyingglass"
    }

    var cachedLeadingFavicon: NSImage? {
        faviconCache.image(for: faviconCandidate?.faviconURL(for: model.selectedSuggestion))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if model.isPresented {
                    dismissLayer(in: proxy.size)

                    panel
                        .frame(width: panelWidth(in: proxy.size), alignment: .top)
                        .background(panelBackground)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: style.cornerRadius,
                                style: .continuous
                            )
                        )
                        .overlay(panelBorder)
                        .shadow(
                            color: Color.black.opacity(0.38),
                            radius: BrowserChromeLayout.commandBarShadowRadius,
                            y: 18
                        )
                        .offset(panelOffset(in: proxy.size))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(model.isPresented)
    }

    var panel: some View {
        VStack(spacing: 0) {
            inputField

            if !model.suggestions.isEmpty {
                Rectangle()
                    .fill(BrowserChromePalette.commandBarPanelBorder)
                    .frame(height: 1)
                    .padding(.horizontal, BrowserChromeLayout.commandBarOuterPadding)

                BrowserCommandSuggestionList(
                    model: model,
                    faviconCandidate: faviconCandidate
                )
                .padding(.horizontal, BrowserChromeLayout.commandBarOuterPadding)
            }
        }
        .padding(.horizontal, BrowserChromeLayout.commandBarOuterPadding)
        .padding(.top, BrowserChromeLayout.commandBarOuterPadding)
        .padding(.bottom, model.suggestions.isEmpty ? BrowserChromeLayout.commandBarOuterPadding : 0)
    }

    var inputField: some View {
        HStack(spacing: BrowserChromeLayout.commandBarRowContentSpacing) {
            leadingIcon
                .frame(width: BrowserChromeLayout.commandBarSymbolWidth)

            ZStack(alignment: .leading) {
                if model.query.isEmpty {
                    Text(BrowserStrings.commandBarPlaceholder)
                        .font(.system(size: style.fontSize, weight: .medium))
                        .foregroundStyle(BrowserChromePalette.commandBarPlaceholder)
                        .allowsHitTesting(false)
                }

                BrowserCommandQueryTextField(
                    text: Binding(
                        get: { model.query },
                        set: { model.query = $0 }
                    ),
                    previewDisplayText: model.previewDisplayText,
                    inlineCompletionSuffix: model.inlineCompletionSuffix,
                    isFocused: model.isPresented,
                    focusRequestID: model.focusRequestID,
                    fontSize: style.fontSize,
                    selectAllOnFocus: style.selectsTextOnFocus,
                    onMoveUp: { model.moveSelection(by: -1) },
                    onMoveDown: { model.moveSelection(by: 1) },
                    onAcceptCompletion: { _ = model.acceptSelectedSuggestion() },
                    onSubmit: { model.submitSelection() },
                    onDismiss: { model.dismiss() }
                )
                .offset(y: style.textFieldVerticalOffset)
            }
        }
        .padding(
            .horizontal,
            BrowserChromeLayout.commandBarRowHorizontalPadding + BrowserChromeLayout.commandBarOuterPadding
        )
        .padding(.vertical, BrowserChromeLayout.commandBarRowVerticalPadding)
        .frame(minHeight: style.fieldHeight)
    }

    var panelBackground: some View {
        RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
            .fill(BrowserChromePalette.commandBarPanelTint)
            .background(
                BrowserVisualEffectView(material: .hudWindow)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: style.cornerRadius,
                            style: .continuous
                        )
                    )
            )
    }

    var panelBorder: some View {
        RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
            .stroke(BrowserChromePalette.commandBarPanelBorder, lineWidth: 1)
    }

    @ViewBuilder var leadingIcon: some View {
        if let cachedLeadingFavicon {
            Image(nsImage: cachedLeadingFavicon)
                .resizable()
                .scaledToFit()
                .frame(width: style.symbolSize, height: style.symbolSize)
        } else {
            Image(systemName: leadingSymbolName)
                .font(.system(size: style.symbolSize, weight: .semibold))
                .foregroundStyle(BrowserChromePalette.primaryText)
        }
    }

    // MARK: Private

    private func dismissLayer(in availableSize: CGSize) -> some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: blockedLeadingInset)
                .allowsHitTesting(false)

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    model.dismiss()
                }
        }
        .frame(width: availableSize.width, height: availableSize.height, alignment: .topLeading)
        .ignoresSafeArea()
    }

    private func panelWidth(in availableSize: CGSize) -> CGFloat {
        switch style {
        case .standard:
            return BrowserChromeLayout.commandBarWidth
        case .compact(let anchorFrame, let sidebarWidth, let matchesAnchorWidth):
            let originX = compactPanelOriginX(anchorFrame: anchorFrame)
            let viewportMaximum = max(
                availableSize.width - originX - BrowserChromeLayout.compactCommandBarHorizontalViewportPadding,
                0
            )
            if matchesAnchorWidth, let anchorFrame {
                return min(max(anchorFrame.width, 0), viewportMaximum)
            }

            let maximumWidth = min(
                max(availableSize.width * BrowserChromeLayout.compactCommandBarMaximumWindowFraction, 0),
                viewportMaximum
            )
            let minimumWidth = min(
                max(
                    sidebarWidth,
                    BrowserChromeModel.minSidebarWidth
                        * BrowserChromeLayout.compactCommandBarMinimumSidebarMultiplier
                ),
                maximumWidth
            )
            let measuredWidth = BrowserCommandBarTextWidthMeasurer.width(
                for: model.previewDisplayText ?? model.query,
                fontSize: style.fontSize
            ) + BrowserChromeLayout.compactCommandBarTextWidthBuffer

            return max(min(max(measuredWidth, minimumWidth), maximumWidth), 0)
        }
    }

    private func panelOffset(in availableSize: CGSize) -> CGSize {
        switch style {
        case .standard:
            CGSize(
                width: max((availableSize.width - BrowserChromeLayout.commandBarWidth) / 2, 0),
                height: commandBarTopInset(for: availableSize.height)
            )
        case .compact(let anchorFrame, _, _):
            CGSize(
                width: compactPanelOriginX(anchorFrame: anchorFrame),
                height: compactPanelOriginY(anchorFrame: anchorFrame, availableHeight: availableSize.height)
            )
        }
    }

    private func compactPanelOriginX(anchorFrame: CGRect?) -> CGFloat {
        max(anchorFrame?.minX ?? BrowserChromeLayout.sidebarOuterPadding, BrowserChromeLayout.sidebarOuterPadding)
    }

    private func compactPanelOriginY(anchorFrame: CGRect?, availableHeight: CGFloat) -> CGFloat {
        if let anchorFrame {
            return max(
                availableHeight - anchorFrame.maxY + BrowserChromeLayout.compactCommandBarTopGap,
                BrowserChromeLayout.sidebarOuterPadding
            )
        }

        let fallbackY = BrowserChromeLayout.sidebarOuterPadding
            + BrowserChromeLayout.chromeButtonSize
            + BrowserChromeLayout.sidebarSectionSpacing

        return fallbackY + BrowserChromeLayout.compactCommandBarTopGap
    }

    private func commandBarTopInset(for availableHeight: CGFloat) -> CGFloat {
        let estimatedPanelHeight = estimatedExpandedPanelHeight()
        let centeredTopInset = (availableHeight - estimatedPanelHeight) / 2
        let maximumTopInset = max(
            availableHeight - estimatedPanelHeight - BrowserChromeLayout.commandBarTopInsetMinimum,
            BrowserChromeLayout.sidebarOuterPadding
        )
        return min(
            max(centeredTopInset, BrowserChromeLayout.commandBarTopInsetMinimum),
            maximumTopInset
        )
    }

    private func estimatedExpandedPanelHeight() -> CGFloat {
        let visibleSuggestionCount = BrowserCommandBarModel.maximumVisibleSuggestions
        return BrowserChromeLayout.commandBarOuterPadding
            + style.fieldHeight
            + 1
            + CGFloat(visibleSuggestionCount) * BrowserChromeLayout.commandBarSuggestionRowHeight
            + CGFloat(visibleSuggestionCount - 1) * BrowserChromeLayout.commandBarSuggestionSpacing
            + BrowserChromeLayout.commandBarSuggestionVerticalInset * 2
            + BrowserChromeLayout.commandBarSuggestionViewportAllowance
    }
}

// MARK: - BrowserCommandSuggestionList

struct BrowserCommandSuggestionList: View {
    @ObservedObject var model: BrowserCommandBarModel

    let faviconCandidate: BrowserCommandBarFaviconCandidate?

    var visibleSuggestionCount: Int {
        min(model.suggestions.count, BrowserCommandBarModel.maximumVisibleSuggestions)
    }

    var visibleHeight: CGFloat {
        guard visibleSuggestionCount > 0 else {
            return 0
        }

        return CGFloat(visibleSuggestionCount) * BrowserChromeLayout.commandBarSuggestionRowHeight
            + CGFloat(max(visibleSuggestionCount - 1, 0)) * BrowserChromeLayout.commandBarSuggestionSpacing
            + BrowserChromeLayout.commandBarSuggestionVerticalInset * 2
            + visibleViewportAllowance
    }

    var visibleViewportAllowance: CGFloat {
        model.suggestions.count > visibleSuggestionCount
            ? BrowserChromeLayout.commandBarSuggestionViewportAllowance
            : 0
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: BrowserChromeLayout.commandBarSuggestionSpacing) {
                    ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { _, suggestion in
                        BrowserCommandSuggestionRow(
                            suggestion: suggestion,
                            isSelected: model.selectedSuggestionID == suggestion.id,
                            faviconCandidate: faviconCandidate,
                            onPress: { model.submitSuggestion(id: suggestion.id) }
                        )
                        .id(suggestion.id)
                    }
                }
                .padding(.vertical, BrowserChromeLayout.commandBarSuggestionVerticalInset)
            }
            .frame(height: visibleHeight)
            .onChange(of: model.selectedSuggestionID) { _, selectedSuggestionID in
                guard let selectedSuggestionID else {
                    return
                }

                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(selectedSuggestionID, anchor: .center)
                }
            }
        }
    }
}

// MARK: - BrowserCommandSuggestionRow

struct BrowserCommandSuggestionRow: View {
    @EnvironmentObject var faviconCache: BrowserFaviconCache

    let suggestion: BrowserCommandSuggestion
    let isSelected: Bool
    let faviconCandidate: BrowserCommandBarFaviconCandidate?
    let onPress: () -> Void

    @State var isHovered = false

    var cachedFavicon: NSImage? {
        faviconCache.image(for: faviconCandidate?.faviconURL(for: suggestion))
    }

    var body: some View {
        Button(action: onPress) {
            HStack(spacing: BrowserChromeLayout.commandBarRowContentSpacing) {
                leadingIcon
                    .frame(width: BrowserChromeLayout.commandBarSymbolWidth)

                Text(suggestion.displayText)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(BrowserChromePalette.primaryText)
                    .lineLimit(1)

                if let detailText = suggestion.detailText, !detailText.isEmpty {
                    Text(detailText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(BrowserChromePalette.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if let shortcut = suggestion.shortcut {
                    BrowserCommandSuggestionShortcutBadge(shortcut: shortcut)
                }
            }
            .padding(.horizontal, BrowserChromeLayout.commandBarRowHorizontalPadding)
            .padding(.vertical, BrowserChromeLayout.commandBarRowVerticalPadding)
            .frame(maxWidth: .infinity, minHeight: BrowserChromeLayout.commandBarSuggestionRowHeight)
            .background(backgroundShape)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering in
            isHovered = hovering
        }
    }

    var backgroundShape: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill((isSelected || isHovered) ? BrowserChromePalette.commandBarSuggestionSelected : Color.clear)
    }

    @ViewBuilder var leadingIcon: some View {
        if let cachedFavicon {
            Image(nsImage: cachedFavicon)
                .resizable()
                .scaledToFit()
                .frame(
                    width: BrowserChromeLayout.commandBarSymbolSize,
                    height: BrowserChromeLayout.commandBarSymbolSize
                )
        } else {
            Image(systemName: suggestion.systemImageName)
                .font(.system(size: BrowserChromeLayout.commandBarSymbolSize, weight: .semibold))
                .foregroundStyle(BrowserChromePalette.primaryText)
        }
    }
}

// MARK: - BrowserCommandSuggestionShortcutBadge

struct BrowserCommandSuggestionShortcutBadge: View {
    let shortcut: BrowserKeyboardShortcut

    var body: some View {
        Text(shortcut.displayText)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(BrowserChromePalette.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(badgeBackground)
    }

    var badgeBackground: some View {
        Capsule(style: .continuous)
            .fill(BrowserChromePalette.commandBarPanelBorder.opacity(0.55))
    }
}

// MARK: - BrowserCommandQueryTextField

struct BrowserCommandQueryTextField: NSViewRepresentable {
    final class Coordinator: NSObject, NSTextFieldDelegate {
        // MARK: Lifecycle

        init(
            text: Binding<String>,
            onMoveUp: @escaping () -> Void,
            onMoveDown: @escaping () -> Void,
            onAcceptCompletion: @escaping () -> Void,
            onSubmit: @escaping () -> Void,
            onDismiss: @escaping () -> Void
        ) {
            self.text = text
            self.onMoveUp = onMoveUp
            self.onMoveDown = onMoveDown
            self.onAcceptCompletion = onAcceptCompletion
            self.onSubmit = onSubmit
            self.onDismiss = onDismiss
        }

        // MARK: Internal

        var text: Binding<String>
        var onMoveUp: () -> Void
        var onMoveDown: () -> Void
        var onAcceptCompletion: () -> Void
        var onSubmit: () -> Void
        var onDismiss: () -> Void

        func update(
            text: Binding<String>,
            onMoveUp: @escaping () -> Void,
            onMoveDown: @escaping () -> Void,
            onAcceptCompletion: @escaping () -> Void,
            onSubmit: @escaping () -> Void,
            onDismiss: @escaping () -> Void
        ) {
            self.text = text
            self.onMoveUp = onMoveUp
            self.onMoveDown = onMoveDown
            self.onAcceptCompletion = onAcceptCompletion
            self.onSubmit = onSubmit
            self.onDismiss = onDismiss
        }

        func controlTextDidChange(_ notification: Notification) {
            guard
                let textField = notification.object as? BrowserCommandNSTextField,
                !textField.isApplyingPresentation
            else {
                return
            }

            if text.wrappedValue != textField.stringValue {
                text.wrappedValue = textField.stringValue
            }
            textField.clearFocusSelectionRequest()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                onMoveUp()
                return true
            case #selector(NSResponder.moveDown(_:)):
                onMoveDown()
                return true
            case #selector(NSResponder.moveRight(_:)):
                guard
                    let textField = control as? BrowserCommandNSTextField,
                    textField.hasSuggestionPreview
                else {
                    return false
                }

                onAcceptCompletion()
                return true
            case #selector(NSResponder.selectAll(_:)):
                textView.selectAll(nil)
                return true
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                onDismiss()
                return true
            default:
                return false
            }
        }
    }

    @Binding var text: String

    let previewDisplayText: String?
    let inlineCompletionSuffix: String?
    let isFocused: Bool
    let focusRequestID: Int
    let fontSize: CGFloat
    let selectAllOnFocus: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onAcceptCompletion: () -> Void
    let onSubmit: () -> Void
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onMoveUp: onMoveUp,
            onMoveDown: onMoveDown,
            onAcceptCompletion: onAcceptCompletion,
            onSubmit: onSubmit,
            onDismiss: onDismiss
        )
    }

    func makeNSView(context: Context) -> BrowserCommandNSTextField {
        let textField = BrowserCommandNSTextField()
        textField.delegate = context.coordinator
        textField.stringValue = text
        textField.fontSize = fontSize
        textField.selectAllOnFocus = selectAllOnFocus
        return textField
    }

    func updateNSView(_ nsView: BrowserCommandNSTextField, context: Context) {
        context.coordinator.update(
            text: $text,
            onMoveUp: onMoveUp,
            onMoveDown: onMoveDown,
            onAcceptCompletion: onAcceptCompletion,
            onSubmit: onSubmit,
            onDismiss: onDismiss
        )

        nsView.syncCommandPresentation(
            text: text,
            previewDisplayText: previewDisplayText,
            inlineCompletionSuffix: inlineCompletionSuffix,
            shouldFocus: isFocused,
            focusRequestID: focusRequestID,
            fontSize: fontSize,
            selectAllOnFocus: selectAllOnFocus
        )
    }
}

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

    var selectAllOnFocus = false
    var pendingFocus = false
    var lastFocusRequestID = -1
    var focusSelectionRequestID: Int?
    var committedText = ""
    var previewDisplayText: String?
    var inlineCompletionSuffix: String?

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

    // MARK: Fileprivate

    fileprivate private(set) var isApplyingPresentation = false

    // MARK: Private

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
        guard window != nil else {
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
            let needsStringUpdate = editor.string != targetDisplayText || stringValue != targetDisplayText
            let needsPreviewSelection = targetSelectionRange != nil && editor.selectedRange() != targetSelectionRange
            let needsSelectionCollapse =
                targetSelectionRange == nil &&
                editor.string == targetDisplayText &&
                editor.selectedRange().length > 0

            guard needsStringUpdate || needsPreviewSelection || needsSelectionCollapse else {
                applyEditorAppearance()
                return
            }

            isApplyingPresentation = true
            stringValue = targetDisplayText
            editor.string = targetDisplayText

            if let targetSelectionRange {
                editor.setSelectedRange(targetSelectionRange)
            } else if needsStringUpdate || needsSelectionCollapse {
                editor.setSelectedRange(
                    NSRange(location: (targetDisplayText as NSString).length, length: 0)
                )
            }

            isApplyingPresentation = false
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
