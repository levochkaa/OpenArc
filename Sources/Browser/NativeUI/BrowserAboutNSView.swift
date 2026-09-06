import AppKit

// MARK: - BrowserAboutLayout

enum BrowserAboutLayout {
    static let windowWidth: CGFloat = 440
    static let windowHeight: CGFloat = 420
}

// MARK: - BrowserAboutInfo

struct BrowserAboutInfo {
    let applicationName: String
    let applicationVersionText: String
    let chromiumVersionText: String
    let copyrightText: String
    let icon: NSImage
}

// MARK: - BrowserAboutResources

enum BrowserAboutResources {
    static let chromiumProjectURL = URL(string: "https://www.chromium.org/chromium-projects/")!
    static let chromiumCreditsLinkURL = URL(string: "tb://credits/")!

    static var theBrowserCreditsURL: URL {
        Bundle.main.url(forResource: "Credits", withExtension: "html")
            ?? URL(fileURLWithPath: "Credits.html")
    }
}

// MARK: - BrowserAboutView

final class BrowserAboutView: NSView, NSTextViewDelegate {
    // MARK: Lifecycle

    init(info: BrowserAboutInfo, openLink: @escaping (URL) -> Void) {
        self.openLink = openLink
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: BrowserAboutLayout.windowWidth,
            height: BrowserAboutLayout.windowHeight
        ))
        setAccessibilityIdentifier("browser.about")
        let icon = NSImageView()
        icon.image = info.icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        let name = label(info.applicationName, size: 24, weight: .semibold, color: .labelColor)
        let version = label(info.applicationVersionText, size: 12)
        let chromiumVersion = label(info.chromiumVersionText, size: 12)
        let copyright = label(info.copyrightText, size: 10)
        let versions = NSStackView(views: [name, version, chromiumVersion])
        versions.orientation = .vertical
        versions.spacing = 6
        versions.alignment = .centerX
        links.isEditable = false
        links.isSelectable = true
        links.drawsBackground = false
        links.delegate = self
        links.textContainerInset = .zero
        links.textContainer?.lineFragmentPadding = 0
        links.textContainer?.widthTracksTextView = true
        links.textStorage?.setAttributedString(Self.creditsText())
        links.setAccessibilityIdentifier("browser.about.credits")
        links.textContainer?.containerSize = NSSize(width: 360, height: CGFloat.greatestFiniteMagnitude)
        if let container = links.textContainer {
            links.layoutManager?.ensureLayout(for: container)
        }
        let linksHeight = links.textContainer.flatMap { links.layoutManager?.usedRect(for: $0).height } ?? 48
        let stack = NSStackView(views: [icon, versions, copyright, links])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 0
        stack.setCustomSpacing(16, after: icon)
        stack.setCustomSpacing(18, after: versions)
        stack.setCustomSpacing(22, after: copyright)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -28),
            stack.widthAnchor.constraint(equalToConstant: 360),
            icon.widthAnchor.constraint(equalToConstant: 92),
            icon.heightAnchor.constraint(equalToConstant: 92),
            links.widthAnchor.constraint(equalToConstant: 360),
            links.heightAnchor.constraint(equalToConstant: ceil(linksHeight)),
        ])
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Internal

    override func draw(_: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }

    static func creditsText() -> NSAttributedString {
        let result = NSMutableAttributedString()
        func append(_ text: String, link: URL? = nil) {
            result.append(NSAttributedString(string: text, attributes: link.map { [.link: $0] } ?? [:]))
        }
        append(BrowserStrings.aboutMadePossiblePrefix)
        append(BrowserStrings.aboutChromiumProjectLinkTitle, link: BrowserAboutResources.chromiumProjectURL)
        append(BrowserStrings.aboutMadePossibleChromiumProjectSuffix)
        append(BrowserStrings.aboutOpenSourceSoftwareLinkTitle, link: BrowserAboutResources.chromiumCreditsLinkURL)
        append(BrowserStrings.aboutMadePossibleOtherPrefix)
        append(BrowserStrings.aboutOpenSourceSoftwareLinkTitle, link: BrowserAboutResources.theBrowserCreditsURL)
        append(BrowserStrings.aboutMadePossibleSuffix)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 3
        result.addAttributes([
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ], range: NSRange(location: 0, length: result.length))
        return result
    }

    func textView(_: NSTextView, clickedOnLink link: Any, at _: Int) -> Bool {
        guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return false }
        openLink(url)
        return true
    }

    // MARK: Private

    private let openLink: (URL) -> Void
    private let links = NSTextView()

    private func label(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor = .secondaryLabelColor
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.alignment = .center
        label.isSelectable = true
        return label
    }
}
