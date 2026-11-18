// BrowserEngineCookiesTests.swift

import Foundation
import Testing

// MARK: - BrowserEngineCookiesTests

struct BrowserEngineCookiesTests {
    // MARK: Private

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Internal

    @Test func aDomainCookieKeepsItsDotAndReachesSubdomains() throws {
        let cookie = BrowserChromiumCookie(
            name: "NetflixId", value: "v=1", domain: ".netflix.com", path: "/",
            isSecure: true, isHTTPOnly: true, expires: chromiumTime(now.addingTimeInterval(86400)), sameSite: .none,
        )
        let converted = try #require(cookie.httpCookie(now: now))
        #expect(converted.domain == ".netflix.com")
        #expect(converted.isSecure)
        #expect(converted.isHTTPOnly)
        #expect(!converted.isSessionOnly)
        #expect(converted.sameSitePolicy == nil)
        #expect(try abs(#require(converted.expiresDate).timeIntervalSince(now.addingTimeInterval(86400))) < 0.001)
        let storage = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        storage.setCookie(converted)
        #expect(try storage.cookies(for: #require(URL(string: "https://www.netflix.com/browse")))?
            .map(\.name) == ["NetflixId"])
    }

    @Test func aHostOnlyCookieStaysOnItsHost() throws {
        let cookie = BrowserChromiumCookie(
            name: "__Host-session", value: "abc", domain: "www.example.com", path: "/",
            isSecure: true, isHTTPOnly: false, expires: nil, sameSite: .strict,
        )
        #expect(cookie.isHostOnly)
        let converted = try #require(cookie.httpCookie(now: now))
        #expect(converted.domain == "www.example.com")
        #expect(converted.isSessionOnly)
        #expect(converted.sameSitePolicy == .sameSiteStrict)
        let storage = try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
        storage.setCookie(converted)
        #expect(try storage.cookies(for: #require(URL(string: "https://www.example.com/")))?.count == 1)
        #expect(try storage.cookies(for: #require(URL(string: "https://sub.www.example.com/")))?.isEmpty == true)
        #expect(try storage.cookies(for: #require(URL(string: "https://example.com/")))?.isEmpty == true)
    }

    @Test func sameSiteMapsToFoundationsPolicy() {
        let policies = [BrowserChromiumCookie.SameSite.unspecified, .none, .lax, .strict].map { sameSite in
            BrowserChromiumCookie(
                name: "a", value: "1", domain: ".example.com", path: "/",
                isSecure: false, isHTTPOnly: false, expires: nil, sameSite: sameSite,
            )
            .httpCookie(now: now)?
            .sameSitePolicy
        }
        #expect(policies == [nil, nil, .sameSiteLax, .sameSiteStrict])
    }

    @Test func anExpiredCookieIsDropped() {
        let cookie = BrowserChromiumCookie(
            name: "old", value: "1", domain: ".example.com", path: "/",
            isSecure: false, isHTTPOnly: false, expires: chromiumTime(now.addingTimeInterval(-1)), sameSite: .lax,
        )
        #expect(cookie.httpCookieProperties(now: now) == nil)
    }

    @Test func chromiumsClockCountsMicrosecondsFrom1601() throws {
        // 1970-01-01 in Chromium's clock.
        let cookie = BrowserChromiumCookie(
            name: "a", value: "1", domain: ".example.com", path: "/",
            isSecure: false, isHTTPOnly: false, expires: 11_644_473_600_000_000, sameSite: .lax,
        )
        #expect(try #require(cookie.expiryDate) == Date(timeIntervalSince1970: 0))
    }

    @Test func theControllersDictionaryReadsBack() throws {
        let cookie = try #require(BrowserChromiumCookie(dictionary: [
            "name": "id", "value": "x", "domain": ".max.com", "path": "/a",
            "secure": NSNumber(value: true), "httpOnly": NSNumber(value: false),
            "hasExpires": NSNumber(value: true), "expires": NSNumber(value: Int64(13_000_000_000_000_000)),
            "sameSite": NSNumber(value: 2),
        ]))
        #expect(cookie == BrowserChromiumCookie(
            name: "id", value: "x", domain: ".max.com", path: "/a",
            isSecure: true, isHTTPOnly: false, expires: 13_000_000_000_000_000, sameSite: .lax,
        ))
        let session = try #require(BrowserChromiumCookie(dictionary: [
            "name": "s", "value": "", "domain": "a.com", "path": "/",
            "hasExpires": NSNumber(value: false), "expires": NSNumber(value: Int64(5)),
        ]))
        #expect(session.expires == nil)
        #expect(session.sameSite == .unspecified)
        #expect(BrowserChromiumCookie(dictionary: ["value": "1"]) == nil)
    }

    @Test func thePageSitesSignInDomainsAndHistorySignInPagesGoAlong() {
        let parser = TestDomainParser()
        #expect(BrowserEngineCookieTransfer.domains(
            forPageURLString: "https://www.primevideo.com/detail/1",
            historyURLStrings: [
                "https://www.google.com/search?q=prime",
                "https://www.amazon.co.uk/ap/signin?openid=1",
                "https://accounts.example.org/",
                "https://news.example.net/login-help",
                "https://www.primevideo.com/",
            ],
            parser: parser,
        ) == ["primevideo.com", "amazon.com", "amazon.co.uk", "example.org", "example.net"])
        #expect(BrowserEngineCookieTransfer.domains(
            forPageURLString: "https://play.max.com/",
            historyURLStrings: [],
            parser: parser,
        ) == ["max.com", "hbomax.com"])
        #expect(BrowserEngineCookieTransfer.domains(
            forPageURLString: "openarc://settings",
            historyURLStrings: ["https://accounts.google.com/"],
            parser: parser,
        )
        .isEmpty)
    }

    @Test func cookiesMatchTheirDomainsAndSubdomainsOnly() {
        let domains = ["netflix.com", "amazon.com"]
        #expect(BrowserEngineCookieTransfer.cookieDomain(".netflix.com", matchesDomains: domains))
        #expect(BrowserEngineCookieTransfer.cookieDomain("www.netflix.com", matchesDomains: domains))
        #expect(BrowserEngineCookieTransfer.cookieDomain("WWW.Amazon.com", matchesDomains: domains))
        #expect(!BrowserEngineCookieTransfer.cookieDomain("notnetflix.com", matchesDomains: domains))
        #expect(!BrowserEngineCookieTransfer.cookieDomain(".com", matchesDomains: domains))
        #expect(!BrowserEngineCookieTransfer.cookieDomain("", matchesDomains: domains))
    }

    @Test func webKitsOwnCookiesStay() throws {
        let chromium = try [
            cookie("session", domain: ".netflix.com", value: "chromium"),
            cookie("session", domain: ".netflix.com", path: "/other", value: "chromium"),
            cookie("prefs", domain: "www.netflix.com", value: "chromium"),
        ]
        let webKit = try [cookie("session", domain: ".netflix.com", value: "webkit")]
        let added = BrowserEngineCookieTransfer.cookiesToAdd(chromium + chromium, existing: webKit)
        #expect(added.map { "\($0.name)@\($0.domain)\($0.path)" } == [
            "session@.netflix.com/other",
            "prefs@www.netflix.com/",
        ])
    }

    private func chromiumTime(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 + Double(BrowserChromiumCookie.windowsEpochOffset)) * 1_000_000)
    }

    private func cookie(_ name: String, domain: String, path: String = "/", value: String) throws -> HTTPCookie {
        try #require(HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: path]))
    }
}

// MARK: - TestDomainParser

/// Two labels, or three under a country's `co.`: enough for these hosts.
private struct TestDomainParser: BrowserDomainParsing {
    func parse(host: String) -> BrowserParsedHost? {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }
        let keepsThree = labels.count >= 3 && labels[labels.count - 2] == "co"
        let suffix = keepsThree ? labels.suffix(2).joined(separator: ".") : labels.last!
        return BrowserParsedHost(
            publicSuffix: suffix,
            registrableDomain: labels.suffix(keepsThree ? 3 : 2).joined(separator: "."),
        )
    }
}
