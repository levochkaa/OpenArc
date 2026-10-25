// BrowserShareMenuServiceProvider.swift

import AppKit

// MARK: - BrowserShareMenuServiceProvider

enum BrowserShareMenuServiceProvider {
    // MARK: Internal

    static func sharingServices(for items: [Any]) -> [NSSharingService] {
        let readingListMenuTitle = NSSharingService(named: .addToSafariReadingList)?.menuItemTitle

        return legacySharingServices(for: items).filter { service in
            guard let readingListMenuTitle else {
                return true
            }

            return service.menuItemTitle != readingListMenuTitle
        }
    }

    // MARK: Private

    private static func legacySharingServices(for items: [Any]) -> [NSSharingService] {
        let selector = NSSelectorFromString("sharingServicesForItems:")

        guard NSSharingService.responds(to: selector),
              let result = NSSharingService.perform(selector, with: items as NSArray)?.takeUnretainedValue()
        else {
            return []
        }

        return result as? [NSSharingService] ?? []
    }
}
