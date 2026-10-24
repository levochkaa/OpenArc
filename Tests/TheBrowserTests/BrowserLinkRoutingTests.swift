import Foundation
import Testing

// MARK: - BrowserLinkRoutingTests

@MainActor struct BrowserLinkRoutingTests {
    @Test func aSiteRuleMatchesTheSiteItsSubdomainsAndItsPath() throws {
        let site = BrowserLinkRoute(match: .site, pattern: " https://www.GitHub.com/org/ ", destination: .littleWindow)
        for match in ["https://github.com/org", "https://docs.github.com/org/repo", "http://www.github.com/ORG/a"] {
            #expect(try site.matches(#require(URL(string: match))), "\(match)")
        }
        for miss in ["https://github.com/organization", "https://github.com/", "https://notgithub.com/org"] {
            #expect(try !site.matches(#require(URL(string: miss))), "\(miss)")
        }

        let host = BrowserLinkRoute(match: .site, pattern: "localhost:3000", destination: .littleWindow)
        #expect(try host.matches(#require(URL(string: "http://localhost:3000/a"))))
        #expect(try !host.matches(#require(URL(string: "http://localhost:4000/a"))))
        #expect(try !BrowserLinkRoute(match: .site, pattern: "  ", destination: .littleWindow)
            .matches(#require(URL(string: "https://example.com"))))
    }

    @Test func theFirstMatchingRuleWinsForWebLinksOnly() throws {
        let contains = BrowserLinkRoute(match: .contains, pattern: "Meet", destination: .littleWindow)
        let space = BrowserLinkRoute(
            match: .site,
            pattern: "google.com",
            destination: .space(profileID: "Default", spaceID: "work")
        )
        let routes = [contains, space]
        #expect(try BrowserLinkRouter
            .route(for: #require(URL(string: "https://meet.google.com/x")), in: routes) == contains)
        #expect(try BrowserLinkRouter.route(for: #require(URL(string: "https://mail.google.com")), in: routes) == space)
        #expect(try BrowserLinkRouter.route(for: #require(URL(string: "https://example.com")), in: routes) == nil)
        #expect(try BrowserLinkRouter.route(for: #require(URL(string: "mailto:meet@google.com")), in: routes) == nil)
    }

    @Test func rulesPersistInTheirOrder() throws {
        let defaults = try #require(UserDefaults(suiteName: "BrowserLinkRoutingTests.\(UUID().uuidString)"))
        let routes = [
            BrowserLinkRoute(
                pattern: "figma.com",
                destination: .space(profileID: "Work", spaceID: "s"),
                spaceTitle: "Design"
            ),
            BrowserLinkRoute(match: .contains, pattern: "zoom", destination: .littleWindow),
        ]
        BrowserUserPreferencesStore(userDefaults: defaults).linkRoutes = routes
        #expect(BrowserUserPreferencesStore(userDefaults: defaults).linkRoutes == routes)
    }

    @Test func aRoutedLinkOpensAsATabOfItsSpace() throws {
        let f = SidebarDragFixture(temporary: ["x"])
        #expect(f.model.selectedSpaceID == "s")
        #expect(f.model.canOpenLittleWindow && !f.model.opensExternalLinksInLittleWindow)

        let url = try #require(URL(string: "https://figma.com/file"))
        #expect(f.model.openURL(url, inSpaceWithID: "t"))
        #expect(f.model.selectedSpaceID == "t")
        #expect(f.driver.createdTabRequests.last?.urlString == url.absoluteString)
        #expect(f.model.tabs.first { $0.id == f.model.selectedTabID }?.spaceID == "t")

        let created = f.driver.createdTabRequests.count
        #expect(!f.model.openURL(url, inSpaceWithID: "deleted"), "A deleted Space lets the link open as usual")
        #expect(f.driver.createdTabRequests.count == created && f.model.selectedSpaceID == "t")
    }
}
