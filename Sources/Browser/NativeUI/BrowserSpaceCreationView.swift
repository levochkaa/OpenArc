// BrowserSpaceCreationView.swift

import AppKit

// MARK: - BrowserSpaceCreationDraft

/// A Space being set up in the sidebar, before it exists.
struct BrowserSpaceCreationDraft: Equatable {
    var title = ""
    var icon: String?
    var theme: BrowserSpaceTheme?
    var profileDirectory: String?
}

// MARK: - BrowserSpaceCreationView

/// The sidebar page that creates a Space: a name, an icon and a theme.
final class BrowserSpaceCreationView: NSView, NSTextFieldDelegate {
    override var isFlipped: Bool { true }

    // MARK: Internal

    var onTitleChange: (String) -> Void = { _ in }
    var onChooseIcon: (NSView) -> Void = { _ in }
    var onChooseTheme: (NSView) -> Void = { _ in }
    var onChooseProfile: (String) -> Void = { _ in }
    var onCreate: () -> Void = {}
    var onCancel: () -> Void = {}

    // MARK: Private

    private let hero = BrowserSpaceCreationHero()
    private let title = NSTextField(labelWithString: BrowserStrings.spaceCreationTitle)
    private let detail = NSTextField(wrappingLabelWithString: BrowserStrings.spaceCreationDetail)
    private let nameRow = BrowserNativeSurface()
    private let nameField = NSTextField()
    private let iconButton = BrowserSpaceCreationIconButton()
    private let profileRow = BrowserNativeSurface()
    private let profileLabel = NSTextField(labelWithString: BrowserStrings.spaceCreationProfile)
    private let profilePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let themeRow = BrowserSpaceCreationRowButton(
        symbol: "paintbrush.pointed.fill",
        title: BrowserStrings.spaceCreationTheme,
    )
    private let createButton = BrowserSpaceCreationPrimaryButton(title: BrowserStrings.spaceCreationCreate)
    private let cancelButton = BrowserSpaceCreationPlainButton(title: BrowserStrings.spaceCreationCancel)

