// BrowserOnboardingWindow.swift

import AppKit
import UniformTypeIdentifiers

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
        source.supportedImportItems.contains(self)
    }
}

// MARK: - BrowserOnboardingWindowController

/// The first thing a new person sees: what OpenArc is, bringing their browser across,
/// and how they want it set up. Every step can be skipped. Its look follows `DESIGN.md`:
/// blue bookends, cream working steps, one red action.
@MainActor final class BrowserOnboardingWindowController: NSObject, NSWindowDelegate {
    // MARK: Internal

    typealias Item = BrowserOnboardingImportItem

    private enum Step: CaseIterable { case welcome, importing, look, defaultBrowser, done }

    private enum ImportState {
        case choosing
        case running
        case finished(String)
    }

    // MARK: Building blocks

    private typealias Palette = BrowserOnboardingPalette

    static let minimumContentHeight: CGFloat = 560

    var onFinish: () -> Void = {}
    var importItems: (_ items: Set<Item>, _ profiles: [BrowserProfileImporter]) async -> String = { _, _ in "" }
    var setAsDefault: () -> Void = {}
    var isDefaultBrowser: () -> Bool = { false }

    private let preferences: BrowserUserPreferencesStore
    /// The whole welcome, or only the import step for Import from Another Browser.
    private let steps: [Step]
    private let window: NSWindow
    private let content = NSView()
    private let profiles = BrowserProfileImporter.detected()
    private var stepIndex = 0
    private var selectedProfile: BrowserProfileImporter?
    private var checks = [Item: NSButton]()
    private var currentStep: NSView?
    /// The browsers' height when the screen can't show every row; nil shows them all.
    private var tileHeightLimit: CGFloat?
    private var tileHeight: CGFloat = 0
    /// The browser tiles, kept across redraws of the import step so a pick
    /// changes only the selection and the tile under the pointer keeps its hover.
    private var browserTiles: (flow: BrowserOnboardingTileFlow, tiles: [BrowserOnboardingBrowserTile])?
    /// The step on screen; redrawing the same step swaps it without a fade.
    private var renderedStepIndex: Int?
    private var importState = ImportState.choosing
    private var unchecked = Set<Item>()
    /// Profile folders of the selected browser the person unticked.
    private var skippedProfiles = Set<URL>()
    private weak var importButton: BrowserOnboardingButton?
    /// Titles of each browser's Spaces by the profile folder they live in, read once.
    private var spaceTitlesBySource = [BrowserBookmarkImportSource: [String: [String]]]()

    // MARK: Private

    private var step: Step { steps[stepIndex] }

    /// The steps a person counts: the two blue bookends are not among them.
    private var countedSteps: [Step] { steps.filter { $0 != .welcome && $0 != .done } }

    private var isImportRunning: Bool {
        if case .running = importState { return true }
        return false
    }

    private var isImportFinished: Bool {
        if case .finished = importState { return true }
        return false
    }

    /// The selected browser's profiles that stay ticked.
    private var chosenProfiles: [BrowserImportProfile] {
        selectedProfile?.profiles.filter { !skippedProfiles.contains($0.directory) } ?? []
    }

