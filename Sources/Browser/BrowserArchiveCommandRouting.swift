// BrowserArchiveCommandRouting.swift

import AppKit

/// Archive commands retain the originating model across Command Bar dismissal.
/// Menu and keyboard callers resolve their current owner before using this route.
@MainActor enum BrowserArchiveCommandRouting {
    /// A true result means the command was handled by the owner's Archive surface.
    /// An existing confirmation may safely ignore a repeated Clear request.
    @discardableResult static func perform(
        _ command: BrowserCommandID,
        from owner: BrowserChromeModel,
        registeredOwners: [BrowserChromeModel],
        isTerminating: Bool,
        present: (BrowserChromeModel) -> BrowserArchiveViewController?,
    ) -> Bool {
        guard command == .viewArchive || command == .clearArchive,
              !isTerminating,
              registeredOwners.contains(where: { $0 === owner }),
              owner.canBrowseArchive,
              command != .clearArchive || !owner.isArchiveOperationInFlight,
              let controller = present(owner), controller.model === owner else { return false }
        switch command {
        case .viewArchive:
            controller.focusSearch()
        case .clearArchive:
            controller.requestClear()
        default:
            return false
        }
        return true
    }

    /// Use the same resolved shortcuts as the Command Bar and physical-key bridge.
    static func menuItems(
        shortcutResolver: any BrowserShortcutResolving,
        viewAction: Selector,
        clearAction: Selector,
        target: AnyObject,
    ) -> [NSMenuItem] {
        [
            (BrowserCommandID.viewArchive, viewAction, "browser.archive.open"),
            (BrowserCommandID.clearArchive, clearAction, "browser.archive.clear"),
        ].map { command, action, identifier in
            let descriptor = shortcutResolver.descriptor(for: command)
            let item = NSMenuItem(
                title: descriptor.menuTitle,
                action: action,
                keyEquivalent: descriptor.shortcut.keyEquivalent,
            )
            item.keyEquivalentModifierMask = descriptor.shortcut.modifiers
            item.identifier = NSUserInterfaceItemIdentifier(identifier)
            item.target = target
            return item
        }
    }
}