    init() {
        super.init(frame: .zero)
        setAccessibilityIdentifier("browser.sidebar.create-space-page")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.alignment = .center
        detail.font = .systemFont(ofSize: 13)
        detail.alignment = .center
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byWordWrapping
        for label in [title, detail] {
            label.isEditable = false
            label.isBordered = false
            label.drawsBackground = false
            addSubview(label)
        }
        addSubview(hero)
        nameRow.cornerRadius = BrowserChromeLayout.spaceCreationRowCornerRadius
        nameRow.strokeWidth = 0
        nameRow.fillColor = BrowserChromeColors.currentURLRow
        addSubview(nameRow)
        nameField.placeholderString = BrowserStrings.spaceCreationNamePlaceholder
        nameField.font = .systemFont(ofSize: 14)
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.focusRingType = .none
        nameField.delegate = self
        nameField.target = self
        nameField.action = #selector(commit)
        nameField.setAccessibilityIdentifier("browser.sidebar.create-space-name")
        nameRow.addSubview(nameField)
        iconButton.onClick = { [weak self] _ in
            guard let self else { return }
            onChooseIcon(iconButton)
        }
        iconButton.setAccessibilityLabel(BrowserStrings.spaceChangeIconAction)
        nameRow.addSubview(iconButton)
        profileRow.cornerRadius = BrowserChromeLayout.spaceCreationRowCornerRadius
        profileRow.strokeWidth = 0
        profileRow.fillColor = BrowserChromeColors.currentURLRow
        addSubview(profileRow)
        profileLabel.font = .systemFont(ofSize: 13, weight: .medium)
        profileRow.addSubview(profileLabel)
        profilePopUp.isBordered = false
        profilePopUp.controlSize = .small
        profilePopUp.font = .systemFont(ofSize: 12, weight: .medium)
        profilePopUp.target = self
        profilePopUp.action = #selector(chooseProfile)
        profilePopUp.setAccessibilityIdentifier("browser.sidebar.create-space-profile")
        profileRow.addSubview(profilePopUp)
        themeRow.onClick = { [weak self] _ in
            guard let self else { return }
            onChooseTheme(themeRow)
        }
        addSubview(themeRow)
        createButton.onClick = { [weak self] _ in self?.commit() }
        createButton.setAccessibilityIdentifier("browser.sidebar.create-space-confirm")
        addSubview(createButton)
        cancelButton.onClick = { [weak self] _ in self?.onCancel() }
        cancelButton.setAccessibilityIdentifier("browser.sidebar.create-space-cancel")
        addSubview(cancelButton)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let width = bounds.width
        let inner = width - 28
        hero.frame = NSRect(x: (width - 80) / 2, y: 40, width: 80, height: 52)
        title.frame = NSRect(x: 0, y: 96, width: width, height: 20)
        detail.frame = NSRect(x: 14, y: 124, width: inner, height: 36)
        nameRow.frame = NSRect(x: 14, y: 190, width: inner, height: 36)
        iconButton.frame = NSRect(x: 8, y: 7, width: 22, height: 22)
        nameField.frame = NSRect(x: 34, y: 9, width: inner - 42, height: 18)
        profileRow.frame = NSRect(x: 14, y: 234, width: inner, height: 36)
        profileLabel.frame = NSRect(x: 12, y: 10, width: 50, height: 16)
        profilePopUp.frame = NSRect(x: 62, y: 6, width: inner - 70, height: 24)
        themeRow.frame = NSRect(x: 14, y: profileRow.isHidden ? 234 : 278, width: inner, height: 36)
        createButton.frame = NSRect(x: 14, y: bounds.height - 82, width: inner, height: 36)
        cancelButton.frame = NSRect(x: 14, y: bounds.height - 36, width: inner, height: 24)
    }

    /// The profile choice, shown once there is more than one to choose from.
    func updateProfiles(_ profiles: [BrowserProfile], selected: String?) {
        profileRow.isHidden = profiles.count < 2
        profileLabel.textColor = BrowserChromeColors.sidebarRowText
        profilePopUp.removeAllItems()
        for profile in profiles {
            profilePopUp.addItem(withTitle: profile.displayName)
            profilePopUp.lastItem?.representedObject = profile.id
        }
        if let index = profiles.firstIndex(where: { $0.id == selected }) {
            profilePopUp.selectItem(at: index)
        }
        needsLayout = true
    }

    func update(draft: BrowserSpaceCreationDraft) {
        if nameField.stringValue != draft.title, window?.firstResponder !== nameField.currentEditor() {
            nameField.stringValue = draft.title
        }
        iconButton.icon = draft.icon
        createButton.isEnabled = !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        nameField.textColor = BrowserChromeColors.sidebarRowText
        title.textColor = BrowserChromeColors.sidebarRowText
        detail.textColor = BrowserChromeColors.sidebarRowText
        needsDisplay = true
    }

    func focusName() {
        window?.makeFirstResponder(nameField)
    }

    func controlTextDidChange(_: Notification) {
        onTitleChange(nameField.stringValue)
    }

    @objc private func chooseProfile() {
        if let id = profilePopUp.selectedItem?.representedObject as? String {
            onChooseProfile(id)
        }
    }

    @objc private func commit() {
        guard createButton.isEnabled else { return }
        onCreate()
    }
}

// MARK: - BrowserSpaceCreationHero

/// Three cards fanned out, each with a picture of what a Space can hold.
private final class BrowserSpaceCreationHero: NSView {
    override var isFlipped: Bool { true }

