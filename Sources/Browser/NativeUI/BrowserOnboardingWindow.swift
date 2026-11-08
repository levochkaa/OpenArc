// BrowserOnboardingWindow.swift

import AppKit

// MARK: - BrowserOnboardingImportItem

enum BrowserOnboardingImportItem: String, CaseIterable {
    case spaces
    case bookmarks
    case passwords
    case history
    case signIns
    case extensions
    case siteSearches

    @MainActor var title: String {
        switch self {
        case .spaces: BrowserStrings.onboardingItemSpaces
        case .bookmarks: BrowserStrings.onboardingItemBookmarks
        case .passwords: BrowserStrings.onboardingItemPasswords
        case .history: BrowserStrings.onboardingItemHistory
        case .signIns: BrowserStrings.onboardingItemSignIns
        case .extensions: BrowserStrings.onboardingItemExtensions
        case .siteSearches: BrowserStrings.onboardingItemSiteSearches
        }
    }

    func isAvailable(from source: BrowserBookmarkImportSource) -> Bool {
        self != .spaces || source == .arc
    }
}

// MARK: - BrowserOnboardingWindowController

/// The first thing a new person sees: what OpenArc is, bringing their browser across,
/// and how they want it set up. Every step can be skipped.
@MainActor final class BrowserOnboardingWindowController: NSObject, NSWindowDelegate {
    // MARK: Internal

    typealias Item = BrowserOnboardingImportItem

    private enum Step: CaseIterable { case welcome, importing, look, defaultBrowser, done }

    var onFinish: () -> Void = {}
    var importItems: (_ items: Set<Item>, _ profile: BrowserProfileImporter) async -> String = { _, _ in "" }
    var setAsDefault: () -> Void = {}
    var isDefaultBrowser: () -> Bool = { false }

    private let preferences: BrowserUserPreferencesStore
    /// The whole welcome, or only the import step for Import from Another Browser.
    private let steps: [Step]
    private let window: NSWindow
    private let content = BrowserOnboardingBackdrop()
    private let profiles = BrowserProfileImporter.detected()
    private var stepIndex = 0
    private var selectedProfile: BrowserProfileImporter?
    private var checks = [Item: NSButton]()
    private var currentStep: NSView?
    private var importResult: String?
    private var isImporting = false
    private var unchecked = Set<Item>()

    // MARK: Private

    private var step: Step { steps[stepIndex] }

