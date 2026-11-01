// BrowserJavaScriptDialog.swift

import AppKit

/// A page's `alert`, `confirm` or `prompt`, as a sheet on its window.
@MainActor @objc final class BrowserJavaScriptDialog: NSObject {
    // MARK: Private

    private weak var window: NSWindow?
    private let kind: Int
    private let origin: String
    private let message: String
    private let field = NSTextField()
    private var panel: NSPanel?
    private var completion: ((Bool, String) -> Void)?

    /// `kind` is CEF's: 0 alert, 1 confirm, 2 prompt.
    @objc(initWithWindow:kind:origin:message:defaultText:completion:) init(
        window: NSWindow?,
        kind: Int,
        origin: String,
        message: String,
        defaultText: String,
        completion: @escaping (Bool, String) -> Void,
    ) {
        self.window = window
        self.kind = kind
        self.origin = origin
        self.message = message
        field.stringValue = defaultText
        self.completion = completion
        super.init()
    }

    /// `kind` is CEF's: 0 alert, 1 confirm, 2 prompt.
    // MARK: Internal

    /// The title names the host, not the whole address: "example.com says".
    nonisolated static func siteName(forOrigin origin: String) -> String? {
        guard let components = URLComponents(string: origin), let host = components.host, !host.isEmpty else {
            return nil
        }
        return components.port.map { "\(host):\($0)" } ?? host
    }

    nonisolated static func title(forOrigin origin: String) -> String {
        siteName(forOrigin: origin).map { String(format: BrowserStrings.javaScriptDialogSays, $0) }
            ?? BrowserStrings.javaScriptDialogPageSays
    }

    @objc func present() {
        guard panel == nil, completion != nil else { return }
        guard let window, window.attachedSheet == nil else {
            finish(accepted: false)
            return
        }
        let panel = makePanel()
        self.panel = panel
        window.beginSheet(panel)
        if kind == 2 {
            panel.makeFirstResponder(field)
        }
    }

    @objc func cancel() {
        finish(accepted: false)
    }

    private func finish(accepted: Bool) {
        guard let completion else { return }
        self.completion = nil
        if let panel {
            panel.sheetParent?.endSheet(panel)
        }
        completion(accepted, accepted && kind == 2 ? field.stringValue : "")
    }

    private func makePanel() -> NSPanel {
        let width: CGFloat = 260
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 100),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false,
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.setAccessibilityIdentifier("browser.javaScriptDialog")

        let inner = width - 32
        let title = NSTextField(wrappingLabelWithString: Self.title(forOrigin: origin))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.preferredMaxLayoutWidth = inner
        let text = NSTextField(wrappingLabelWithString: message)
        text.font = .systemFont(ofSize: 12)
        text.maximumNumberOfLines = 16
        text.lineBreakMode = .byTruncatingTail
        text.preferredMaxLayoutWidth = inner
        text.isSelectable = true

        var rows: [NSView] = [title]
        if !message.isEmpty {
            rows.append(text)
        }
        if kind == 2 {
            field.widthAnchor.constraint(equalToConstant: inner).isActive = true
            rows.append(field)
        }
        rows.append(buttonRow(width: inner))

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.setCustomSpacing(14, after: rows[rows.count - 2])
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        panel.contentView = stack
        stack.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: width, height: stack.fittingSize.height))
        return panel
    }

    private func buttonRow(width: CGFloat) -> NSView {
        let accept = NSButton(title: BrowserStrings.javaScriptDialogOK, target: self, action: #selector(acceptPressed))
        accept.keyEquivalent = "\r"
        accept.controlSize = .large
        guard kind != 0 else {
            // One button also takes Escape: there's nothing else an alert can answer.
            accept.widthAnchor.constraint(equalToConstant: width).isActive = true
            return accept
        }
        let decline = NSButton(
            title: BrowserStrings.javaScriptDialogCancel,
            target: self,
            action: #selector(declinePressed),
        )
        decline.keyEquivalent = "\u{1b}"
        decline.controlSize = .large
        let row = NSStackView(views: [decline, accept])
        row.distribution = .fillEqually
        row.spacing = 8
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }

    @objc private func acceptPressed() {
        finish(accepted: true)
    }

    @objc private func declinePressed() {
        finish(accepted: false)
    }
}
