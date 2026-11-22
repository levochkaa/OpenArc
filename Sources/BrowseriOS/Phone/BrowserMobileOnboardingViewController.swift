// BrowserMobileOnboardingViewController.swift

import UIKit

// MARK: - BrowserMobileOnboarding

/// Whether the welcome still has to show: once on the first launch, and again
/// from Settings ▸ Show Onboarding.
enum BrowserMobileOnboarding {
    static let doneKey = "browser.mobile.onboardingDone"

    static func isNeeded(_ defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: doneKey)
    }

    static func markDone(_ defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: doneKey)
    }

    /// The welcome's steps, the default browser one only when the build can be one.
    static func steps(canBeDefaultBrowser: Bool) -> [BrowserMobileOnboardingViewController.Step] {
        [.welcome, .tour, .icon, .blocking] + (canBeDefaultBrowser ? [.defaultBrowser] : []) + [.done]
    }
}

// MARK: - BrowserMobileOnboardingViewController

/// The iPhone's welcome, a branded moment like the Mac's: blue bookends with
/// cream type, working steps on paper, one red action on each. Every step
/// can be skipped, and what it sets is in Settings later.
final class BrowserMobileOnboardingViewController: UIViewController {
    // MARK: Lifecycle

    init(defaults: UserDefaults = .standard, canBeDefaultBrowser: Bool = BrowserMobileDefaultBrowser.isAvailable) {
        self.defaults = defaults
        steps = BrowserMobileOnboarding.steps(canBeDefaultBrowser: canBeDefaultBrowser)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
        overrideUserInterfaceStyle = .light
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Internal

    enum Step: Equatable {
        case welcome
        case tour
        case icon
        case blocking
        case defaultBrowser
        case done
    }

    /// Shows the welcome over whatever `controller` shows.
    static func present(over controller: UIViewController, defaults: UserDefaults = .standard) {
        var top = controller
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        top.present(BrowserMobileOnboardingViewController(defaults: defaults), animated: true)
    }

    /// The first launch's welcome.
    static func presentIfNeeded(over controller: UIViewController, defaults: UserDefaults = .standard) {
        guard BrowserMobileOnboarding.isNeeded(defaults) else { return }
        present(over: controller, defaults: defaults)
    }

    private(set) var step: Step = .welcome

    override var preferredStatusBarStyle: UIStatusBarStyle {
        step == .welcome || step == .done ? .lightContent : .darkContent
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "browser.onboarding"
        show(steps[0], animated: false)
    }

    /// Goes to the next step, or closes after the last.
    func advance() {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else {
            finish()
            return
        }
        show(steps[index + 1], animated: true)
    }

    func finish() {
        BrowserMobileOnboarding.markDone(defaults)
        dismiss(animated: true)
    }

    // MARK: Private

    private enum Palette {
        static let brandBlue = UIColor(red: 0x31 / 255, green: 0x39 / 255, blue: 0xFB / 255, alpha: 1)
        static let cream = UIColor(red: 0xFF / 255, green: 0xFA / 255, blue: 0xDD / 255, alpha: 1)
        static let paper = UIColor(red: 0xFF / 255, green: 0xFC / 255, blue: 0xEC / 255, alpha: 1)
        static let ink = UIColor(red: 0x1B / 255, green: 0x1D / 255, blue: 0x3A / 255, alpha: 1)
        static let muted = UIColor(red: 0x5B / 255, green: 0x5B / 255, blue: 0x6B / 255, alpha: 1)
        static let actionRed = UIColor(red: 0xE5 / 255, green: 0x26 / 255, blue: 0x2B / 255, alpha: 1)
        static let tile = UIColor(red: 0xF3 / 255, green: 0xEF / 255, blue: 0xD6 / 255, alpha: 1)
    }

    private let defaults: UserDefaults
    private let steps: [Step]
    private var stepView: UIView?

    private func show(_ step: Step, animated: Bool) {
        self.step = step
        let next = makeView(for: step)
        next.frame = view.bounds
        next.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let previous = stepView
        stepView = next
        view.addSubview(next)
        setNeedsStatusBarAppearanceUpdate()
        guard animated, let previous, !UIAccessibility.isReduceMotionEnabled else {
            previous?.removeFromSuperview()
            UIAccessibility.post(notification: .screenChanged, argument: next)
            return
        }
        next.alpha = 0
        UIView.animate(withDuration: 0.25, animations: { next.alpha = 1 }, completion: { _ in
            previous.removeFromSuperview()
            UIAccessibility.post(notification: .screenChanged, argument: next)
        })
    }

    private func makeView(for step: Step) -> UIView {
        switch step {
        case .welcome:
            blueStep(
                title: BrowserStrings.onboardingWelcomeTitle,
                subtitle: String(
                    localized: "Your Spaces and pinned tabs, now in your pocket. A few steps set it up.",
                    table: "Mobile",
                ),
                action: BrowserStrings.onboardingGetStarted,
                showsSkip: true,
            )
        case .tour:
            paperStep(
                title: String(localized: "Made for one hand", table: "Mobile"),
                subtitle: nil,
                body: tourBody(),
            )
        case .icon:
            paperStep(
                title: String(localized: "Pick an icon for your Home Screen", table: "Mobile"),
                subtitle: String(localized: "You can change it later in Settings.", table: "Mobile"),
                body: iconBody(),
            )
        case .blocking:
            paperStep(
                title: String(localized: "Pages without the noise", table: "Mobile"),
                subtitle: String(
                    localized: "OpenArc blocks these on every site. Allow one back for a site from its menu.",
                    table: "Mobile",
                ),
                body: blockingBody(),
            )
        case .defaultBrowser:
            paperStep(
                title: BrowserStrings.onboardingDefaultTitle,
                subtitle: BrowserStrings.onboardingDefaultSubtitle,
                body: nil,
                action: BrowserStrings.onboardingSetDefault,
                perform: { [weak self] in
                    BrowserMobileDefaultBrowser.openSystemSettings()
                    self?.advance()
                },
                quietAction: BrowserStrings.onboardingNotNow,
            )
        case .done:
            blueStep(
                title: BrowserStrings.onboardingDoneTitle,
                subtitle: String(
                    localized: "Swipe the bar at the bottom to switch tabs, or tap it to search.",
                    table: "Mobile",
                ),
                action: BrowserStrings.onboardingStart,
                showsSkip: false,
            )
        }
    }

    // MARK: Step layouts

    /// A bookend: the arch mark and centered cream type on the grained blue field,
    /// the action at the bottom.
    private func blueStep(title: String, subtitle: String, action: String, showsSkip: Bool) -> UIView {
        let field = BrowserMobileOnboardingBlueField()
        field.accessibilityIdentifier = "browser.onboarding.\(step)"
        let mark = BrowserMobileOnboardingArchMark(color: Palette.cream)
        let titleLabel = label(title, style: .largeTitle, size: 40, weight: .heavy, rounded: true, color: Palette.cream)
        titleLabel.textAlignment = .center
        titleLabel.accessibilityTraits = .header
        let subtitleLabel = label(subtitle, style: .body, size: 17, weight: .regular, color: Palette.cream)
        subtitleLabel.textAlignment = .center
        let column = UIStackView(arrangedSubviews: [mark, titleLabel, subtitleLabel])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = 18
        column.setCustomSpacing(28, after: mark)
        var actions: [UIView] = [primaryButton(action) { [weak self] in self?.advance() }]
        if showsSkip {
            actions.append(quietButton(BrowserStrings.onboardingSkip, color: Palette.cream) { [weak self] in
                self?.finish()
            })
        }
        let bar = actionBar(actions)
        for view in [column, bar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            field.addSubview(view)
        }
        let guide = field.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: 44),
            mark.heightAnchor.constraint(equalToConstant: 40),
            column.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 28),
            column.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -28),
            column.centerYAnchor.constraint(equalTo: guide.centerYAnchor, constant: -40),
            bar.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
            bar.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
            bar.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12),
            column.bottomAnchor.constraint(lessThanOrEqualTo: bar.topAnchor, constant: -24),
        ])
        return field
    }

    /// A working step on paper: Skip at the top, a blue title, the step's own
    /// body, and the red action at the bottom.
    private func paperStep(
        title: String,
        subtitle: String?,
        body: UIView?,
        action: String = BrowserStrings.onboardingContinue,
        perform: (() -> Void)? = nil,
        quietAction: String? = nil,
    ) -> UIView {
        let paper = UIView()
        paper.backgroundColor = Palette.paper
        paper.accessibilityIdentifier = "browser.onboarding.\(step)"
        let skip = quietButton(BrowserStrings.onboardingSkip, color: Palette.brandBlue) { [weak self] in self?.finish() }
        skip.accessibilityIdentifier = "browser.onboarding.skip"
        let titleLabel = label(title, style: .title1, size: 30, weight: .heavy, rounded: true, color: Palette.brandBlue)
        titleLabel.accessibilityTraits = .header
        var views: [UIView] = [titleLabel]
        if let subtitle {
            views.append(label(subtitle, style: .body, size: 17, weight: .regular, color: Palette.muted))
        }
        if let body { views.append(body) }
        let column = UIStackView(arrangedSubviews: views)
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = 10
        if body != nil { column.setCustomSpacing(28, after: views[views.count - 2]) }
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = false
        scroll.addSubview(column)
        var actions: [UIView] = [primaryButton(action) { [weak self] in
            if let perform { perform() } else { self?.advance() }
        }]
        if let quietAction {
            actions.append(quietButton(quietAction, color: Palette.brandBlue) { [weak self] in self?.advance() })
        }
        let bar = actionBar(actions)
        for view in [skip, scroll, bar, column] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        for view in [skip, scroll, bar] {
            paper.addSubview(view)
        }
        let guide = paper.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            skip.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
            skip.topAnchor.constraint(equalTo: guide.topAnchor, constant: 4),
            scroll.topAnchor.constraint(equalTo: skip.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -16),
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -8),
            column.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 24),
            column.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -24),
            bar.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
            bar.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
            bar.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12),
        ])
        return paper
    }

    // MARK: Step bodies

    private func tourBody() -> UIView {
        let items: [(String, String)] = [
            (
                String(localized: "Swipe the bar", table: "Mobile"),
                String(localized: "Sideways to step through your tabs, up to bring back the last one.", table: "Mobile"),
            ),
            (
                String(localized: "Your Spaces come along", table: "Mobile"),
                String(
                    localized: "Sign in with your OpenArc account and your Mac's Spaces and pinned tabs are here.",
                    table: "Mobile",
                ),
            ),
            (
                String(localized: "Tabs tidy themselves", table: "Mobile"),
                String(localized: "Tabs you leave go to Archive after a while, ready to bring back.", table: "Mobile"),
            ),
            (
                String(localized: "Back from anywhere", table: "Mobile"),
                String(localized: "Swipe from the left edge of a page to go back.", table: "Mobile"),
            ),
        ]
        let cards = items.map { title, detail in
            let card = UIView()
            card.backgroundColor = Palette.tile
            card.layer.cornerRadius = 14
            card.layer.cornerCurve = .continuous
            let titleLabel = label(title, style: .headline, size: 17, weight: .semibold, color: Palette.ink)
            let detailLabel = label(detail, style: .subheadline, size: 15, weight: .regular, color: Palette.muted)
            let stack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
            stack.axis = .vertical
            stack.spacing = 3
            stack.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
                stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
                stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            ])
            card.isAccessibilityElement = true
            card.accessibilityLabel = "\(title). \(detail)"
            return card
        }
        let stack = UIStackView(arrangedSubviews: cards)
        stack.axis = .vertical
        stack.spacing = 10
        return stack
    }

    private func iconBody() -> UIView {
        let current = BrowserMobileAppIcon.current
        var tiles = [BrowserMobileAppIconTile]()
        for icon in BrowserMobileAppIcon.allCases {
            let tile = BrowserMobileAppIconTile(icon: icon, side: 62)
            tile.tintColor = Palette.brandBlue
            tile.isSelected = icon == current
            tile.addAction(UIAction { _ in
                for other in tiles {
                    other.isSelected = other.icon == icon
                }
                Task { @MainActor in
                    await BrowserMobileAppIcon.choose(icon)
                    let shown = BrowserMobileAppIcon.current
                    for other in tiles {
                        other.isSelected = other.icon == shown
                    }
                }
            }, for: .touchUpInside)
            tiles.append(tile)
        }
        let perRow = 4
        let rows = stride(from: 0, to: tiles.count, by: perRow).map { start in
            let row = UIStackView(arrangedSubviews: Array(tiles[start..<min(start + perRow, tiles.count)]))
            row.axis = .horizontal
            row.spacing = 4
            row.distribution = .equalSpacing
            return row
        }
        let grid = UIStackView(arrangedSubviews: rows)
        grid.axis = .vertical
        grid.alignment = .center
        grid.spacing = 14
        return grid
    }

    private func blockingBody() -> UIView {
        let card = UIStackView()
        card.axis = .vertical
        card.backgroundColor = Palette.tile
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.isLayoutMarginsRelativeArrangement = true
        card.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)
        let settings = BrowserMobileContentBlocking.settings(defaults)
        for (index, kind) in BrowserFilterListKind.mobileOrder.enumerated() {
            let title = label(kind.mobileTitle, style: .body, size: 17, weight: .regular, color: Palette.ink)
            let toggle = UISwitch()
            toggle.isOn = settings.blocks(kind)
            toggle.onTintColor = Palette.brandBlue
            toggle.accessibilityLabel = kind.mobileTitle
            toggle.accessibilityIdentifier = "browser.onboarding.blocking.\(kind.rawValue)"
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                guard let self, let toggle else { return }
                BrowserMobileContentBlocking.update(defaults) { $0.setBlocks(kind, toggle.isOn) }
            }, for: .valueChanged)
            toggle.setContentHuggingPriority(.required, for: .horizontal)
            let row = UIStackView(arrangedSubviews: [title, toggle])
            row.alignment = .center
            row.spacing = 12
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
            if index > 0 {
                let line = UIView()
                line.backgroundColor = Palette.ink.withAlphaComponent(0.1)
                line.heightAnchor.constraint(equalToConstant: 1 / max(traitCollection.displayScale, 1)).isActive = true
                card.addArrangedSubview(line)
            }
            card.addArrangedSubview(row)
        }
        return card
    }

    // MARK: Controls

    private func label(
        _ text: String, style: UIFont.TextStyle, size: CGFloat, weight: UIFont.Weight, rounded: Bool = false,
        color: UIColor,
    ) -> UILabel {
        let label = UILabel()
        var font = UIFont.systemFont(ofSize: size, weight: weight)
        if rounded, let descriptor = font.fontDescriptor.withDesign(.rounded) {
            font = UIFont(descriptor: descriptor, size: size)
        }
        label.font = UIFontMetrics(forTextStyle: style).scaledFont(for: font)
        label.adjustsFontForContentSizeCategory = true
        label.text = text
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = Palette.actionRed
        configuration.baseForegroundColor = .white
        configuration.background.cornerRadius = 9
        configuration.cornerStyle = .fixed
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFontMetrics(forTextStyle: .headline)
                .scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))
            return attributes
        }
        configuration.title = title
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.accessibilityIdentifier = "browser.onboarding.primary"
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        return button
    }

    private func quietButton(_ title: String, color: UIColor, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.baseForegroundColor = color
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .medium))
            return attributes
        }
        configuration.title = title
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return button
    }

    private func actionBar(_ actions: [UIView]) -> UIStackView {
        let bar = UIStackView(arrangedSubviews: actions)
        bar.axis = .vertical
        bar.alignment = .fill
        bar.spacing = 4
        return bar
    }
}

