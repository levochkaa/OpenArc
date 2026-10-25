// BrowserDefaultBrowserServiceTests.swift

import CoreServices
import Foundation
import Testing

@Test func defaultBrowserServiceIsDefaultOnlyWhenAllWebSchemesUseTheAppBundleIdentifier() {
    let service = BrowserDefaultBrowserService(
        bundleIdentifier: "com.example.Browser",
        schemes: ["http", "https"],
        defaultHandlerLookup: { scheme in
            switch scheme {
            case "http",
                 "https":
                "com.example.Browser"
            default:
                nil
            }
        },
        defaultHandlerSetter: { _, _ in noErr },
    )

    #expect(service.isDefaultBrowser)
}

@Test func defaultBrowserServiceRequiresEveryWebSchemeToMatch() {
    let service = BrowserDefaultBrowserService(
        bundleIdentifier: "com.example.Browser",
        schemes: ["http", "https"],
        defaultHandlerLookup: { scheme in
            scheme == "http" ? "com.example.Browser" : "com.apple.Safari"
        },
        defaultHandlerSetter: { _, _ in noErr },
    )

    #expect(!service.isDefaultBrowser)
}

@Test func defaultBrowserServiceSetsEveryConfiguredWebScheme() {
    var requests = [(scheme: String, bundleIdentifier: String)]()
    let service = BrowserDefaultBrowserService(
        bundleIdentifier: "com.example.Browser",
        schemes: ["http", "https"],
        defaultHandlerLookup: { _ in nil },
        defaultHandlerSetter: { scheme, bundleIdentifier in
            requests.append((scheme: scheme, bundleIdentifier: bundleIdentifier))
            return scheme == "http" ? noErr : -1
        },
    )

    #expect(!service.setAsDefaultBrowser())
    #expect(requests.map(\.scheme) == ["http", "https"])
    #expect(requests.map(\.bundleIdentifier) == ["com.example.Browser", "com.example.Browser"])
}