    /// The tallest content the window's screen leaves room for.
    private var maximumContentHeight: CGFloat {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return .greatestFiniteMagnitude }
        let chrome = window.frame.height - content.bounds.height
        return max(visible.height - chrome, Self.minimumContentHeight)
    }

    init(preferences: BrowserUserPreferencesStore, importOnly: Bool = false) {
        self.preferences = preferences
        self.steps = importOnly ? [.importing] : Step.allCases
        self.window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: Self.minimumContentHeight),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false,
        )
        super.init()
        // The most recently used browser with something to read; Safari waits for its ZIP.
        self.selectedProfile = profiles.first { $0.hasImportableData } ?? profiles.first
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // A branded moment keeps its colors in dark mode, and native checkboxes match the paper.
        window.appearance = NSAppearance(named: .aqua)
        window.delegate = self
        content.wantsLayer = true
        window.contentView = content
        window.setAccessibilityIdentifier("browser.onboarding")
        window.center()
    }

    static func contentHeight(fitting height: CGFloat) -> CGFloat {
        max(minimumContentHeight, ceil(height))
    }

    /// A tall step's height comes from these, and the window grows to it in an
    /// animation; required, they would make AppKit resize the window at once.
    private static func belowWindowSize(_ constraint: NSLayoutConstraint) -> NSLayoutConstraint {
        constraint.priority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 1)
        return constraint
    }

    func show() {
        render()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_: Notification) { onFinish() }

    /// Every step's view, built without showing the window; tests draw them.
    func stepViewsForTesting() -> [NSView] {
        steps.indices.map { index in
            stepIndex = index
            let view = stepView()
            view.frame = NSRect(x: 0, y: 0, width: 820, height: Self.contentHeight(fitting: view.fittingSize.height))
            view.layoutSubtreeIfNeeded()
            return view
        }
    }

    private func advance() {
        if stepIndex + 1 < steps.count {
            stepIndex += 1
            render()
        } else {
            window.close()
        }
    }

    private func render() {
        tileHeightLimit = nil
        var view = stepView()
        // Every browser shows while the screen has room; past it, the
        // browsers scroll by just what does not fit.
        let overflow = Self.contentHeight(fitting: view.fittingSize.height) - maximumContentHeight
        if step == .importing, overflow > 0, tileHeight > 0 {
            tileHeightLimit = max(tileHeight - overflow, BrowserOnboardingBrowserTile.size.height)
            view = stepView()
        }
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        let previous = currentStep
        currentStep = view
        let isSameStep = renderedStepIndex == stepIndex
        renderedStepIndex = stepIndex
        // Only a new step fades in; picking a browser or finishing an import
        // swaps the step in place, so what stays the same doesn't blink.
        let fades = previous != nil && !isSameStep && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        view.alphaValue = fades ? 0 : 1
        content.addSubview(view)
        window.recalculateKeyViewLoop()
        // The new view goes up before the window resizes: the resize animates
        // and redraws, and the browser tiles have already left the old view.
        if !fades {
            previous?.removeFromSuperview()
        }
        fitWindow(to: view)
        guard fades else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            view.animator().alphaValue = 1
            previous?.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { previous?.removeFromSuperview() }
        }
    }

    private func stepView() -> NSView {
        switch step {
        case .welcome: welcomeStep()
        case .importing: importStep()
        case .look: lookStep()
        case .defaultBrowser: defaultBrowserStep()
        case .done: doneStep()
        }
    }

    /// The window keeps its width and grows to the step's height, never
    /// below the first step's, with its top edge in place.
    private func fitWindow(to view: NSView) {
        let height = min(Self.contentHeight(fitting: view.fittingSize.height), maximumContentHeight)
        guard abs(height - content.bounds.height) > 0.5 else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(
            width: content.bounds.width,
            height: height,
        )))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if let visible = window.screen?.visibleFrame, frame.minY < visible.minY {
            frame.origin.y = min(visible.minY, visible.maxY - frame.height)
        }
        window.setFrame(frame, display: true, animate: window.isVisible && currentStep != nil)
    }

    private func text(
        _ string: String,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        rounded: Bool = false,
        color: NSColor,
        alignment: NSTextAlignment = .left,
        width: CGFloat = 640,
    ) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: string)
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        label.font = rounded
            ? font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) }
                ?? font
            : font
        label.textColor = color
        label.alignment = alignment
        label.isSelectable = false
        label.drawsBackground = false
        label.preferredMaxLayoutWidth = width
        return label
    }

    /// The blue bookends: centered, cream type on the grained blue field.
    private func blueStep(_ views: [NSView], spacing: CGFloat) -> NSView {
        let field = BrowserOnboardingBlueField()
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        field.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: field.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: field.centerYAnchor, constant: 8),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
        ])
        return field
    }

    /// A working step on paper: counter, blue title, subtitle, the step's own body,
    /// and a bar with an optional note on the left and the actions on the right.
    private func paperStep(
        title: String,
        subtitle: String?,
        body: NSView?,
        note: String? = nil,
        actions: [NSView],
    ) -> NSView {
        let paper = BrowserOnboardingPaper()
        var header = [NSView]()
        if let index = countedSteps.firstIndex(of: step), countedSteps.count > 1 {
            header.append(text(
                BrowserStrings.onboardingStepCounter(index + 1, countedSteps.count),
                size: 12,
                weight: .medium,
                color: Palette.muted,
            ))
        }
        let titleLabel = text(title, size: 30, weight: .heavy, rounded: true, color: Palette.brandBlue)
        titleLabel.setAccessibilityRole(.staticText)
        header.append(titleLabel)
        if let subtitle {
            header.append(text(subtitle, size: 14, color: Palette.muted, width: 560))
        }
        let headerStack = NSStackView(views: header)
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 8
        if header.count > 2 {
            headerStack.setCustomSpacing(6, after: header[0])
        }

        let column = NSStackView(views: [headerStack] + (body.map { [$0] } ?? []))
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 28
        column.translatesAutoresizingMaskIntoConstraints = false
        paper.addSubview(column)

        let bar = NSStackView(views: actions)
        bar.orientation = .horizontal
        bar.spacing = 10
        bar.translatesAutoresizingMaskIntoConstraints = false
        paper.addSubview(bar)

        var constraints = [
            column.leadingAnchor.constraint(equalTo: paper.leadingAnchor, constant: 48),
            column.trailingAnchor.constraint(lessThanOrEqualTo: paper.trailingAnchor, constant: -48),
            column.topAnchor.constraint(equalTo: paper.topAnchor, constant: 64),
            bar.trailingAnchor.constraint(equalTo: paper.trailingAnchor, constant: -40),
            bar.bottomAnchor.constraint(equalTo: paper.bottomAnchor, constant: -32),
            Self.belowWindowSize(column.bottomAnchor.constraint(lessThanOrEqualTo: bar.topAnchor, constant: -24)),
        ]
        if let note {
            let noteLabel = text(note, size: 12, color: Palette.muted, width: 380)
            noteLabel.translatesAutoresizingMaskIntoConstraints = false
            paper.addSubview(noteLabel)
            constraints += [
                noteLabel.leadingAnchor.constraint(equalTo: paper.leadingAnchor, constant: 48),
                noteLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
                noteLabel.trailingAnchor.constraint(lessThanOrEqualTo: bar.leadingAnchor, constant: -24),
                Self.belowWindowSize(column.bottomAnchor.constraint(
                    lessThanOrEqualTo: noteLabel.topAnchor,
                    constant: -24,
                )),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        return paper
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> BrowserOnboardingButton {
        BrowserOnboardingButton(title: title, style: .primary, action: action)
    }

    private func quiet(_ title: String, onBlue: Bool = false, action: @escaping () -> Void) -> BrowserOnboardingButton {
        BrowserOnboardingButton(title: title, style: onBlue ? .quietOnBlue : .quiet, action: action)
    }

    // MARK: Steps

    private func welcomeStep() -> NSView {
        let mark = BrowserOnboardingArchMark(color: Palette.cream)
        mark.widthAnchor.constraint(equalToConstant: 44).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let title = text(
            BrowserStrings.onboardingWelcomeTitle,
            size: 46,
            weight: .heavy,
            rounded: true,
            color: Palette.cream,
            alignment: .center,
            width: 600,
        )
        let subtitle = text(
            BrowserStrings.onboardingWelcomeSubtitle,
            size: 16,
            color: Palette.cream,
            alignment: .center,
            width: 480,
        )
        let stack = blueStep([
            mark,
            title,
            subtitle,
            primary(BrowserStrings.onboardingGetStarted) { [weak self] in self?.advance() },
        ], spacing: 22)
        if let stackView = stack.subviews.first as? NSStackView {
            stackView.setCustomSpacing(28, after: mark)
            stackView.setCustomSpacing(32, after: subtitle)
        }
        return stack
    }

    private func importStep() -> NSView {
        unchecked.formUnion(checks.filter { $0.value.state == .off }.keys)
        unchecked.subtract(checks.filter { $0.value.state == .on }.keys)
        checks = [:]
        let leaving = steps.count == 1 ? BrowserStrings.cancelAction : BrowserStrings.onboardingSkip
        guard !profiles.isEmpty else {
            return paperStep(
                title: BrowserStrings.onboardingImportTitle,
                subtitle: BrowserStrings.onboardingImportNothingFound,
                body: nil,
                actions: [primary(BrowserStrings.onboardingContinue) { [weak self] in self?.advance() }],
            )
        }

        let browsers = browserTiles ?? {
            let tiles = profiles.map { profile in
                let tile = BrowserOnboardingBrowserTile(
                    name: profile.source.browserName,
                    detail: profile.lastUsed.map(BrowserStrings.onboardingUsedAgo),
                    icon: profile.applicationURL.map { NSWorkspace.shared.icon(forFile: $0.path) },
                )
                tile.onPick = { [weak self] in self?.pick(profile) }
                return tile
            }
            return (BrowserOnboardingTileFlow(tiles: tiles), tiles)
        }()
        browserTiles = browsers
        for (profile, tile) in zip(profiles, browsers.tiles) {
            tile.isSelected = profile.source == selectedProfile?.source
            tile.isEnabled = !isImportRunning
        }
        let tiles = browsers.flow

        var body: [NSView] = [scrollingIfTall(tiles)]
        if let selectedProfile, let detail = selectedProfileDetail(selectedProfile) {
            body.append(detail)
        }
        let source = selectedProfile?.source
        let available = Item.allCases.filter { item in source.map { item.isAvailable(from: $0) } ?? false }
        body.append(checkGrid(available.map { item in
            let check = importCheckbox(item.title)
            check.state = unchecked.contains(item) ? .off : .on
            check.setAccessibilityIdentifier("browser.onboarding.item.\(item.rawValue)")
            checks[item] = check
            return check
        }))

        let actions: [NSView]
        switch importState {
        case .choosing:
            let name = source?.browserName ?? ""
            let needsArchive = selectedProfile.map { $0.source.importsFromExportArchive && $0.archiveURL == nil }
                ?? false
            let importButton = needsArchive
                ? primary(BrowserStrings.onboardingChooseSafariExport) { [weak self] in self?.chooseArchive() }
                : primary(BrowserStrings.onboardingImportFrom(name)) { [weak self] in self?.runImport() }
            importButton.isEnabled = needsArchive || !chosenProfiles.isEmpty
            self.importButton = importButton
            actions = [quiet(leaving) { [weak self] in self?.advance() }, importButton]
        case .running:
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            let progress = text(
                BrowserStrings.onboardingImporting(source?.browserName ?? ""),
                size: 13,
                color: Palette.muted,
                width: 300,
            )
            let stack = NSStackView(views: [spinner, progress])
            stack.spacing = 8
            actions = [stack]
        case .finished(let result):
            body.append(BrowserOnboardingResult(text: result))
            let continueButton = primary(BrowserStrings.onboardingContinue) { [weak self] in self?.advance() }
            if result == BrowserStrings.onboardingImportResult([]) {
                // Nothing came: most often a keychain prompt was refused, which a retry asks again.
                actions = [
                    quiet(BrowserStrings.onboardingTryAgain) { [weak self] in self?.runImport() },
                    continueButton,
                ]
            } else {
                actions = [continueButton]
            }
        }

        let column = NSStackView(views: body)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 24
        return paperStep(
            title: BrowserStrings.onboardingImportTitle,
            subtitle: BrowserStrings.onboardingImportSubtitle,
            body: column,
            note: !isImportFinished && selectedProfile?.needsKeychainKey == true
                ? BrowserStrings.onboardingImportKeychainNote
                : nil,
            actions: actions,
        )
    }

    /// Browsers taller than the screen allows scroll, so the actions stay in the window.
    private func scrollingIfTall(_ tiles: BrowserOnboardingTileFlow) -> NSView {
        let size = tiles.intrinsicContentSize
        tileHeight = size.height
        guard let limit = tileHeightLimit, size.height > limit else {
            tiles.translatesAutoresizingMaskIntoConstraints = false
            return tiles
        }
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        tiles.translatesAutoresizingMaskIntoConstraints = true
        tiles.frame = NSRect(origin: .zero, size: size)
        scroll.documentView = tiles
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: size.width + 16),
            scroll.heightAnchor.constraint(equalToConstant: limit),
        ])
        return scroll
    }

    /// Under the tiles: which profile to read when the browser has several, and for
    /// Safari, which exported ZIP, since Safari keeps its data out of reach.
    private func selectedProfileDetail(_ importer: BrowserProfileImporter) -> NSView? {
        if importer.source.importsFromExportArchive {
            guard let archive = importer.archiveURL else {
                return text(BrowserStrings.onboardingSafariExportHint, size: 13, color: Palette.ink, width: 600)
            }
            let name = text(archive.lastPathComponent, size: 13, weight: .medium, color: Palette.ink, width: 400)
            let change = quiet(BrowserStrings.onboardingChooseAnother) { [weak self] in self?.chooseArchive() }
            change.isEnabled = !isImportRunning && !isImportFinished
            let row = NSStackView(views: [name, change])
            row.spacing = 8
            return row
        }
        guard importer.profiles.count > 1 else { return nil }
        let label = text(BrowserStrings.onboardingProfiles, size: 13, weight: .semibold, color: Palette.ink)
        // A browser that binds each Space to a profile names the Spaces each box brings.
        let spaces = importer.supportedItems.contains(.spaces) ? spaceTitles(of: importer.source) : [:]
        let grid = checkGrid(columns: 2, width: 330, importer.profiles.map { profile in
            let titles = spaces[profile.directory.lastPathComponent] ?? []
            let check = importCheckbox(profile.name, detail: titles.isEmpty ? nil : titles.joined(separator: ", "))
            check.state = skippedProfiles.contains(profile.directory) ? .off : .on
            check.target = self
            check.action = #selector(toggleProfile(_:))
            check.identifier = NSUserInterfaceItemIdentifier(profile.directory.path)
            return check
        })
        let column = NSStackView(views: [label, grid])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        return column
    }

    /// Checkboxes in columns of one width, so a browser with fewer items
    /// keeps the same spacing and nothing moves when another tile is picked.
    private func checkGrid(columns: Int = 3, width: CGFloat = 200, _ boxes: [NSButton]) -> NSGridView {
        let grid = NSGridView(numberOfColumns: columns, rows: 0)
        grid.rowSpacing = 10
        grid.columnSpacing = 24
        for start in stride(from: 0, to: boxes.count, by: columns) {
            let row = Array(boxes[start..<min(start + columns, boxes.count)])
            grid.addRow(with: row + Array(repeating: NSGridCell.emptyContentView, count: columns - row.count))
        }
        for index in 0..<columns {
            grid.column(at: index).width = width
        }
        grid.setContentHuggingPriority(.required, for: .horizontal)
        return grid
    }

    /// A checkbox in the paper's ink, with an optional muted detail after the title.
    private func importCheckbox(_ title: String, detail: String? = nil) -> NSButton {
        let check = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let font = NSFont.systemFont(ofSize: 13)
        let label = NSMutableAttributedString(string: title, attributes: [
            .foregroundColor: Palette.ink, .font: font, .paragraphStyle: paragraph,
        ])
        if let detail {
            label.append(NSAttributedString(string: "  " + detail, attributes: [
                .foregroundColor: Palette.muted, .font: font, .paragraphStyle: paragraph,
            ]))
        }
        check.attributedTitle = label
        check.isEnabled = !isImportRunning && !isImportFinished
        check.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return check
    }

    private func spaceTitles(of source: BrowserBookmarkImportSource) -> [String: [String]] {
        if let titles = spaceTitlesBySource[source] { return titles }
        let spaces = (try? BrowserImportedSidebar.load(source).spaces) ?? []
        let titles = Dictionary(grouping: spaces) { $0.profileDirectory ?? BrowserProfile.defaultDirectoryName }
            .mapValues { $0.compactMap(\.title) }
        spaceTitlesBySource[source] = titles
        return titles
    }

    @objc private func toggleProfile(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        if sender.state == .on {
            skippedProfiles = skippedProfiles.filter { $0.path != directory.path }
        } else if let profile = selectedProfile?.profiles.first(where: { $0.directory.path == directory.path }) {
            skippedProfiles.insert(profile.directory)
        }
        importButton?.isEnabled = !chosenProfiles.isEmpty
    }

    private func chooseArchive() {
        guard let selectedProfile else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = BrowserStrings.onboardingSafariExportHint
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let url = panel.url else { return }
                self.selectedProfile = selectedProfile.withArchive(url)
                self.importState = .choosing
                self.render()
            }
        }
    }

    private func pick(_ profile: BrowserProfileImporter) {
        guard !isImportRunning else { return }
        selectedProfile = profile
        importState = .choosing
        render()
    }

    private func runImport() {
        guard !isImportRunning, let selectedProfile else { return }
        // A browser with several profiles imports the ticked ones; with one, that one.
        let importers = selectedProfile.profiles.count > 1
            ? selectedProfile.selecting(chosenProfiles)
            : [selectedProfile]
        guard !importers.isEmpty else { return }
        let chosen = Set(checks.filter { $0.value.state == .on }.keys)
        unchecked = Set(checks.filter { $0.value.state == .off }.keys)
        importState = .running
        render()
        Task { [weak self] in
            guard let self else { return }
            let result = await importItems(chosen, importers)
            importState = .finished(result)
            render()
        }
    }

    private func lookStep() -> NSView {
        let left = BrowserOnboardingSidebarChoice(side: .left, title: BrowserStrings.onboardingSidebarLeft)
        let right = BrowserOnboardingSidebarChoice(side: .right, title: BrowserStrings.onboardingSidebarRight)
        let choices = [left, right]
        for choice in choices {
            choice.isSelected = preferences.sidebarPosition == choice.side
            choice.onPick = { [weak self] in
                self?.preferences.sidebarPosition = choice.side
                for other in choices {
                    other.isSelected = other === choice
                }
            }
        }
        let pictures = NSStackView(views: choices)
        pictures.spacing = 16

        let toolbar = checkbox(
            BrowserStrings.onboardingShowToolbar,
            isOn: preferences.siteURLToolbarEnabled,
            action: #selector(toggleToolbar(_:)),
        )
        let bookmarks = checkbox(
            BrowserStrings.settingsShowBookmarksBar,
            isOn: preferences.bookmarksBarVisible,
            action: #selector(toggleBookmarks(_:)),
        )
        let options = NSStackView(views: [toolbar, bookmarks])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 10

        let body = NSStackView(views: [pictures, options])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 24
        return paperStep(
            title: BrowserStrings.onboardingLookTitle,
            subtitle: BrowserStrings.onboardingLookSubtitle,
            body: body,
            actions: [primary(BrowserStrings.onboardingContinue) { [weak self] in self?.advance() }],
        )
    }

    private func checkbox(_ title: String, isOn: Bool, action: Selector) -> NSButton {
        let check = NSButton(checkboxWithTitle: title, target: self, action: action)
        check.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: Palette.ink, .font: NSFont.systemFont(ofSize: 13),
        ])
        check.state = isOn ? .on : .off
        return check
    }

    @objc private func toggleToolbar(_ sender: NSButton) { preferences.siteURLToolbarEnabled = sender.state == .on }
    @objc private func toggleBookmarks(_ sender: NSButton) { preferences.bookmarksBarVisible = sender.state == .on }

    private func defaultBrowserStep() -> NSView {
        guard !isDefaultBrowser() else {
            return paperStep(
                title: BrowserStrings.onboardingDefaultDone,
                subtitle: nil,
                body: nil,
                actions: [primary(BrowserStrings.onboardingContinue) { [weak self] in self?.advance() }],
            )
        }
        return paperStep(
            title: BrowserStrings.onboardingDefaultTitle,
            subtitle: BrowserStrings.onboardingDefaultSubtitle,
            body: nil,
            actions: [
                quiet(BrowserStrings.onboardingNotNow) { [weak self] in self?.advance() },
                primary(BrowserStrings.onboardingSetDefault) { [weak self] in
                    self?.setAsDefault()
                    self?.advance()
                },
            ],
        )
    }

    private func doneStep() -> NSView {
        let tips = [
            ("⌘T", BrowserStrings.onboardingTipCommandBar),
            ("⌘S", BrowserStrings.onboardingTipSidebar),
            ("⌃⇧=", BrowserStrings.onboardingTipSplit),
            ("⇧⌘D", BrowserStrings.onboardingTipToolbar),
        ]
        // Rows of a fixed-width key slot and its tip, so the block centers as a whole.
        let rows: [NSView] = tips.map { keys, tip in
            let slot = NSView()
            slot.translatesAutoresizingMaskIntoConstraints = false
            let cap = BrowserOnboardingKeycap(keys: keys)
            slot.addSubview(cap)
            NSLayoutConstraint.activate([
                slot.widthAnchor.constraint(equalToConstant: 64),
                slot.heightAnchor.constraint(equalTo: cap.heightAnchor),
                cap.trailingAnchor.constraint(equalTo: slot.trailingAnchor),
                cap.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
            ])
            let label = NSTextField(labelWithString: tip)
            label.font = .systemFont(ofSize: 14)
            label.textColor = Palette.cream
            let row = NSStackView(views: [slot, label])
            row.spacing = 16
            return row
        }
        let grid = NSStackView(views: rows)
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 12
        let mark = BrowserOnboardingArchMark(color: Palette.cream)
        mark.widthAnchor.constraint(equalToConstant: 34).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 31).isActive = true
        let field = blueStep([
            mark,
            text(
                BrowserStrings.onboardingDoneTitle,
                size: 40,
                weight: .heavy,
                rounded: true,
                color: Palette.cream,
                alignment: .center,
            ),
            grid,
            primary(BrowserStrings.onboardingStart) { [weak self] in self?.advance() },
        ], spacing: 28)
        if let stackView = field.subviews.first as? NSStackView,
           let title = stackView.arrangedSubviews.dropFirst().first
        {
            stackView.setCustomSpacing(20, after: mark)
            stackView.setCustomSpacing(30, after: title)
            stackView.setCustomSpacing(36, after: grid)
        }
        return field
    }
}

