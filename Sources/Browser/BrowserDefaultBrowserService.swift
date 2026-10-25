// BrowserDefaultBrowserService.swift

import AppKit
import CoreServices
import Foundation

struct BrowserDefaultBrowserService {
    // MARK: Internal

    typealias DefaultHandlerLookup = (_ scheme: String) -> String?
    typealias DefaultHandlerSetter = (_ scheme: String, _ bundleIdentifier: String) -> OSStatus

    static let defaultBundleIdentifier = "com.levochkaa.OpenArc"
    static let webURLSchemes = ["http", "https"]

    let bundleIdentifier: String

    // MARK: Private

    private let schemes: [String]
    private let defaultHandlerLookup: DefaultHandlerLookup
    private let defaultHandlerSetter: DefaultHandlerSetter

    var isDefaultBrowser: Bool {
        schemes.allSatisfy { scheme in
            defaultHandlerLookup(scheme)?.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        }
    }

    init(
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? BrowserDefaultBrowserService.defaultBundleIdentifier,
        schemes: [String] = BrowserDefaultBrowserService.webURLSchemes,
        defaultHandlerLookup: @escaping DefaultHandlerLookup = BrowserDefaultBrowserService
            .defaultHandlerBundleIdentifier(for:),
        defaultHandlerSetter: @escaping DefaultHandlerSetter = BrowserDefaultBrowserService
            .setDefaultHandler(for:bundleIdentifier:),
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.schemes = schemes
        self.defaultHandlerLookup = defaultHandlerLookup
        self.defaultHandlerSetter = defaultHandlerSetter
    }

    private static func defaultHandlerBundleIdentifier(for scheme: String) -> String? {
        guard
            let url = URL(string: "\(scheme)://openarc.default-handler-check"),
            let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: url)
        else {
            return nil
        }

        return Bundle(url: applicationURL)?.bundleIdentifier
    }

    private static func setDefaultHandler(for scheme: String, bundleIdentifier: String) -> OSStatus {
        LSSetDefaultHandlerForURLScheme(scheme as CFString, bundleIdentifier as CFString)
    }

    @discardableResult func setAsDefaultBrowser() -> Bool {
        var didSetEveryScheme = true

        for scheme in schemes {
            let status = defaultHandlerSetter(scheme, bundleIdentifier)
            if status != noErr {
                didSetEveryScheme = false
            }
        }

        return didSetEveryScheme
    }
}
