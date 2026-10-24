import AppKit
import Combine

// MARK: - BrowserSiteControlCenterViewController

/// Site control center: page actions, extensions, the site's own
/// settings, and its connection with a menu of site tools.
final class BrowserSiteControlCenterViewController: NSViewController {
    // MARK: Lifecycle

    init(model: BrowserChromeModel) { self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Internal

    enum Action: Equatable {
        case copyURL
        case capture
        case captureFullPage
        case clearCache
        case clearCookies
        case allSiteSettings
    }

    var onManage: () -> Void = {}
    var onAdd: () -> Void = {}
    var onSelectExtension: (String) -> Void = { _ in }
    var menuForExtension: (BrowserExtension) -> NSMenu = { _ in NSMenu() }
    /// Page actions that close the popover first.
    var onAction: (Action) -> Void = { _ in }

    override func loadView() {
        view = root
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityIdentifier("browser.extensions.control-center")
        for (index, action) in pageActions.enumerated() {
            let button = BrowserSiteControlButton(symbol: action.symbol)
            button.tooltipTitle = action.title
            button.setAccessibilityLabel(action.title)
            button.setAccessibilityIdentifier("browser.site-control.\(action.identifier)")
            button.onClick = { [weak self, weak button] _ in
                guard let self else { return }
                if index == 0, let button {
                    share(from: button)
                } else if let mapped = action.action {
                    onAction(mapped)
                }
            }
            actionButtons.append(button)
            root.addSubview(button)
        }
        root.addSubview(extensionsHeading)
        root.addSubview(manage)
        manage.isBordered = false
        manage.bezelStyle = .inline
        manage.font = .systemFont(ofSize: 12, weight: .medium)
        manage.contentTintColor = .linkColor
        manage.setAccessibilityIdentifier("browser.extensions.manage")
        manage.onAction = { [weak self] in self?.onManage() }
        root.addSubview(settingsHeading)
        root.addSubview(divider)
        divider.fillColor = .separatorColor
        root.addSubview(security)
        security.setAccessibilityIdentifier("browser.site-control.security")
        security.fillColor = .quaternaryLabelColor
        security.cornerRadius = 8
        security.addSubview(securityIcon)
        security.addSubview(securityLabel)
        securityIcon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        more.tooltipTitle = BrowserStrings.siteControlMore
        more.setAccessibilityLabel(BrowserStrings.siteControlMore)
        more.setAccessibilityIdentifier("browser.site-control.more")
        more.onClick = { [weak self] _ in self?.showMoreMenu() }
        root.addSubview(more)
        observation = model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in self?.refresh() }
        reloadSiteSettings()
    }

    /// Reads the site's settings again, as the popover opens or after a change.
    func reloadSiteSettings() {
        guard isViewLoaded else { return }
        let urlString = model.currentTab?.urlString ?? ""
        siteSettings = model.siteSettingRows(forURLString: urlString)
        refresh()
    }

