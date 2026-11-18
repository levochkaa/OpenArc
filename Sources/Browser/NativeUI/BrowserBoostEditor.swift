// BrowserBoostEditor.swift

import AppKit
import Combine

// MARK: - BrowserBoostEditorViewController

/// A site's Boost: on or off, its CSS, its JavaScript and the elements zapped
/// on its pages. CSS applies as it is typed; JavaScript is saved when its
/// field loses focus or the editor closes, and reloads the site's pages.
final class BrowserBoostEditorViewController: NSViewController, NSTextViewDelegate, NSPopoverDelegate {
    // MARK: Internal

    static let width: CGFloat = 380

    // MARK: Private

    private static let cssCommitDelay: TimeInterval = 0.3

    let host: String
    /// Closes the editor's popover.
    var onClose: () -> Void = {}
    /// Zapping started: the page takes the keyboard and the pointer.
    var onStartZapping: () -> Void = {}

    private let model: BrowserChromeModel
    private let enabledToggle = BrowserActionToggle()
    private let hostLabel = BrowserNativeControls.label("", size: 12, color: .secondaryLabelColor)
    private let cssView = BrowserBoostEditorViewController.makeCodeView()
    private let javaScriptView = BrowserBoostEditorViewController.makeCodeView()
    private let zappedStack = NSStackView()
    private let zappedEmpty = BrowserNativeControls.label(
        BrowserStrings.boostEditorNoHiddenElements,
        size: 12,
        color: .secondaryLabelColor,
        wraps: true,
    )
    private let zapHint = BrowserNativeControls.label(
        BrowserStrings.boostEditorZapHint,
        size: 12,
        color: .secondaryLabelColor,
        wraps: true,
    )
    private lazy var zapButton = BrowserActionButton(BrowserStrings.boostEditorZap) { [weak self] in
        self?.toggleZapping()
    }

    private lazy var deleteButton = BrowserActionButton(BrowserStrings.boostEditorDelete) { [weak self] in
        self?.deleteBoost()
    }

    private var observations = Set<AnyCancellable>()
    private var pendingCSSCommit: DispatchWorkItem?
    private var shownZappedSelectors: [String]?