// MARK: - BrowserOnboardingPalette

/// The welcome's colors, from `DESIGN.md`.
enum BrowserOnboardingPalette {
    static let brandBlue = NSColor(srgbRed: 0x31 / 255, green: 0x39 / 255, blue: 0xFB / 255, alpha: 1)
    static let cream = NSColor(srgbRed: 0xFF / 255, green: 0xFA / 255, blue: 0xDD / 255, alpha: 1)
    static let paper = NSColor(srgbRed: 0xFF / 255, green: 0xFC / 255, blue: 0xEC / 255, alpha: 1)
    static let ink = NSColor(srgbRed: 0x1B / 255, green: 0x1D / 255, blue: 0x3A / 255, alpha: 1)
    static let muted = NSColor(srgbRed: 0x5B / 255, green: 0x5B / 255, blue: 0x6B / 255, alpha: 1)
    static let actionRed = NSColor(srgbRed: 0xE5 / 255, green: 0x26 / 255, blue: 0x2B / 255, alpha: 1)
    static let tile = NSColor(srgbRed: 0xF3 / 255, green: 0xEF / 255, blue: 0xD6 / 255, alpha: 1)
    static let tileHover = NSColor(srgbRed: 0xEC / 255, green: 0xE7 / 255, blue: 0xCB / 255, alpha: 1)
}