    init(preferences: BrowserUserPreferencesStore, importOnly: Bool = false) {
        self.preferences = preferences
        self.steps = importOnly ? [.importing] : Step.allCases
        self.window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false,
        )
        super.init()
        self.selectedProfile = profiles.first { $0.source == .arc } ?? profiles.first
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = content
        window.setAccessibilityIdentifier("browser.onboarding")
        window.center()
    }

    func show() {
        render()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_: Notification) { onFinish() }

    private func advance() {
        if stepIndex + 1 < steps.count {
            stepIndex += 1
            render()
        } else {
            window.close()
        }
    }

    private func render() {
        let view =
            switch step {
            case .welcome: welcomeStep()
            case .importing: importStep()
            case .look: lookStep()
            case .defaultBrowser: defaultBrowserStep()
            case .done: doneStep()
            }
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        view.alphaValue = 0
        content.addSubview(view)
        let previous = currentStep
        currentStep = view
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            view.animator().alphaValue = 1
            previous?.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { previous?.removeFromSuperview() }
        }
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat = 1) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = NSColor.white.withAlphaComponent(alpha)
        label.alignment = .center
        label.isSelectable = false
        label.drawsBackground = false
        label.preferredMaxLayoutWidth = 560
        return label
    }

    private func button(
        _ title: String,
        primary: Bool = true,
        action: @escaping () -> Void,
    ) -> BrowserOnboardingButton {
        BrowserOnboardingButton(title: title, primary: primary, action: action)
    }

    /// Lays a step out as a centered column.
    private func column(_ views: [NSView], spacing: CGFloat = 16) -> NSView {
        let container = NSView()
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
        ])
        return container
    }

    private func welcomeStep() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true
        return column([
            icon,
            label(BrowserStrings.onboardingWelcomeTitle, size: 38, weight: .bold),
            label(BrowserStrings.onboardingWelcomeSubtitle, size: 16, weight: .regular, alpha: 0.8),
            button(BrowserStrings.onboardingGetStarted) { [weak self] in self?.advance() },
        ], spacing: 20)
    }

    private func importStep() -> NSView {
        unchecked = Set(checks.filter { $0.value.state == .off }.keys)
        guard !profiles.isEmpty else {
            return column([
                label(BrowserStrings.onboardingImportTitle, size: 30, weight: .bold),
                label(BrowserStrings.onboardingImportNothingFound, size: 15, weight: .regular, alpha: 0.8),
                button(BrowserStrings.onboardingContinue) { [weak self] in self?.advance() },
            ])
        }
        var views: [NSView] = [
            label(BrowserStrings.onboardingImportTitle, size: 30, weight: .bold),
            label(BrowserStrings.onboardingImportSubtitle, size: 15, weight: .regular, alpha: 0.8),
        ]
        if profiles.count > 1 {
            let picker = NSSegmentedControl(
                labels: profiles.map(\.source.browserName),
                trackingMode: .selectOne,
                target: self,
                action: #selector(pickProfile(_:)),
            )
            picker.selectedSegment = profiles.firstIndex { $0.source == selectedProfile?.source } ?? 0
            picker.setAccessibilityIdentifier("browser.onboarding.source")
            views.append(picker)
        }
        checks = [:]
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 10
        grid.columnSpacing = 28
        let available = Item.allCases.filter { item in
            selectedProfile.map { item.isAvailable(from: $0.source) } ?? false
        }
        var row = [NSView]()
        for item in available {
            let check = NSButton(checkboxWithTitle: item.title, target: nil, action: nil)
            check.state = unchecked.contains(item) ? .off : .on
            check.attributedTitle = NSAttributedString(string: item.title, attributes: [
                .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            ])
            check.setAccessibilityIdentifier("browser.onboarding.item.\(item.rawValue)")
            checks[item] = check
            row.append(check)
            if row.count == 2 {
                grid.addRow(with: row)
                row = []
            }
        }
        if !row.isEmpty {
            grid.addRow(with: row + [NSGridCell.emptyContentView])
        }
        views.append(grid)
        views.append(label(BrowserStrings.onboardingImportKeychainNote, size: 12, weight: .regular, alpha: 0.65))
        if let importResult {
            views.append(label(importResult, size: 13, weight: .medium, alpha: 0.95))
        }
        let actions = NSStackView(views: [
            button(
                steps.count == 1 ? BrowserStrings.cancelAction : BrowserStrings.onboardingSkip,
                primary: false,
            ) { [weak self] in
                self?.advance()
            },
            button(importResult == nil
                ? BrowserStrings.onboardingImport
                : BrowserStrings
                    .onboardingContinue)
            { [weak self] in
                guard let self else { return }
                if importResult == nil { runImport() } else { advance() }
            },
        ])
        actions.spacing = 12
        views.append(actions)
        return column(views, spacing: 18)
    }

    @objc private func pickProfile(_ sender: NSSegmentedControl) {
        selectedProfile = profiles[sender.selectedSegment]
        importResult = nil
        render()
    }

    private func runImport() {
        guard !isImporting, let selectedProfile else { return }
        isImporting = true
        let chosen = Set(checks.filter { $0.value.state == .on }.keys)
        Task { [weak self] in
            guard let self else { return }
            importResult = await importItems(chosen, selectedProfile)
            isImporting = false
            render()
        }
    }

    private func lookStep() -> NSView {
        let position = NSSegmentedControl(
            labels: [BrowserStrings.onboardingSidebarLeft, BrowserStrings.onboardingSidebarRight],
            trackingMode: .selectOne,
            target: self,
            action: #selector(pickSidebarPosition(_:)),
        )
        position.selectedSegment = preferences.sidebarPosition == .left ? 0 : 1
        let toolbar = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleToolbar(_:)))
        toolbar.attributedTitle = NSAttributedString(string: BrowserStrings.onboardingShowToolbar, attributes: [
            .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 14, weight: .medium),
        ])
        toolbar.state = preferences.siteURLToolbarEnabled ? .on : .off
        let bookmarks = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleBookmarks(_:)))
        bookmarks.attributedTitle = NSAttributedString(string: BrowserStrings.settingsShowBookmarksBar, attributes: [
            .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 14, weight: .medium),
        ])
        bookmarks.state = preferences.bookmarksBarVisible ? .on : .off
        return column([
            label(BrowserStrings.onboardingLookTitle, size: 30, weight: .bold),
            label(BrowserStrings.onboardingLookSubtitle, size: 15, weight: .regular, alpha: 0.8),
            position,
            toolbar,
            bookmarks,
            button(BrowserStrings.onboardingContinue) { [weak self] in self?.advance() },
        ], spacing: 18)
    }

    @objc private func pickSidebarPosition(_ sender: NSSegmentedControl) {
        preferences.sidebarPosition = sender.selectedSegment == 0 ? .left : .right
    }

    @objc private func toggleToolbar(_ sender: NSButton) { preferences.siteURLToolbarEnabled = sender.state == .on }
    @objc private func toggleBookmarks(_ sender: NSButton) { preferences.bookmarksBarVisible = sender.state == .on }

    private func defaultBrowserStep() -> NSView {
        guard !isDefaultBrowser() else {
            return column([
                label(BrowserStrings.onboardingDefaultDone, size: 30, weight: .bold),
                button(BrowserStrings.onboardingContinue) { [weak self] in self?.advance() },
            ])
        }
        let actions = NSStackView(views: [
            button(BrowserStrings.onboardingNotNow, primary: false) { [weak self] in self?.advance() },
            button(BrowserStrings.onboardingSetDefault) { [weak self] in
                self?.setAsDefault()
                self?.advance()
            },
        ])
        actions.spacing = 12
        return column([
            label(BrowserStrings.onboardingDefaultTitle, size: 30, weight: .bold),
            label(BrowserStrings.onboardingDefaultSubtitle, size: 15, weight: .regular, alpha: 0.8),
            actions,
        ], spacing: 18)
    }

    private func doneStep() -> NSView {
        let tips = [
            ("⌘T", BrowserStrings.onboardingTipCommandBar),
            ("⌘S", BrowserStrings.onboardingTipSidebar),
            ("⌃⇧=", BrowserStrings.onboardingTipSplit),
            ("⇧⌘D", BrowserStrings.onboardingTipToolbar),
        ]
        let grid = NSGridView(views: tips.map { key, text in
            let keyLabel = label(key, size: 14, weight: .semibold)
            keyLabel.alignment = .right
            let textLabel = label(text, size: 14, weight: .regular, alpha: 0.85)
            textLabel.alignment = .left
            return [keyLabel, textLabel]
        })
        grid.rowSpacing = 10
        grid.columnSpacing = 18
        return column([
            label(BrowserStrings.onboardingDoneTitle, size: 34, weight: .bold),
            grid,
            button(BrowserStrings.onboardingStart) { [weak self] in self?.advance() },
        ], spacing: 24)
    }
}