// MARK: - BrowserMobileOnboardingBlueField

/// The brand's blue with fine grain, as on the site's hero: printed, not glowing.
final class BrowserMobileOnboardingBlueField: UIView {
    // MARK: Lifecycle

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0x31 / 255, green: 0x39 / 255, blue: 0xFB / 255, alpha: 1)
        grain.backgroundColor = UIColor(patternImage: Self.grain)
        grain.isUserInteractionEnabled = false
        grain.frame = bounds
        grain.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(grain)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Private

    /// White noise at up to 7% alpha, at half size so each grain is a device pixel or two.
    private static let grain: UIImage = {
        let size = 128
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        var generator = SystemRandomNumberGenerator()
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = UInt8.random(in: 0...18, using: &generator)
            pixels[index] = alpha
            pixels[index + 1] = alpha
            pixels[index + 2] = alpha
            pixels[index + 3] = alpha
        }
        let image = pixels.withUnsafeMutableBytes { bytes -> CGImage? in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            return CGContext(
                data: bytes.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
            )?.makeImage()
        }
        return image.map { UIImage(cgImage: $0, scale: 2, orientation: .up) } ?? UIImage()
    }()

    private let grain = UIView()
}

// MARK: - BrowserMobileOnboardingArchMark

/// The `^` arch from the app icon and the site's top bar.
final class BrowserMobileOnboardingArchMark: UIView {
    // MARK: Lifecycle