    func refresh() {
        guard isViewLoaded else { return }
        let padding = BrowserChromeLayout.siteControlPopoverPadding
        let spacing = BrowserChromeLayout.siteControlPopoverSpacing
        let width = BrowserChromeLayout.siteControlPopoverWidth
        let content = width - padding * 2
        let tab = model.currentTab
        var y = padding

        // Page actions, four across.
        let actionGap: CGFloat = 8
        let actionWidth = (content - actionGap * CGFloat(pageActions.count - 1)) / CGFloat(pageActions.count)
        for (index, button) in actionButtons.enumerated() {
            button.frame = NSRect(
                x: padding + CGFloat(index) * (actionWidth + actionGap),
                y: y,
                width: actionWidth,
                height: 36
            )
            button.isInteractionEnabled = tab != nil && pageActions[index].isAvailable(model)
            button.alphaValue = button.isInteractionEnabled ? 1 : 0.4
        }
        y += 36 + spacing

        // Extensions, wrapping four to a row.
        extensionsHeading.frame = NSRect(x: padding, y: y, width: 170, height: 18)
        let manageWidth = ceil(manage.intrinsicContentSize.width)
        manage.frame = NSRect(x: width - padding - manageWidth, y: y - 2, width: manageWidth, height: 22)
        y += 18 + spacing / 2
        let items = BrowserExtensionControlCenterModel.gridItems(for: model.browserExtensions)
        let ids = Set(items.map(\.id))
        for id in Set(tiles.keys).subtracting(ids) {
            tiles.removeValue(forKey: id)?.removeFromSuperview()
        }
        let tileSize = BrowserChromeLayout.extensionTileSize
        let tileGap = BrowserChromeLayout.extensionGridSpacing
        let columns = max(Int((content + tileGap) / (tileSize + tileGap)), 1)
        for (index, item) in items.enumerated() {
            let tile = tiles[item.id] ?? BrowserNativeExtensionButton(tile: true)
            if tiles[item.id] == nil {
                tiles[item.id] = tile
                root.addSubview(tile)
            }
            switch item.kind {
            case .installed(let browserExtension):
                tile.update(browserExtension)
                tile.onClick = { [weak self] _ in self?.onSelectExtension(browserExtension.id) }
                tile.menuProvider = { [weak self] in self?.menuForExtension(browserExtension) ?? NSMenu() }
            case .add:
                tile.update(nil)
                tile.onClick = { [weak self] _ in self?.onAdd() }
                tile.menuProvider = nil
            }
            tile.frame = NSRect(
                x: padding + CGFloat(index % columns) * (tileSize + tileGap),
                y: y + CGFloat(index / columns) * (tileSize + tileGap),
                width: tileSize,
                height: tileSize
            )
        }
        let rows = (items.count + columns - 1) / columns
        y += CGFloat(rows) * tileSize + CGFloat(max(rows - 1, 0)) * tileGap

        // The site's settings that differ from the defaults.
        settingsHeading.isHidden = siteSettings.isEmpty
        let rowViews = settingRows(for: siteSettings, urlString: tab?.urlString ?? "")
        if !siteSettings.isEmpty {
            y += spacing
            settingsHeading.frame = NSRect(x: padding, y: y, width: content, height: 18)
            y += 18 + 6
            for row in rowViews {
                row.frame = NSRect(x: padding - 6, y: y, width: content + 12, height: 44)
                y += 44
            }
        }

        // Connection and site tools.
        y += spacing / 2
        divider.frame = NSRect(x: padding, y: y, width: content, height: 1)
        y += 1 + spacing / 2
        let scheme = tab.flatMap { URLComponents(string: $0.urlString)?.scheme?.lowercased() }
        let isWeb = scheme == "https" || scheme == "http"
        security.isHidden = !isWeb
        let secure = scheme == "https"
        securityIcon.image = NSImage(
            systemSymbolName: secure ? "lock.fill" : "lock.open",
            accessibilityDescription: nil
        )
        securityIcon.contentTintColor = secure ? .secondaryLabelColor : .systemOrange
        securityLabel.stringValue = secure ? BrowserStrings.siteControlSecure : BrowserStrings.siteControlNotSecure
        let labelWidth = ceil(securityLabel.intrinsicContentSize.width)
        security.frame = NSRect(x: padding, y: y, width: labelWidth + 34, height: 26)
        securityIcon.frame = NSRect(x: 8, y: 6, width: 14, height: 14)
        securityLabel.frame = NSRect(x: 26, y: 5, width: labelWidth, height: 16)
        security.setAccessibilityLabel(securityLabel.stringValue)
        more.frame = NSRect(x: width - padding - 26, y: y, width: 26, height: 26)
        more.isInteractionEnabled = tab != nil
        y += 26 + padding

        preferredContentSize = NSSize(width: width, height: y)
        view.frame = NSRect(origin: .zero, size: preferredContentSize)
    }

