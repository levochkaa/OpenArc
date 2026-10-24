import AppKit

// MARK: - BrowserNativeMenuItem

@MainActor final class BrowserNativeMenuItem: NSMenuItem {
    // MARK: Lifecycle

    init(_ title: String, shortcut: BrowserKeyboardShortcut? = nil, action: @escaping () -> Void) {
        self.handler = action
        super.init(title: title, action: #selector(invoke), keyEquivalent: shortcut?.keyEquivalent ?? "")
        keyEquivalentModifierMask = shortcut?.modifiers ?? []
        target = self
    }

    @available(*, unavailable) required init(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Private

    private let handler: () -> Void

    @objc private func invoke() { handler() }
}

// MARK: - BrowserNativeMenus

@MainActor enum BrowserNativeMenus {
    // MARK: Internal

    static func menu() -> NSMenu { let menu = NSMenu()
        menu.autoenablesItems = false
        return menu
    }

    @discardableResult static func add(
        _ title: String,
        to menu: NSMenu,
        shortcut: BrowserKeyboardShortcut? = nil,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> NSMenuItem {
        let item = BrowserNativeMenuItem(title, shortcut: shortcut, action: action)
        item.isEnabled = enabled
        menu.addItem(item)
        return item
    }

    static func submenu(_ title: String, in menu: NSMenu) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = self.menu()
        item.submenu = submenu
        menu.addItem(item)
        return submenu
    }

    static func share(items: [Any], subject: String, in menu: NSMenu) {
        let submenu = submenu(BrowserStrings.tabShareAction, in: menu)
        for service in BrowserShareMenuServiceProvider.sharingServices(for: items) {
            let item = add(service.menuItemTitle, to: submenu) {
                service.subject = subject
                service.perform(withItems: items)
            }
            item.image = service.image
        }
    }

    static func prompt(title: String, defaultValue: String) -> String? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = defaultValue
        let alert = NSAlert()
        alert.messageText = title
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func space(
        _ space: BrowserChromeModel.Space,
        canDelete: Bool,
        canResetTabs: Bool = false,
        color: BrowserSpaceColor? = nil,
        onRename: @escaping () -> Void,
        onChangeIcon: @escaping (String) -> Void,
        onChangeColor: ((BrowserSpaceColor?) -> Void)? = nil,
        onResetTabs: @escaping () -> Void = {},
        onDelete: @escaping () -> Void
    ) -> NSMenu {
        let menu = menu()
        add(BrowserStrings.spaceRenameAction, to: menu, action: onRename)
        let icons = submenu(BrowserStrings.spaceChangeIconAction, in: menu)
        addIcons(to: icons, selected: space.systemImageName, action: onChangeIcon)
        if let onChangeColor {
            let colors = submenu(BrowserStrings.spaceChangeColorAction, in: menu)
            add(BrowserStrings.spaceColorNone, to: colors) { onChangeColor(nil) }.state = color == nil ? .on : .off
            colors.addItem(.separator())
            for option in BrowserSpaceColor.allCases {
                let item = add(option.title, to: colors) { onChangeColor(option) }
                item.state = option == color ? .on : .off
                item.image = swatch(option.color)
            }
        }
        menu.addItem(.separator())
        add(BrowserStrings.menuResetSpaceTabs, to: menu, enabled: canResetTabs, action: onResetTabs)
        menu.addItem(.separator())
        add(BrowserStrings.spaceDeleteAction, to: menu, enabled: canDelete, action: onDelete)
        return menu
    }

    static func folder(
        _ folder: BrowserChromeModel.PinnedTabFolder,
        onRename: @escaping () -> Void,
        onChangeIcon: @escaping (String?) -> Void,
        onDelete: (() -> Void)? = nil
    ) -> NSMenu {
        let menu = menu()
        add(BrowserStrings.pinnedTabFolderRenameAction, to: menu, action: onRename)
        let icons = submenu(BrowserStrings.pinnedTabFolderChangeIconAction, in: menu)
        add(BrowserStrings.pinnedTabFolderNoIconAction, to: icons) { onChangeIcon(nil) }
        icons.addItem(.separator())
        addIcons(to: icons, selected: folder.systemImageName) { onChangeIcon($0) }
        if let onDelete {
            menu.addItem(.separator())
            add(BrowserStrings.pinnedTabFolderDeleteAction, to: menu, action: onDelete)
        }
        return menu
    }

    /// An icon submenu with a No Icon choice, as folders use.
    static func addIconMenu(
        _ title: String,
        to menu: NSMenu,
        selected: String?,
        noIconTitle: String,
        action: @escaping (String?) -> Void
    ) {
        let icons = submenu(title, in: menu)
        add(noIconTitle, to: icons) { action(nil) }
        icons.addItem(.separator())
        addIcons(to: icons, selected: selected) { action($0) }
    }

    // MARK: Private

    private static func addIcons(to menu: NSMenu, selected: String?, action: @escaping (String) -> Void) {
        for name in BrowserSpaceIconCatalog.systemImageNames {
            let item = add(name, to: menu) { action(name) }
            item.image = NSImage(systemSymbolName: selected == name ? "checkmark" : name, accessibilityDescription: nil)
        }
    }

    /// A round color sample for a menu item.
    private static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}