// MARK: - BrowserOnboardingBackdrop

/// A slow gradient behind the welcome window.
final class BrowserOnboardingBackdrop: NSView {
    private let gradient = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        gradient.colors = [
            NSColor(red: 0.11, green: 0.09, blue: 0.42, alpha: 1).cgColor,
            NSColor(red: 0.56, green: 0.16, blue: 0.62, alpha: 1).cgColor,
            NSColor(red: 0.95, green: 0.33, blue: 0.40, alpha: 1).cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        layer?.addSublayer(gradient)
        let drift = CABasicAnimation(keyPath: "endPoint")
        drift.fromValue = CGPoint(x: 1, y: 0)
        drift.toValue = CGPoint(x: 0.4, y: 0.1)
        drift.duration = 14
        drift.autoreverses = true
        drift.repeatCount = .infinity
        drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        gradient.add(drift, forKey: "drift")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - BrowserOnboardingButton

final class BrowserOnboardingButton: NSButton {
    private let handler: () -> Void

    init(title: String, primary: Bool, action: @escaping () -> Void) {
        self.handler = action
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = primary ? NSColor.white.cgColor : NSColor.white.withAlphaComponent(0.18).cgColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: primary ? NSColor.black : NSColor.white,
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
        ])
        target = self
        self.action = #selector(pressed)
        if primary {
            keyEquivalent = "\r"
        }
        setAccessibilityIdentifier("browser.onboarding.button")
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 40).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func pressed() { handler() }
}
