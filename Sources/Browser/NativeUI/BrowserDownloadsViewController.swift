import AppKit
import Combine

// MARK: - BrowserDownloadsViewController

final class BrowserDownloadsViewController: NSViewController {
    // MARK: Lifecycle

    init(model: BrowserDownloadsModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Internal

    let model: BrowserDownloadsModel
    var onSizeChanged: (NSSize) -> Void = { _ in }
    private(set) var rows = [String: BrowserNativeDownloadRow]()
    let clearButton = BrowserActionButton(BrowserStrings.downloadsClearFinished, action: {})

    override func loadView() {
        view = root
        root.setAccessibilityIdentifier("browser.downloads.popover")
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        for subview in [titleLabel, clearButton, empty, scroll] {
            root.addSubview(subview)
        }
        clearButton.isBordered = false
        clearButton.bezelStyle = .inline
        clearButton.font = .systemFont(ofSize: 12, weight: .medium)
        clearButton.contentTintColor = .linkColor
        clearButton.setAccessibilityIdentifier("browser.downloads.clear-finished")
        clearButton.onAction = { [weak self] in self?.model.clearFinishedDownloads() }
        empty.alignment = .center
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        observation = model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in self?.refresh() }
        refresh()
    }

    func refresh() {
        guard isViewLoaded else { return }
        let ids = Set(model.items.map(\.id))
        for id in Set(rows.keys).subtracting(ids) {
            rows.removeValue(forKey: id)?.removeFromSuperview()
        }
        var y: CGFloat = 0
        for (index, item) in model.items.enumerated() {
            let row = rows[item.id] ?? BrowserNativeDownloadRow()
            if rows[item.id] == nil {
                rows[item.id] = row
                document.addSubview(row)
            }
            row.update(item: item, status: model.statusTitle(for: item), detail: model.detailText(for: item))
            row.onOpen = { [weak model] in model?.open(item) }
            row.onReveal = { [weak model] in model?.reveal(item) }
            row.showsDivider = index < model.items.count - 1
            row.frame = NSRect(x: 0, y: y, width: 332, height: row.preferredHeight)
            y += row.preferredHeight
        }
        let bodyHeight = model.items.isEmpty ? 96 : min(y, 320)
        let size = NSSize(width: 360, height: 14 + 18 + 12 + bodyHeight + 14)
        preferredContentSize = size
        view.frame = NSRect(origin: .zero, size: size)
        titleLabel.frame = NSRect(x: 14, y: 14, width: 160, height: 18)
        let clearWidth = min(ceil(clearButton.intrinsicContentSize.width), 170)
        clearButton.frame = NSRect(x: 346 - clearWidth, y: 12, width: clearWidth, height: 22)
        clearButton.isEnabled = model.finishedDownloadCount > 0
        empty.isHidden = !model.items.isEmpty
        empty.frame = NSRect(x: 14, y: 44 + (bodyHeight - 18) / 2, width: 332, height: 18)
        scroll.isHidden = model.items.isEmpty
        scroll.frame = NSRect(x: 14, y: 44, width: 332, height: bodyHeight)
        document.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: y)
        for row in rows.values {
            row.setFrameSize(NSSize(width: scroll.contentSize.width, height: row.frame.height))
        }
        view.layoutSubtreeIfNeeded()
        onSizeChanged(size)
    }

    // MARK: Private

    private let root = BrowserNativeSurface()
    private let titleLabel = BrowserNativeControls.label(BrowserStrings.downloadsTitle, size: 13, weight: .semibold)
    private let empty = BrowserNativeControls.label(
        BrowserStrings.downloadsEmpty,
        size: 13,
        color: .secondaryLabelColor
    )
    private let scroll = NSScrollView()
    private let document = BrowserNativeSurface()
    private var observation: AnyCancellable?
}

// MARK: - BrowserNativeDownloadRow

