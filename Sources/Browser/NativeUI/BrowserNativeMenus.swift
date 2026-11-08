// BrowserNativeMenus.swift

import AppKit

// MARK: - BrowserNativeMenuItem

@MainActor final class BrowserNativeMenuItem: NSMenuItem {
    // MARK: Private

    private let handler: () -> Void

    init(_ title: String, shortcut: BrowserKeyboardShortcut? = nil, action: @escaping () -> Void) {
        self.handler = action
        super.init(title: title, action: #selector(invoke), keyEquivalent: shortcut?.keyEquivalent ?? "")
        keyEquivalentModifierMask = shortcut?.modifiers ?? []
        target = self
    }

    @available(*, unavailable) required init(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
        action: @escaping () -> Void,
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
        onRename: @escaping () -> Void,
        onChangeIcon: @escaping (String) -> Void,
        onEditTheme: (() -> Void)? = nil,
        profiles: [BrowserProfile] = [],
        selectedProfile: String? = nil,
        onSetProfile: ((String) -> Void)? = nil,
        onNewProfile: (() -> Void)? = nil,
        onManageSpaces: (() -> Void)? = nil,
        canCreateFolder: Bool = false,
        onNewFolder: (() -> Void)? = nil,
        onNewGitHubLiveFolder: (() -> Void)? = nil,
        exportTargets: [BrowserChromeModel.Space] = [],
        onExport: ((String) -> Void)? = nil,
        onResetTabs: @escaping () -> Void = {},
        onDelete: @escaping () -> Void,
    ) -> NSMenu {
        let menu = menu()
        addIconPicker(BrowserStrings.spaceChangeIconAction, to: menu, action: onChangeIcon)
        add(BrowserStrings.spaceRenameAction, to: menu, action: onRename)
        if let onEditTheme {
            add(BrowserStrings.spaceEditThemeAction, to: menu, action: onEditTheme)
        }
        if let onSetProfile, !profiles.isEmpty {
            let submenu = submenu(BrowserStrings.spaceSetProfileAction, in: menu)
            for profile in profiles {
                let item = add(profile.displayName, to: submenu) { onSetProfile(profile.id) }
                item.state = profile.id == selectedProfile ? .on : .off
            }
            if let onNewProfile {
                submenu.addItem(.separator())
                add(BrowserStrings.spaceMenuNewProfile, to: submenu, action: onNewProfile)
            }
        }
        if let onNewFolder {
            menu.addItem(.separator())
            add(BrowserStrings.dockMenuNewFolder, to: menu, enabled: canCreateFolder, action: onNewFolder)
            if let onNewGitHubLiveFolder {
                let live = submenu(BrowserStrings.liveFoldersMenu, in: menu)
                add(BrowserStrings.liveFolderGitHubTitle, to: live, action: onNewGitHubLiveFolder)
            }
        }
        if let onExport, !exportTargets.isEmpty {
            menu.addItem(.separator())
            let exportMenu = submenu(BrowserStrings.spaceExportAction(space.title), in: menu)
            for target in exportTargets {
                let item = add(target.title, to: exportMenu) { onExport(target.id) }
                item.image = BrowserIconImage.image(named: target.systemImageName, pointSize: 13)
            }
        }
        if let onManageSpaces {
            menu.addItem(.separator())
            add(BrowserStrings.menuManageSpaces, to: menu, action: onManageSpaces)
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
        onNewNested: (() -> Void)? = nil,
        onTurnIntoSpace: (() -> Void)? = nil,
        onCopyAllLinks: (() -> Void)? = nil,
        onDuplicate: (() -> Void)? = nil,
        moveTargets: [BrowserChromeModel.Space] = [],
        onMove: @escaping (String) -> Void = { _ in },
        onDelete: (() -> Void)? = nil,
    ) -> NSMenu {
        let menu = menu()
        if let onNewNested {
            add(BrowserStrings.pinnedTabFolderNewNestedAction, to: menu, action: onNewNested)
        }
        if let onTurnIntoSpace {
            add(
                String(format: BrowserStrings.pinnedTabFolderTurnIntoSpaceAction, folder.title),
                to: menu,
                action: onTurnIntoSpace,
            )
        }
        if let onCopyAllLinks {
            add(BrowserStrings.pinnedTabFolderCopyAllLinksAction, to: menu, action: onCopyAllLinks)
        }
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        addIconMenu(
            BrowserStrings.pinnedTabFolderChangeIconAction,
            to: menu,
            selected: folder.systemImageName,
            noIconTitle: BrowserStrings.pinnedTabFolderNoIconAction,
            action: onChangeIcon,
        )
        add(BrowserStrings.pinnedTabFolderRenameAction, to: menu, action: onRename)
        if onDuplicate != nil || !moveTargets.isEmpty {
            menu.addItem(.separator())
        }
        if let onDuplicate {
            add(BrowserStrings.tabDuplicateAction, to: menu, action: onDuplicate)
        }
        if !moveTargets.isEmpty {
            let submenu = submenu(BrowserStrings.tabMoveToSpaceAction, in: menu)
            for space in moveTargets {
                let item = add(space.title, to: submenu) { onMove(space.id) }
                item.image = NSImage(systemSymbolName: space.systemImageName, accessibilityDescription: nil)
            }
        }
        if let onDelete {
            menu.addItem(.separator())
            add(BrowserStrings.pinnedTabFolderDeleteAction, to: menu, action: onDelete)
        }
        return menu
    }

    /// Opens the icon picker, and offers to remove an icon already chosen.
    static func addIconMenu(
        _ title: String,
        to menu: NSMenu,
        selected: String?,
        noIconTitle: String,
        action: @escaping (String?) -> Void,
    ) {
        addIconPicker(title, to: menu) { action($0) }
        if selected != nil {
            add(noIconTitle, to: menu) { action(nil) }
        }
    }

    // MARK: Private

    private static func addIconPicker(_ title: String, to menu: NSMenu, action: @escaping (String) -> Void) {
        add(title + "…", to: menu) {
            BrowserIconPickerPresenter.shared.showAtPointer(onPick: action)
        }
    }
}