// MARK: - BrowserOnboardingBlueField

/// The brand's blue with fine grain, as on the site's hero: printed, not glowing.
final class BrowserOnboardingBlueField: NSView {
    private static let grain: NSImage = {
        let size = 128
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        var generator = SystemRandomNumberGenerator()
        for index in stride(from: 0, to: pixels.count, by: 4) {
            // Premultiplied white at up to 7% alpha.
            let alpha = UInt8.random(in: 0...18, using: &generator)
            pixels[index] = alpha
            pixels[index + 1] = alpha
            pixels[index + 2] = alpha
            pixels[index + 3] = alpha
        }
        let image = pixels.withUnsafeMutableBytes { bytes -> CGImage? in
            CGContext(
                data: bytes.baseAddress,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
            )?.makeImage()
        }
        return image.map { NSImage(cgImage: $0, size: NSSize(width: size / 2, height: size / 2)) } ?? NSImage()
    }()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        BrowserOnboardingPalette.brandBlue.setFill()
        dirtyRect.fill()
        NSColor(patternImage: Self.grain).setFill()
        dirtyRect.fill(using: .sourceOver)
    }
}

// MARK: - BrowserOnboardingPaper

final class BrowserOnboardingPaper: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        BrowserOnboardingPalette.paper.setFill()
        dirtyRect.fill()
    }
}