    // MARK: Private

    private struct PageAction {
        let symbol: String
        let title: String
        let identifier: String
        let action: Action?
        let isAvailable: @MainActor (BrowserChromeModel) -> Bool
    }

    private let model: BrowserChromeModel
    private let root = BrowserNativeSurface()
    private let extensionsHeading = BrowserNativeControls.label(
        BrowserStrings.extensionsSectionTitle,
        size: 13,
        weight: .semibold
    )
    private let settingsHeading = BrowserNativeControls.label(
        BrowserStrings.siteControlSettingsSection,
        size: 13,
        weight: .semibold
    )
    private let manage = BrowserActionButton(BrowserStrings.extensionsManageAction, action: {})
    private let divider = BrowserNativeSurface()
    private let security = BrowserNativeSurface()
    private let securityIcon = NSImageView()
    private let securityLabel = BrowserNativeControls.label("", size: 12, weight: .medium, color: .secondaryLabelColor)
    private let more = BrowserSiteControlButton(symbol: "ellipsis")
    private var actionButtons = [BrowserSiteControlButton]()
    private var tiles = [String: BrowserNativeExtensionButton]()
    private var settingViews = [BrowserSiteSettingRowView]()
    private var siteSettings = [BrowserSiteSettingRow]()
    private var observation: AnyCancellable?

    private let pageActions: [PageAction] = [
        PageAction(
            symbol: "square.and.arrow.up",
            title: BrowserStrings.siteControlShare,
            identifier: "share",
            action: nil
        ) { _ in true },
        PageAction(
            symbol: "link",
            title: BrowserStrings.tabCopyURLAction,
            identifier: "copy-url",
            action: .copyURL
        ) { _ in true },
        PageAction(
            symbol: "camera.viewfinder",
            title: BrowserStrings.siteControlCapture,
            identifier: "capture",
            action: .capture
        ) {
            $0.canCaptureArea
        },
        PageAction(
            symbol: "rectangle.dashed.and.paperclip",
            title: BrowserStrings.siteCaptureFullPageAction,
            identifier: "capture-full-page",
            action: .captureFullPage
        ) { _ in true },
    ]

    private func settingRows(for rows: [BrowserSiteSettingRow], urlString: String) -> [BrowserSiteSettingRowView] {
        while settingViews.count < rows.count {
            let view = BrowserSiteSettingRowView()
            settingViews.append(view)
            root.addSubview(view)
        }
        for (index, view) in settingViews.enumerated() {
            guard rows.indices.contains(index) else {
                view.isHidden = true
                continue
            }
            let row = rows[index]
            view.isHidden = false
            view.update(row)
            view.onClick = { [weak self, weak view] _ in
                guard let self, let view else { return }
                let menu = settingMenu(for: row, urlString: urlString)
                menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.maxX - 8, y: view.bounds.midY), in: view)
            }
        }
        return Array(settingViews.prefix(rows.count))
    }

    private func settingMenu(for row: BrowserSiteSettingRow, urlString: String) -> NSMenu {
        let menu = BrowserNativeMenus.menu()
        for value in row.kind.choices {
            let item = BrowserNativeMenus.add(value.menuTitle, to: menu) { [weak self] in
                guard let self else { return }
                model.setSiteSetting(row.kind, value: value, forURLString: urlString)
                reloadSiteSettings()
            }
            item.state = value == row.value || (value == .ask && row.value == .default) ? .on : .off
        }
        menu.addItem(.separator())
        BrowserNativeMenus.add(BrowserStrings.siteControlAllSiteSettings, to: menu) { [weak self] in
            self?.onAction(.allSiteSettings)
        }
        return menu
    }

    private func showMoreMenu() {
        let menu = BrowserNativeMenus.menu()
        BrowserNativeMenus
            .add(BrowserStrings.siteControlClearCache, to: menu, enabled: model.canReload) { [weak self] in
                self?.onAction(.clearCache)
            }
        BrowserNativeMenus
            .add(BrowserStrings.siteControlClearCookies, to: menu, enabled: model.canReload) { [weak self] in
                self?.onAction(.clearCookies)
            }
        menu.addItem(.separator())
        BrowserNativeMenus.add(BrowserStrings.extensionsManageAction, to: menu) { [weak self] in self?.onManage() }
        BrowserNativeMenus.add(BrowserStrings.extensionsAddAction, to: menu) { [weak self] in self?.onAdd() }
        menu.addItem(.separator())
        let isWeb = model.currentTab
            .flatMap { BrowserSitePermissionRequest.origin(ofURLString: $0.urlString) }?
            .hasPrefix("http") == true
        BrowserNativeMenus.add(BrowserStrings.siteControlAllSiteSettings, to: menu, enabled: isWeb) { [weak self] in
            self?.onAction(.allSiteSettings)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.maxY + 4), in: more)
    }

    private func share(from button: NSView) {
        guard let tab = model.currentTab else { return }
        let items: [Any] = tab.pageURL.map { [$0] } ?? [NSString(string: tab.urlString)]
        NSSharingServicePicker(items: items).show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}