    init(model: BrowserChromeModel, host: String) {
        self.model = model
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 1))
        root.setAccessibilityIdentifier("browser.boost-editor")
        view = root

        let boost = model.boost(forHost: host)
        hostLabel.stringValue = host
        hostLabel.lineBreakMode = .byTruncatingMiddle
        let title = BrowserNativeControls.label(BrowserStrings.boostEditorTitle, size: 15, weight: .semibold)
        enabledToggle.state = boost.isEnabled ? .on : .off
        enabledToggle.setAccessibilityLabel(BrowserStrings.boostEditorEnabled)
        enabledToggle.setAccessibilityIdentifier("browser.boost-editor.enabled")
        enabledToggle.onChange = { [weak self] on in
            guard let self else { return }
            commitPendingEdits()
            model.updateBoost(host: host) { $0.isEnabled = on }
        }
        let header = BrowserNativeControls.stack(
            [BrowserNativeControls.stack([title, hostLabel], spacing: 2), Self.spacer(), enabledToggle],
            orientation: .horizontal,
            spacing: 8,
        )

        cssView.textView.string = boost.css
        cssView.textView.delegate = self
        cssView.textView.setAccessibilityLabel(BrowserStrings.boostEditorCSS)
        cssView.textView.setAccessibilityIdentifier("browser.boost-editor.css")
        javaScriptView.textView.string = boost.javaScript
        javaScriptView.textView.delegate = self
        javaScriptView.textView.setAccessibilityLabel(BrowserStrings.boostEditorJavaScript)
        javaScriptView.textView.setAccessibilityIdentifier("browser.boost-editor.javascript")

        zappedStack.orientation = .vertical
        zappedStack.alignment = .leading
        zappedStack.spacing = 2
        let zappedScroll = Self.scrollView(containing: zappedStack)
        zappedScroll.heightAnchor.constraint(equalToConstant: 84).isActive = true

        zapButton.setAccessibilityIdentifier("browser.boost-editor.zap")
        deleteButton.setAccessibilityIdentifier("browser.boost-editor.delete")
        let done = BrowserActionButton(BrowserStrings.boostEditorDone) { [weak self] in self?.onClose() }
        done.keyEquivalent = "\r"
        done.keyEquivalentModifierMask = [.command]
        done.setAccessibilityIdentifier("browser.boost-editor.done")
        let buttons = BrowserNativeControls.stack(
            [zapButton, Self.spacer(), deleteButton, done],
            orientation: .horizontal,
            spacing: 8,
        )

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        // The zapping hint keeps its place, so the editor does not change height.
        stack.detachesHiddenViews = false
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        let javaScriptDetail = BrowserNativeControls.label(
            BrowserStrings.boostEditorJavaScriptDetail,
            size: 11,
            color: .secondaryLabelColor,
            wraps: true,
        )
        for view in [
            header,
            BrowserNativeControls.divider(),
            Self.sectionLabel(BrowserStrings.boostEditorCSS),
            cssView.scrollView,
            Self.sectionLabel(BrowserStrings.boostEditorJavaScript),
            javaScriptView.scrollView,
            javaScriptDetail,
            Self.sectionLabel(BrowserStrings.boostEditorHiddenElements),
            zappedScroll,
            zapHint,
            buttons,
        ] {
            BrowserNativeControls.fillWidth(view, in: stack)
        }
        stack.setCustomSpacing(12, after: javaScriptDetail)
        stack.setCustomSpacing(12, after: zapHint)
        cssView.scrollView.heightAnchor.constraint(equalToConstant: 132).isActive = true
        javaScriptView.scrollView.heightAnchor.constraint(equalToConstant: 104).isActive = true
        let textWidth = Self.width - stack.edgeInsets.left - stack.edgeInsets.right
        for label in [javaScriptDetail, zapHint] {
            label.preferredMaxLayoutWidth = textWidth
        }
        // Inside the list's border and insets.
        zappedEmpty.preferredMaxLayoutWidth = textWidth - zappedStack.edgeInsets.left - zappedStack.edgeInsets.right - 4
        let width = stack.widthAnchor.constraint(equalToConstant: Self.width)
        width.isActive = true
        let size = NSSize(width: Self.width, height: ceil(stack.fittingSize.height))
        width.isActive = false
        root.setFrameSize(size)
        preferredContentSize = size

        model.userPreferencesStore
            .objectWillChange
            .merge(with: model.objectWillChange)
            .sink { [weak self] _ in
                // Sent before the change; read the new state after it.
                DispatchQueue.main.async { self?.refresh() }
            }
            .store(in: &observations)
        refresh()
    }

    // MARK: Private

    private static func makeCodeView() -> (scrollView: NSScrollView, textView: NSTextView) {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let textView = scrollView.documentView as? NSTextView ?? NSTextView()
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        return (scrollView, textView)
    }

    private static func scrollView(containing stack: NSStackView) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        let document = BrowserBoostFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 4)
        document.addSubview(stack)
        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        return scrollView
    }

    private static func sectionLabel(_ text: String) -> NSTextField {
        BrowserNativeControls.label(text, size: 12, weight: .semibold, color: .secondaryLabelColor)
    }

    private static func spacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return spacer
    }

    /// Saves typed CSS and JavaScript that are not saved yet.
    func commitPendingEdits() {
        commitCSS()
        commitJavaScript()
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === cssView.textView else { return }
        pendingCSSCommit?.cancel()
        let commit = DispatchWorkItem { [weak self] in self?.commitCSS() }
        pendingCSSCommit = commit
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.cssCommitDelay, execute: commit)
    }

    func textDidEndEditing(_ notification: Notification) {
        if notification.object as? NSTextView === javaScriptView.textView {
            commitJavaScript()
        } else {
            commitCSS()
        }
    }

    // MARK: NSPopoverDelegate

    func popoverWillClose(_: Notification) {
        commitPendingEdits()
        if model.boostZapSession?.host == host {
            model.stopZapping()
        }
    }

    private func commitCSS() {
        pendingCSSCommit?.cancel()
        pendingCSSCommit = nil
        let css = cssView.textView.string
        guard css != model.boost(forHost: host).css else { return }
        model.updateBoost(host: host) { $0.css = css }
    }

    private func commitJavaScript() {
        let javaScript = javaScriptView.textView.string
        guard javaScript != model.boost(forHost: host).javaScript else { return }
        model.updateBoost(host: host) { $0.javaScript = javaScript }
    }

    private func toggleZapping() {
        if model.boostZapSession != nil {
            model.stopZapping()
            return
        }
        commitPendingEdits()
        model.startZapping(host: host)
        onStartZapping()
    }

    private func deleteBoost() {
        pendingCSSCommit?.cancel()
        pendingCSSCommit = nil
        cssView.textView.string = ""
        javaScriptView.textView.string = ""
        model.removeBoost(host: host)
        onClose()
    }

    private func refresh() {
        let boost = model.boost(forHost: host)
        enabledToggle.state = boost.isEnabled ? .on : .off
        let zapping = model.boostZapSession?.host == host
        zapButton.title = zapping ? BrowserStrings.boostEditorStopZapping : BrowserStrings.boostEditorZap
        zapButton.isEnabled = zapping || model.currentBoostHost == host
        zapHint.isHidden = !zapping
        deleteButton.isEnabled = model.userPreferencesStore.boosts.boost(forHost: host) != nil
        guard boost.zappedSelectors != shownZappedSelectors else { return }
        shownZappedSelectors = boost.zappedSelectors
        let rows = boost.zappedSelectors.map(zappedRow)
        BrowserNativeControls.replaceViews(rows.isEmpty ? [zappedEmpty] : rows, in: zappedStack)
    }

    private func zappedRow(_ selector: String) -> NSView {
        let label = NSTextField(labelWithString: selector)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = selector
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let remove = BrowserActionButton("") { [weak self] in
            guard let self else { return }
            model.updateBoost(host: host) { boost in boost.zappedSelectors.removeAll { $0 == selector } }
        }
        remove.image = NSImage(
            systemSymbolName: "minus.circle",
            accessibilityDescription: BrowserStrings.boostEditorRemoveHiddenElement,
        )
        remove.isBordered = false
        remove.toolTip = BrowserStrings.boostEditorRemoveHiddenElement
        remove.setAccessibilityIdentifier("browser.boost-editor.remove-hidden-element")
        return BrowserNativeControls.stack([label, Self.spacer(), remove], orientation: .horizontal, spacing: 6)
    }
}

// MARK: - BrowserBoostFlippedView

/// Lays the hidden elements out from the top.
private final class BrowserBoostFlippedView: NSView {
    override var isFlipped: Bool { true }
}