// MARK: - BrowserOnboardingArchMark

/// The arch from the app icon and the site's top bar.
final class BrowserOnboardingArchMark: NSView {
    override var isFlipped: Bool { true }

    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_: NSRect) {
        // The site's 40 × 36 logo path.
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 20, y: 3))
        path.curve(
            to: NSPoint(x: 27.5, y: 10),
            controlPoint1: NSPoint(x: 24, y: 3),
            controlPoint2: NSPoint(x: 26, y: 6),
        )
        path.line(to: NSPoint(x: 35, y: 28))
        path.curve(to: NSPoint(x: 32, y: 33), controlPoint1: NSPoint(x: 36, y: 30.5), controlPoint2: NSPoint(
            x: 34.5,
            y: 33,
        ))
        path.curve(to: NSPoint(x: 28, y: 29.6), controlPoint1: NSPoint(x: 30, y: 33), controlPoint2: NSPoint(
            x: 29,
            y: 31.8,
        ))
        path.line(to: NSPoint(x: 20, y: 12))
        path.line(to: NSPoint(x: 12, y: 29.6))
        path.curve(
            to: NSPoint(x: 8, y: 33),
            controlPoint1: NSPoint(x: 11, y: 31.8),
            controlPoint2: NSPoint(x: 10, y: 33),
        )
        path.curve(
            to: NSPoint(x: 5, y: 28),
            controlPoint1: NSPoint(x: 5.5, y: 33),
            controlPoint2: NSPoint(x: 4, y: 30.5),
        )
        path.line(to: NSPoint(x: 12.5, y: 10))
        path.curve(to: NSPoint(x: 20, y: 3), controlPoint1: NSPoint(x: 14, y: 6), controlPoint2: NSPoint(x: 16, y: 3))
        path.close()
        let scale = min(bounds.width / 40, bounds.height / 36)
        let transform = AffineTransform(scale: scale)
        path.transform(using: transform)
        color.setFill()
        path.fill()
    }
}