// MARK: - BrowserSiteControlButton

/// An icon button of the site control center.
final class BrowserSiteControlButton: BrowserNativePressableView {
    // MARK: Lifecycle

    init(symbol: String) {
        super.init(frame: .zero)
        cornerRadius = 8
        addSubview(icon)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        icon.contentTintColor = .labelColor
        icon.setAccessibilityElement(false)
        interactionChanged()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Internal

    override func interactionChanged() {
        super.interactionChanged()
        fillColor = isHovered && isInteractionEnabled
            ? .tertiaryLabelColor.withAlphaComponent(0.25)
            : .quaternaryLabelColor.withAlphaComponent(0.4)
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: (bounds.width - 18) / 2, y: (bounds.height - 18) / 2, width: 18, height: 18)
    }

    // MARK: Private

    private let icon = NSImageView()
}

// MARK: - BrowserSiteSettingRowView

/// One of the site's settings: icon, name and value; a click offers the
/// other values.
final class BrowserSiteSettingRowView: BrowserNativePressableView {
    // MARK: Lifecycle

    override init(frame: NSRect) {
        super.init(frame: frame)
        cornerRadius = 8
        badge.cornerRadius = 15
        badge.fillColor = .quaternaryLabelColor
        badge.addSubview(icon)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        icon.contentTintColor = .labelColor
        for view in [badge, title, value] as [NSView] {
            view.setAccessibilityElement(false)
            addSubview(view)
        }
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Internal

    override func interactionChanged() {
        super.interactionChanged()
        fillColor = isHovered ? .quaternaryLabelColor.withAlphaComponent(0.5) : .clear
    }

    override func layout() {
        super.layout()
        badge.frame = NSRect(x: 6, y: (bounds.height - 30) / 2, width: 30, height: 30)
        icon.frame = NSRect(x: 6, y: 6, width: 18, height: 18)
        title.frame = NSRect(x: 44, y: 6, width: bounds.width - 50, height: 17)
        value.frame = NSRect(x: 44, y: 23, width: bounds.width - 50, height: 15)
    }

    func update(_ row: BrowserSiteSettingRow) {
        icon.image = NSImage(systemSymbolName: row.kind.systemImageName, accessibilityDescription: nil)
        title.stringValue = row.kind.title
        value.stringValue = row.value.title
        setAccessibilityLabel("\(row.kind.title), \(row.value.title)")
        setAccessibilityIdentifier("browser.site-control.setting.\(row.kind.rawValue)")
    }

    // MARK: Private

    private let badge = BrowserNativeSurface()
    private let icon = NSImageView()
    private let title = BrowserNativeControls.label("", size: 13, weight: .medium)
    private let value = BrowserNativeControls.label("", size: 11, color: .secondaryLabelColor)
}
