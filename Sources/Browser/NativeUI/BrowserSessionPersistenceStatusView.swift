// BrowserSessionPersistenceStatusView.swift

import AppKit
import UniformTypeIdentifiers

// MARK: - BrowserSessionPersistenceStatusView

/// A persistent recovery surface, independent of sidebar visibility.
final class BrowserSessionPersistenceStatusView: NSView {
    // MARK: Internal

    override var isFlipped: Bool { true }

    var onRetry: () -> Void = {}
    var onSaveCopy: () -> Void = {}

    // MARK: Private

    private let material = NSVisualEffectView()
    private let outline = BrowserNativeSurface()
    private let title = BrowserNativeControls.label(
        "",
        size: 13,
        weight: .semibold,
        color: BrowserChromeColors.primaryText,
    )
    private let message = BrowserNativeControls.label(
        "",
        size: 12,
        color: BrowserChromeColors.secondaryText,
        wraps: true,
    )
    private let retry = BrowserActionButton(BrowserStrings.sessionRecoveryRetry, action: {})
    private let saveCopy = BrowserActionButton(BrowserStrings.sessionRecoverySaveCopy, action: {})

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        material.material = .sidebar
        material.blendingMode = .withinWindow
        material.state = .active
        addSubview(material)
        outline.cornerRadius = 8
        outline.strokeColor = BrowserChromeColors.buttonBorder
        addSubview(outline)
        for view in [title, message, retry, saveCopy] {
            outline.addSubview(view)
        }
        retry.onAction = { [weak self] in self?.onRetry() }
        saveCopy.onAction = { [weak self] in self?.onSaveCopy() }
        setAccessibilityIdentifier("browser.session.recovery")
        setAccessibilityRole(.group)
        retry.setAccessibilityIdentifier("browser.session.retry")
        saveCopy.setAccessibilityIdentifier("browser.session.save-copy")
        message.maximumNumberOfLines = 0
        isHidden = true
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        material.frame = bounds
        outline.frame = bounds
        title.frame = NSRect(x: 16, y: 12, width: max(bounds.width - 32, 0), height: 18)
        let actionsHeight = actionsHeight(for: bounds.width)
        message.frame = NSRect(
            x: 16,
            y: 38,
            width: max(bounds.width - 32, 0),
            height: max(bounds.height - 62 - actionsHeight, 0),
        )
        let saveWidth = min(max(saveCopy.intrinsicContentSize.width, 100), max(bounds.width - 32, 0))
        let retryWidth = min(max(retry.intrinsicContentSize.width, 72), max(bounds.width - 32, 0))
        saveCopy.frame = NSRect(x: bounds.width - 16 - saveWidth, y: bounds.height - 44, width: saveWidth, height: 32)
        retry.frame = NSRect(
            x: actionsHeight > 32 ? bounds.width - 16 - retryWidth : saveCopy.frame.minX - 8 - retryWidth,
            y: actionsHeight > 32 ? saveCopy.frame.minY - 40 : saveCopy.frame.minY,
            width: retryWidth,
            height: 32,
        )
    }

    /// Runs on every window refresh; with nothing to report it stays hidden untouched.
    func update(_ failure: BrowserSessionPersistenceFailure?) {
        guard failure != nil || !isHidden else { return }
        isHidden = failure == nil
        retry.isEnabled = failure?.isRetryable == true
        title.stringValue = BrowserStrings.sessionRecoveryTitle
        message.stringValue = failure?.isRetryable == true
            ? BrowserStrings.sessionRecoveryRetryMessage
            : BrowserStrings.sessionRecoveryTerminalMessage
        setAccessibilityLabel(title.stringValue)
        needsLayout = true
    }

    /// Measuring the message took a millisecond of each window layout; hidden, it has none.
    func height(for width: CGFloat) -> CGFloat {
        guard !isHidden else { return 0 }
        let textHeight = (message.stringValue as NSString)
            .boundingRect(
                with: NSSize(width: max(width - 32, 1), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: message.font!],
            )
            .height
        return 18 + 8 + ceil(textHeight) + 12 + actionsHeight(for: width) + 24
    }

    private func actionsHeight(for width: CGFloat) -> CGFloat {
        max(saveCopy.intrinsicContentSize.width, 100) + max(retry.intrinsicContentSize.width, 72) + 40 > width ? 72 : 32
    }
}

// MARK: - BrowserSessionRecoveryExporter

@MainActor enum BrowserSessionRecoveryExporter {
    static func present(model: BrowserChromeModel, window: NSWindow) {
        let panel = NSSavePanel()
        panel.title = BrowserStrings.sessionRecoverySaveCopy
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "OpenArc-session.json"
        panel.beginSheetModal(for: window) { [weak model, weak window] response in
            guard response == .OK, let url = panel.url, let model, let window else { return }
            do {
                // Capture at acceptance, including edits made while the panel was open.
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(model.sessionRecoverySnapshot()).write(to: url, options: .atomic)
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = BrowserStrings.sessionRecoveryExportFailed
                alert.beginSheetModal(for: window)
            }
        }
    }
}