final class BrowserNativeDownloadRow: NSView {
    // MARK: Lifecycle

    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [icon, title, status, detail, progress, openButton, revealButton, divider] {
            addSubview(view)
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        progress.style = .bar
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        for button in [openButton, revealButton] {
            button.isBordered = false
            button.bezelStyle = .inline
            button.font = .systemFont(ofSize: 11.5, weight: .medium)
            button.contentTintColor = .linkColor
        }
        openButton.onAction = { [weak self] in self?.onOpen() }
        revealButton.onAction = { [weak self] in self?.onReveal() }
        divider.strokeWidth = 0
        divider.fillColor = .separatorColor
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Internal

    override var isFlipped: Bool { true }

    var onOpen: () -> Void = {}
    var onReveal: () -> Void = {}
    private(set) var preferredHeight: CGFloat = 53
    let progress = NSProgressIndicator()
    let openButton = BrowserActionButton(BrowserStrings.downloadsOpen, action: {})
    let revealButton = BrowserActionButton(BrowserStrings.downloadsReveal, action: {})

    var showsDivider = true { didSet { divider.isHidden = !showsDivider } }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 0, y: 9, width: 22, height: 22)
        let x: CGFloat = 32
        let width = max(bounds.width - x, 0)
        let statusWidth = min(ceil(status.intrinsicContentSize.width), width * 0.45)
        status.frame = NSRect(x: bounds.width - statusWidth, y: 12, width: statusWidth, height: 15)
        title.frame = NSRect(x: x, y: 9, width: max(width - statusWidth - 8, 0), height: 18)
        detail.frame = NSRect(x: x, y: 32, width: width, height: 15)
        progress.frame = NSRect(x: x, y: 51, width: width, height: 4)
        let openWidth = ceil(openButton.intrinsicContentSize.width)
        let revealWidth = ceil(revealButton.intrinsicContentSize.width)
        openButton.frame = NSRect(x: x - 4, y: 48, width: openWidth, height: 20)
        revealButton.frame = NSRect(x: x + openWidth + 8, y: 48, width: revealWidth, height: 20)
        divider.frame = NSRect(x: 34, y: bounds.height - 1, width: max(bounds.width - 34, 0), height: 1)
    }

    func update(item: BrowserDownloadItem, status: String, detail: String) {
        title.stringValue = item.fileName
        self.status.stringValue = status
        self.detail.stringValue = detail
        let symbol =
            switch item.state {
            case .inProgress: "arrow.down"
            case .completed: "checkmark.circle.fill"
            case .canceled: "xmark.circle"
            case .interrupted: "exclamationmark.triangle"
            }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(
            pointSize: 15,
            weight: .semibold
        ))
        icon.contentTintColor = item.state == .completed ? .systemGreen : .secondaryLabelColor
        progress.isHidden = item.state != .inProgress
        progress.isIndeterminate = item.progressFraction == nil
        progress.doubleValue = item.progressFraction ?? 0
        if !progress.isHidden && progress.isIndeterminate {
            progress.startAnimation(nil)
        } else {
            progress.stopAnimation(nil)
        }
        let actionsVisible = item.state == .completed && item.fileURL != nil
        openButton.isHidden = !actionsVisible
        revealButton.isHidden = !actionsVisible
        preferredHeight = actionsVisible ? 73 : item.state == .inProgress ? 62 : 53
        setAccessibilityIdentifier("browser.downloads.item.\(item.id)")
        openButton.setAccessibilityIdentifier("browser.downloads.open.\(item.id)")
        revealButton.setAccessibilityIdentifier("browser.downloads.reveal.\(item.id)")
        needsLayout = true
    }

    // MARK: Private

    private let icon = NSImageView()
    private let title = BrowserNativeControls.label("", size: 13, weight: .medium)
    private let status = BrowserNativeControls.label("", size: 11, weight: .medium, color: .secondaryLabelColor)
    private let detail = BrowserNativeControls.label("", size: 11.5, color: .secondaryLabelColor)
    private let divider = BrowserNativeSurface()
}