    override func draw(_: NSRect) {
        let cards: [(emoji: String, angle: CGFloat, x: CGFloat, y: CGFloat)] = [
            ("🌴", -14, 2, 8),
            ("📚", 14, 44, 8),
            ("💻", 0, 21, 3),
        ]
        for card in cards {
            let context = NSGraphicsContext.current?.cgContext
            context?.saveGState()
            context?.translateBy(x: card.x + 17, y: card.y + 21)
            context?.rotate(by: card.angle * .pi / 180)
            let rect = NSRect(x: -17, y: -21, width: 34, height: 42)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22)]
            let text = card.emoji as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: -size.width / 2, y: -size.height / 2), withAttributes: attributes)
            context?.restoreGState()
        }
    }
}

// MARK: - BrowserSpaceCreationIconButton

/// A dashed square with a plus, or the chosen icon.
private final class BrowserSpaceCreationIconButton: BrowserNativePressableView {
    var icon: String? {
        didSet {
            guard icon != oldValue else { return }
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let icon, let image = BrowserIconImage.image(named: icon, pointSize: 14) {
            let size = image.size
            let rect = NSRect(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2,
                width: size.width,
                height: size.height,
            )
            if image.isTemplate {
                BrowserChromeColors.sidebarRowText.set()
                let tinted = NSImage(size: size, flipped: false) { rect in
                    image.draw(in: rect)
                    BrowserChromeColors.sidebarRowText.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(
                    in: rect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: true,
                    hints: nil,
                )
            } else {
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            return
        }
        BrowserChromeColors.sidebarDimText.setStroke()
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 2.5, dy: 2.5), xRadius: 3, yRadius: 3)
        box.lineWidth = 1
        box.setLineDash([2, 2], count: 2, phase: 0)
        box.stroke()
        let plus = NSBezierPath()
        plus.move(to: NSPoint(x: bounds.midX - 4, y: bounds.midY))
        plus.line(to: NSPoint(x: bounds.midX + 4, y: bounds.midY))
        plus.move(to: NSPoint(x: bounds.midX, y: bounds.midY - 4))
        plus.line(to: NSPoint(x: bounds.midX, y: bounds.midY + 4))
        plus.lineWidth = 1
        plus.stroke()
    }
}

// MARK: - BrowserSpaceCreationRowButton

/// A full-width row with an icon and a title, as the theme choice uses.
private final class BrowserSpaceCreationRowButton: BrowserNativePressableView {
    private let symbol: String
    private let title: String

    init(symbol: String, title: String) {
        self.symbol = symbol
        self.title = title
        super.init(frame: .zero)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        BrowserChromeColors.currentURLRow.setFill()
        NSBezierPath(
            roundedRect: bounds,
            xRadius: BrowserChromeLayout.spaceCreationRowCornerRadius,
            yRadius: BrowserChromeLayout.spaceCreationRowCornerRadius,
        ).fill()
        super.draw(dirtyRect)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: BrowserChromeColors.sidebarRowText,
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: 34, y: bounds.midY - size.height / 2), withAttributes: attributes)
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        else { return }
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            BrowserChromeColors.sidebarChromeForeground.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(
            in: NSRect(
                x: 19 - image.size.width / 2,
                y: bounds.midY - image.size.height / 2,
                width: image.size.width,
                height: image.size.height,
            ),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil,
        )
    }
}

// MARK: - BrowserSpaceCreationPrimaryButton

private final class BrowserSpaceCreationPrimaryButton: BrowserNativePressableView {
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            needsDisplay = true
        }
    }

    private let title: String

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    override func draw(_: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(isEnabled ? 1 : 0.45).setFill()
        NSBezierPath(
            roundedRect: bounds,
            xRadius: BrowserChromeLayout.spaceCreationRowCornerRadius,
            yRadius: BrowserChromeLayout.spaceCreationRowCornerRadius,
        ).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.6),
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes,
        )
    }
}

// MARK: - BrowserSpaceCreationPlainButton

private final class BrowserSpaceCreationPlainButton: BrowserNativePressableView {
    private let title: String

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    override func draw(_: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: BrowserChromeColors.sidebarDimText,
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes,
        )
    }
}
