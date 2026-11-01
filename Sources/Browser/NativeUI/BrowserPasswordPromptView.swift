// BrowserPasswordPromptView.swift

import AppKit

/// Save a sign-in, or fill a saved one, over the page's top right corner.
final class BrowserPasswordPromptView: NSView {
    // MARK: Internal

    static let width: CGFloat = 320

    override var isFlipped: Bool { true }

    var onSave: () -> Void = {}
    var onNotNow: () -> Void = {}
    var onNever: () -> Void = {}
    var onFill: (BrowserSavedLogin) -> Void = { _ in }

    private(set) var preferredHeight: CGFloat = 0

    private let panel = BrowserNativeMaterialPanel()
    private let title = BrowserNativeControls.label(
        "",
        size: 13,
        weight: .semibold,
        color: BrowserChromeColors.primaryText,
    )
    private let detail = BrowserNativeControls.label(
        "",
        size: 12,
        weight: .regular,
        color: BrowserChromeColors.secondaryText,
    )
    private var buttons = [BrowserActionButton]()
    private var shown: BrowserPasswordPrompt?

    override init(frame: NSRect) {
        super.init(frame: frame)
        panel.cornerRadius = 12
        addSubview(panel)
        panel.contentView.addSubview(title)
        panel.contentView.addSubview(detail)
        title.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingMiddle
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("browser.password-prompt")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        panel.frame = bounds
        let padding: CGFloat = 14
        title.frame = NSRect(x: padding, y: 12, width: bounds.width - padding * 2, height: 17)
        detail.frame = NSRect(x: padding, y: 31, width: bounds.width - padding * 2, height: 16)
        if case .fill = shown {
            var y: CGFloat = 54
            for button in buttons {
                button.frame = NSRect(x: padding, y: y, width: bounds.width - padding * 2, height: 28)
                y += 32
            }
        } else {
            var x = bounds.width - padding
            for button in buttons.reversed() {
                let width = ceil(button.intrinsicContentSize.width) + 8
                x -= width
                button.frame = NSRect(x: x, y: 56, width: width, height: 28)
                x -= 6
            }
        }
    }

    func update(_ prompt: BrowserPasswordPrompt) {
        guard prompt != shown else { return }
        shown = prompt
        buttons.forEach { $0.removeFromSuperview() }
        switch prompt {
        case .save(_, let login, _, let isUpdate):
            title.stringValue = String(
                format: isUpdate ? BrowserStrings.passwordUpdateTitle : BrowserStrings.passwordSaveTitle,
                login.host,
            )
            detail.stringValue = login.username.isEmpty ? BrowserStrings.passwordNoUsername : login.username
            let save = BrowserActionButton(isUpdate ? BrowserStrings.passwordUpdate : BrowserStrings.passwordSave) {
                [weak self] in self?.onSave()
            }
            save.keyEquivalent = ""
            buttons = [
                BrowserActionButton(BrowserStrings.passwordNever) { [weak self] in self?.onNever() },
                BrowserActionButton(BrowserStrings.passwordNotNow) { [weak self] in self?.onNotNow() },
                save,
            ]
            preferredHeight = 96
        case .fill(_, _, _, let logins):
            let shownLogins = Array(logins.prefix(3))
            title.stringValue = String(format: BrowserStrings.passwordFillTitle, shownLogins.first?.host ?? "")
            detail.stringValue = BrowserStrings.passwordFillDetail
            buttons = shownLogins.map { login in
                BrowserActionButton(login.username.isEmpty ? BrowserStrings.passwordNoUsername : login.username) {
                    [weak self] in self?.onFill(login)
                }
            }
            buttons.append(BrowserActionButton(BrowserStrings.passwordNotNow) { [weak self] in self?.onNotNow() })
            preferredHeight = 54 + CGFloat(buttons.count) * 32 + 8
        }
        buttons.forEach(panel.contentView.addSubview)
        needsLayout = true
    }
}