// MARK: - BrowserOnboardingButton

/// The welcome's buttons: one red primary per step, answering Return, and quiet text buttons.
final class BrowserOnboardingButton: NSButton {
    enum Style { case primary, quiet, quietOnBlue }

    override var intrinsicContentSize: NSSize {
        let size = attributedTitle.size()
        return NSSize(width: ceil(size.width) + 36, height: 36)
    }

    override var isHighlighted: Bool {
        didSet { refresh() }
    }

    override var isEnabled: Bool {
        didSet { refresh() }
    }

    override var focusRingMaskBounds: NSRect { bounds }

    private let handler: () -> Void
    private let style: Style
    private var isHovered = false
    private var tracking: NSTrackingArea?

    init(title: String, style: Style, action: @escaping () -> Void) {
        self.handler = action
        self.style = style
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        wantsLayer = true
        focusRingType = .exterior
        target = self
        self.action = #selector(pressed)
        if style == .primary {
            keyEquivalent = "\r"
        }
        setAccessibilityIdentifier("browser.onboarding.button")
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: style == .primary ? 120 : 64).isActive = true
        refresh()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with _: NSEvent) {
        isHovered = true
        refresh()
    }

    override func mouseExited(with _: NSEvent) {
        isHovered = false
        refresh()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isEnabled ? .pointingHand : .arrow)
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
    }

    override func draw(_: NSRect) {
        let palette = BrowserOnboardingPalette.self
        let fill: NSColor? =
            switch style {
            case .primary:
                isHighlighted
                    ? palette.actionRed.blended(withFraction: 0.18, of: .black)
                    : isHovered ? palette.actionRed.blended(withFraction: 0.08, of: .black) : palette.actionRed
            case .quiet:
                isHighlighted
                    ? palette.ink.withAlphaComponent(0.12)
                    : isHovered ? palette.ink.withAlphaComponent(0.06) : nil
            case .quietOnBlue:
                isHighlighted
                    ? palette.cream.withAlphaComponent(0.24)
                    : isHovered ? palette.cream.withAlphaComponent(0.14) : nil
            }
        if let fill {
            (isEnabled ? fill : fill.withAlphaComponent(0.4)).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        }
        let size = attributedTitle.size()
        attributedTitle.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    private func refresh() {
        let palette = BrowserOnboardingPalette.self
        let color: NSColor =
            switch style {
            case .primary: .white
            case .quiet: palette.ink
            case .quietOnBlue: palette.cream
            }
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: isEnabled ? color : color.withAlphaComponent(0.45),
            .font: NSFont.systemFont(ofSize: 14, weight: style == .primary ? .semibold : .medium),
        ])
        needsDisplay = true
    }

    @objc private func pressed() { handler() }
}

