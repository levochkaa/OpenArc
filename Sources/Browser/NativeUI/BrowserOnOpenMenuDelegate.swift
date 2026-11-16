// BrowserOnOpenMenuDelegate.swift

import AppKit

/// Fills a menu without shortcuts only when it opens. AppKit otherwise asks every menu's
/// delegate to update it on each Command key press while it looks for a shortcut.
@MainActor final class BrowserOnOpenMenuDelegate: NSObject, NSMenuDelegate {
    // MARK: Private

    private let fill: @MainActor (NSMenu) -> Void

    init(fill: @escaping @MainActor (NSMenu) -> Void) {
        self.fill = fill
    }

    // MARK: Internal

    func menuNeedsUpdate(_ menu: NSMenu) {
        fill(menu)
    }

    func menuHasKeyEquivalent(
        _: NSMenu,
        for _: NSEvent,
        target _: AutoreleasingUnsafeMutablePointer<AnyObject?>,
        action _: UnsafeMutablePointer<Selector?>,
    ) -> Bool {
        false
    }
}
