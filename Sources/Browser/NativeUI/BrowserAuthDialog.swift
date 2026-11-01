// BrowserAuthDialog.swift

import AppKit

/// A site or proxy asking for a username and password: a sheet on the page's window.
@MainActor @objc final class BrowserAuthDialog: NSObject {
    // MARK: Private

    private weak var window: NSWindow?
    private let host: String
    private let origin: String
    private let username = NSTextField()
    private let password = NSSecureTextField()
    private var panel: NSPanel?
    private var completion: ((Bool, String, String) -> Void)?

    @objc(initWithWindow:host:origin:completion:)
    init(window: NSWindow?, host: String, origin: String, completion: @escaping (Bool, String, String) -> Void) {
        self.window = window
        self.host = host
        self.origin = origin
        self.completion = completion
        super.init()
    }

    // MARK: Internal

    /// The sheet's second line, which is true only when the password can't be read on the way.
    nonisolated static func isConnectionPrivate(origin: String) -> Bool {
        guard let components = URLComponents(string: origin) else { return false }
        return components.scheme == "https" || ["localhost", "127.0.0.1", "::1"].contains(components.host ?? "")
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
        panel.makeFirstResponder(username)
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
        completion(accepted, accepted ? username.stringValue : "", accepted ? password.stringValue : "")
    }

    private func makePanel() -> NSPanel {
        let width: CGFloat = 412
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false,
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.setAccessibilityIdentifier("browser.authDialog")

        let title = NSTextField(labelWithString: String(format: BrowserStrings.authDialogTitle, host))
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        let detail = NSTextField(labelWithString: Self.isConnectionPrivate(origin: origin)
            ? BrowserStrings.authDialogPrivate
            : BrowserStrings.authDialogNotPrivate)
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor

        username.placeholderString = BrowserStrings.authDialogUsername
        username.contentType = .username
        password.placeholderString = BrowserStrings.authDialogPassword
        password.contentType = .password
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: BrowserStrings.authDialogUsername), username],
            [NSTextField(labelWithString: BrowserStrings.authDialogPassword), password],
        ])
        grid.rowSpacing = 14
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        username.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let cancel = NSButton(
            title: BrowserStrings.javaScriptDialogCancel,
            target: self,
            action: #selector(declinePressed),
        )
        cancel.keyEquivalent = "\u{1b}"
        cancel.controlSize = .large
        let signIn = NSButton(title: BrowserStrings.authDialogSignIn, target: self, action: #selector(acceptPressed))
        signIn.keyEquivalent = "\r"
        signIn.controlSize = .large
        let buttons = NSStackView(views: [NSView(), cancel, signIn])
        buttons.spacing = 8

        let stack = NSStackView(views: [title, detail, grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        buttons.widthAnchor.constraint(equalToConstant: width - 40).isActive = true
        title.widthAnchor.constraint(lessThanOrEqualToConstant: width - 40).isActive = true
        panel.contentView = stack
        stack.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: width, height: stack.fittingSize.height))
        return panel
    }

    @objc private func acceptPressed() {
        finish(accepted: true)
    }

    @objc private func declinePressed() {
        finish(accepted: false)
    }
}