// MARK: - BrowserOnboardingSelectableTile

/// A tile picked by click, Space or Return, marked by a blue ring rather than elevation.
class BrowserOnboardingSelectableTile: NSControl {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    override var focusRingMaskBounds: NSRect { bounds }

    var onPick: () -> Void = {}
    var isSelected = false {
        didSet {
            needsDisplay = true
            setAccessibilityValue(isSelected ? 1 : 0)
        }
    }

    private(set) var isHovered = false

    private var isPressedDown = false
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with _: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with _: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func mouseDown(with _: NSEvent) {
        guard isEnabled else { return }
        isPressedDown = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressedDown else { return }
        isPressedDown = false
        needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onPick()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            onPick()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onPick()
        return true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isEnabled ? .pointingHand : .arrow)
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
    }

    func drawTileBackground() {
        let palette = BrowserOnboardingPalette.self
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 13, yRadius: 13)
        (isPressedDown || (isHovered && isEnabled) ? palette.tileHover : palette.tile).setFill()
        shape.fill()
        if isSelected {
            palette.brandBlue.setStroke()
            shape.lineWidth = 2
            shape.stroke()
        }
    }
}

// MARK: - BrowserOnboardingBrowserTile

/// A browser found on this Mac: its own icon, its name and when it was last used.
final class BrowserOnboardingBrowserTile: BrowserOnboardingSelectableTile {
    static let size = NSSize(width: 132, height: 112)

    private let name: String
    private let detail: String?
    private let icon: NSImage?

    init(name: String, detail: String?, icon: NSImage?) {
        self.name = name
        self.detail = detail
        self.icon = icon
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        setAccessibilityLabel([name, detail].compactMap(\.self).joined(separator: ", "))
        widthAnchor.constraint(equalToConstant: Self.size.width).isActive = true
        heightAnchor.constraint(equalToConstant: Self.size.height).isActive = true
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_: NSRect) {
        drawTileBackground()
        let palette = BrowserOnboardingPalette.self
        let alpha: CGFloat = isEnabled ? 1 : 0.5
        let iconRect = NSRect(x: (bounds.width - 48) / 2, y: 16, width: 48, height: 48)
        if let icon {
            icon.draw(
                in: iconRect,
                from: .zero,
                operation: .sourceOver,
                fraction: alpha,
                respectFlipped: true,
                hints: nil,
            )
        } else {
            palette.ink.withAlphaComponent(0.1 * alpha).setFill()
            NSBezierPath(roundedRect: iconRect.insetBy(dx: 4, dy: 4), xRadius: 9, yRadius: 9).fill()
        }
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        centered.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: palette.ink.withAlphaComponent(alpha),
            .paragraphStyle: centered,
        ]).draw(in: NSRect(x: 8, y: 70, width: bounds.width - 16, height: 17))
        if let detail {
            NSAttributedString(string: detail, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: palette.muted.withAlphaComponent(alpha),
                .paragraphStyle: centered,
            ]).draw(in: NSRect(x: 6, y: 88, width: bounds.width - 12, height: 15))
        }
    }
}