    init(color: UIColor) {
        self.color = color
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        isAccessibilityElement = false
        contentMode = .redraw
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Internal

    override func draw(_: CGRect) {
        // The site's 40 × 36 logo path.
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 20, y: 3))
        path.addCurve(to: CGPoint(x: 27.5, y: 10), controlPoint1: CGPoint(x: 24, y: 3), controlPoint2: CGPoint(x: 26, y: 6))
        path.addLine(to: CGPoint(x: 35, y: 28))
        path.addCurve(to: CGPoint(x: 32, y: 33), controlPoint1: CGPoint(x: 36, y: 30.5), controlPoint2: CGPoint(x: 34.5, y: 33))
        path.addCurve(to: CGPoint(x: 28, y: 29.6), controlPoint1: CGPoint(x: 30, y: 33), controlPoint2: CGPoint(x: 29, y: 31.8))
        path.addLine(to: CGPoint(x: 20, y: 12))
        path.addLine(to: CGPoint(x: 12, y: 29.6))
        path.addCurve(to: CGPoint(x: 8, y: 33), controlPoint1: CGPoint(x: 11, y: 31.8), controlPoint2: CGPoint(x: 10, y: 33))
        path.addCurve(to: CGPoint(x: 5, y: 28), controlPoint1: CGPoint(x: 5.5, y: 33), controlPoint2: CGPoint(x: 4, y: 30.5))
        path.addLine(to: CGPoint(x: 12.5, y: 10))
        path.addCurve(to: CGPoint(x: 20, y: 3), controlPoint1: CGPoint(x: 14, y: 6), controlPoint2: CGPoint(x: 16, y: 3))
        path.close()
        let scale = min(bounds.width / 40, bounds.height / 36)
        path.apply(CGAffineTransform(scaleX: scale, y: scale))
        color.setFill()
        path.fill()
    }

    // MARK: Private

    private let color: UIColor
}
