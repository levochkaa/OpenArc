// BrowserMobileSettingsExtrasTests.swift

import Foundation
import Testing
import UIKit

/// A throwaway defaults domain for one test.
private func scratchDefaults() throws -> UserDefaults {
    let name = "browser.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return defaults
}

// MARK: - App icons

@Test func mobileAppIconsNameTheirIconSetsAndTheOriginalKeepsTheBundlesOwn() {
    #expect(BrowserMobileAppIcon.original.alternateIconName == nil)
    #expect(BrowserMobileAppIcon.candy.alternateIconName == "AppIcon-Candy")
    let names = BrowserMobileAppIcon.allCases.compactMap(\.alternateIconName)
    #expect(Set(names).count == BrowserMobileAppIcon.allCases.count - 1)
    for icon in BrowserMobileAppIcon.allCases {
        #expect(BrowserMobileAppIcon.icon(alternateIconName: icon.alternateIconName) == icon)
    }
    #expect(BrowserMobileAppIcon.icon(alternateIconName: "AppIcon-Gone") == .original)
}

// MARK: - Widget links

@Test func mobileAppLinksRoundTripThroughTheirURLs() throws {
    for link in BrowserMobileAppLink.allCases {
        #expect(BrowserMobileAppLink(url: link.url) == link)
    }
    #expect(BrowserMobileAppLink.voiceSearch.url.absoluteString == "openarc://voice-search")
    #expect(try BrowserMobileAppLink(url: #require(URL(string: "OpenArc://New-Tab"))) == .newTab)
    #expect(try BrowserMobileAppLink(url: #require(URL(string: "openarc://settings"))) == nil)
    #expect(try BrowserMobileAppLink(url: #require(URL(string: "https://search"))) == nil)
}

@Test func mobileQuickActionsNameTheirAppLinks() {
    // The app's Info.plist lists the quick actions by these types.
    #expect(["search", "voice-search", "app-icon"].map(BrowserMobileAppLink.init(rawValue:)) == [
        .search, .voiceSearch, .appIcon,
    ])
    #expect(BrowserMobileAppLink.appIcon.url.absoluteString == "openarc://app-icon")
}

// MARK: - Voice Search languages

@Test func mobileVoiceSearchFollowsTheKeyboardUntilALanguageIsChosen() throws {
    let defaults = try scratchDefaults()
    #expect(BrowserMobileVoiceSearchLanguages.language(keyboard: "en-US", defaults: defaults) == "en-US")
    BrowserMobileVoiceSearchLanguages.add("ru-RU", defaults: defaults)
    BrowserMobileVoiceSearchLanguages.add("de-DE", defaults: defaults)
    #expect(BrowserMobileVoiceSearchLanguages.list(defaults) == ["ru-RU", "de-DE"])
    #expect(BrowserMobileVoiceSearchLanguages.language(keyboard: "en-US", defaults: defaults) == "de-DE")
    BrowserMobileVoiceSearchLanguages.add("ru-RU", defaults: defaults)
    #expect(BrowserMobileVoiceSearchLanguages.list(defaults) == ["ru-RU", "de-DE"], "Adding again only picks it")
    #expect(BrowserMobileVoiceSearchLanguages.preferred(defaults) == "ru-RU")
    BrowserMobileVoiceSearchLanguages.remove("de-DE", defaults: defaults)
    #expect(BrowserMobileVoiceSearchLanguages.preferred(defaults) == "ru-RU")
    BrowserMobileVoiceSearchLanguages.remove("ru-RU", defaults: defaults)
    #expect(BrowserMobileVoiceSearchLanguages.preferred(defaults) == nil)
    #expect(BrowserMobileVoiceSearchLanguages.language(keyboard: "en-US", defaults: defaults) == "en-US")
    BrowserMobileVoiceSearchLanguages.add("ru-RU", defaults: defaults)
    BrowserMobileVoiceSearchLanguages.setPreferred(nil, defaults: defaults)
    #expect(BrowserMobileVoiceSearchLanguages.language(keyboard: nil, defaults: defaults) == nil)
}

@Test func mobileAddLanguageListsTheRecognizersLanguagesByNameLeavingOutAddedOnes() {
    let names = ["ru-RU": "Russian", "de-DE": "German", "en-US": "English", "fr-FR": "French"]
    let choices = BrowserMobileAddLanguageViewController.choices(
        supported: Set(names.keys.map { Locale(identifier: $0) }), added: ["fr-FR"], name: { names[$0] ?? $0 },
    )
    #expect(choices == ["en-US", "de-DE", "ru-RU"])
    #expect(BrowserMobileAddLanguageViewController.matches(
        "ru-RU",
        query: "рус",
        name: "Russian",
        nativeName: "русский",
    ))
    #expect(BrowserMobileAddLanguageViewController.matches(
        "ru-RU",
        query: " rus ",
        name: "Russian",
        nativeName: "русский",
    ))
    #expect(!BrowserMobileAddLanguageViewController.matches(
        "ru-RU",
        query: "germ",
        name: "Russian",
        nativeName: "русский",
    ))
    #expect(BrowserMobileAddLanguageViewController.matches("ru-RU", query: "", name: "Russian", nativeName: "русский"))
}

// MARK: - Onboarding

@Test func mobileOnboardingShowsOnceAndAsksForTheDefaultBrowserOnlyWhenItCanBeOne() throws {
    let defaults = try scratchDefaults()
    #expect(BrowserMobileOnboarding.isNeeded(defaults))
    BrowserMobileOnboarding.markDone(defaults)
    #expect(!BrowserMobileOnboarding.isNeeded(defaults))
    #expect(BrowserMobileOnboarding.steps(canBeDefaultBrowser: false) == [.welcome, .tour, .icon, .blocking, .done])
    #expect(
        BrowserMobileOnboarding.steps(canBeDefaultBrowser: true)
            == [.welcome, .tour, .icon, .blocking, .defaultBrowser, .done],
    )
}

@MainActor @Test func mobileOnboardingWalksItsStepsAndRemembersItWasSeen() throws {
    let defaults = try scratchDefaults()
    let onboarding = BrowserMobileOnboardingViewController(defaults: defaults, canBeDefaultBrowser: false)
    onboarding.loadViewIfNeeded()
    var seen = [onboarding.step]
    while onboarding.step != .done {
        onboarding.advance()
        seen.append(onboarding.step)
    }
    #expect(seen == [.welcome, .tour, .icon, .blocking, .done])
    #expect(BrowserMobileOnboarding.isNeeded(defaults))
    onboarding.advance()
    #expect(!BrowserMobileOnboarding.isNeeded(defaults), "Start Browsing on the last step ends it")
}

// MARK: - Contact and legal pages

@MainActor @Test func mobileContactWritesToSupportNamingTheVersionAndSystem() {
    let url = BrowserMobileSupport.contactURL(version: "0.4.3", build: "20", system: "iOS 27.2")
    #expect(url.scheme == "mailto")
    #expect(url.absoluteString == "mailto:support@openarc.su?subject=OpenArc%200.4.3%20(20),%20iOS%2027.2")
    #expect(BrowserMobileSupport.privacyPolicyURL.absoluteString == "https://openarc.su/privacy/")
    #expect(BrowserMobileSupport.termsURL.absoluteString == "https://openarc.su/terms/")
}