// MARK: - BrowserOnboardingTileFlow

/// Browser tiles in rows, five to a row.
final class BrowserOnboardingTileFlow: NSView {
    private static let spacing: CGFloat = 12
    private static let perRow = 5

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let columns = min(tiles.count, Self.perRow)
        let rows = (tiles.count + Self.perRow - 1) / Self.perRow
        let size = BrowserOnboardingBrowserTile.size
        return NSSize(
            width: CGFloat(columns) * size.width + CGFloat(max(columns - 1, 0)) * Self.spacing,
            height: CGFloat(rows) * size.height + CGFloat(max(rows - 1, 0)) * Self.spacing,
        )
    }

    private let tiles: [BrowserOnboardingBrowserTile]

    init(tiles: [BrowserOnboardingBrowserTile]) {
        self.tiles = tiles
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for tile in tiles {
            tile.translatesAutoresizingMaskIntoConstraints = true
            addSubview(tile)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let size = BrowserOnboardingBrowserTile.size
        for (index, tile) in tiles.enumerated() {
            let column = index % Self.perRow
            let row = index / Self.perRow
            tile.frame = NSRect(
                x: CGFloat(column) * (size.width + Self.spacing),
                y: CGFloat(row) * (size.height + Self.spacing),
                width: size.width,
                height: size.height,
            )
        }
    }
}

// MARK: - BrowserOnboardingSidebarChoice

/// A small window drawing with the sidebar on one side, so the choice shows what it does.
final class BrowserOnboardingSidebarChoice: BrowserOnboardingSelectableTile {
    let side: BrowserSidebarPosition

    private let title: String

    init(side: BrowserSidebarPosition, title: String) {
        self.side = side
        self.title = title
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 150))
        setAccessibilityLabel(title)
        widthAnchor.constraint(equalToConstant: 200).isActive = true
        heightAnchor.constraint(equalToConstant: 150).isActive = true
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_: NSRect) {
        drawTileBackground()
        let palette = BrowserOnboardingPalette.self
        let frame = NSRect(x: 20, y: 16, width: bounds.width - 40, height: 92)
        let window = NSBezierPath(roundedRect: frame, xRadius: 7, yRadius: 7)
        palette.paper.setFill()
        window.fill()
        palette.ink.withAlphaComponent(0.35).setStroke()
        window.lineWidth = 1
        window.stroke()

        let sidebarWidth: CGFloat = 40
        let sidebar = NSRect(
            x: side == .left ? frame.minX + 4 : frame.maxX - 4 - sidebarWidth,
            y: frame.minY + 4,
            width: sidebarWidth,
            height: frame.height - 8,
        )
        palette.brandBlue.withAlphaComponent(isSelected ? 0.9 : 0.35).setFill()
        NSBezierPath(roundedRect: sidebar, xRadius: 4, yRadius: 4).fill()
        palette.cream.withAlphaComponent(0.85).setFill()
        for row in 0..<4 {
            NSBezierPath(
                roundedRect: NSRect(
                    x: sidebar.minX + 6,
                    y: sidebar.minY + 10 + CGFloat(row) * 12,
                    width: sidebarWidth - 12,
                    height: 5,
                ),
                xRadius: 2.5,
                yRadius: 2.5,
            ).fill()
        }
        let pageX = side == .left ? sidebar.maxX + 8 : frame.minX + 8
        let pageWidth = frame.width - sidebarWidth - 20
        palette.ink.withAlphaComponent(0.14).setFill()
        for (row, fraction) in [0.9, 0.7, 0.8, 0.5].enumerated() {
            NSBezierPath(
                roundedRect: NSRect(
                    x: pageX,
                    y: frame.minY + 14 + CGFloat(row) * 14,
                    width: pageWidth * fraction,
                    height: 6,
                ),
                xRadius: 3,
                yRadius: 3,
            ).fill()
        }

        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: isSelected ? .semibold : .regular),
            .foregroundColor: palette.ink,
            .paragraphStyle: centered,
        ]).draw(in: NSRect(x: 8, y: 118, width: bounds.width - 16, height: 18))
    }
}

// MARK: - BrowserOnboardingKeycap

/// A shortcut drawn as a key outline in cream, the last screen's motif.
final class BrowserOnboardingKeycap: NSView {
    private let label: NSTextField

    init(keys: String) {
        self.label = NSTextField(labelWithString: keys)
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = BrowserOnboardingPalette.cream
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1.5
        layer?.borderColor = BrowserOnboardingPalette.cream.withAlphaComponent(0.8).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 28),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(keys)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - BrowserOnboardingResult

/// What an import brought over, or why nothing came.
final class BrowserOnboardingResult: NSView {
    init(text: String) {
        super.init(frame: .zero)
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = BrowserOnboardingPalette.ink
        label.preferredMaxLayoutWidth = 680
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
