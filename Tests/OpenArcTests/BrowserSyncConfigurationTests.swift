// BrowserSyncConfigurationTests.swift

import Foundation
import Testing

@Test(arguments: [
    ("HTTPS://SYNC.EXAMPLE:443/", "https://sync.example"),
    ("http://Sync.Example:80", "http://sync.example"),
    ("https://sync.example:8443/", "https://sync.example:8443"),
    ("http://127.0.0.1:8080/", "http://127.0.0.1:8080"),
    ("http://[::1]:8080/", "http://[::1]:8080"),
]) func syncConfigurationAcceptsCanonicalHTTPRootEndpoints(input: String, expected: String) throws {
    let url = syncConfigurationFixtureURL(input)
    let configuration = try #require(BrowserSyncConfiguration(baseURL: url))
    #expect(configuration.baseURL.absoluteString == expected)
    #expect(BrowserSyncConfiguration.current(environment: ["OPENARC_SYNC_BASE_URL": input])?.baseURL == configuration
        .baseURL)
}

@Test(arguments: [
    "file:///tmp/sync",
    "ftp://sync.example",
    "wss://sync.example",
    "/relative",
    "https:///",
    "https://sync.example/api",
    "https://sync.example/api/",
    "https://sync.example//",
    "https://sync.example/%2F",
    "https://sync.example?tenant=other",
    "https://sync.example?",
    "https://sync.example#section",
    "https://sync.example#",
    "https://user@sync.example",
    "https://user:password@sync.example",
    "https://@sync.example",
]) func syncConfigurationRejectsAmbiguousOrCredentialBearingEndpoints(input: String) {
    let configuration = URL(string: input).flatMap { BrowserSyncConfiguration(baseURL: $0) }
    #expect(configuration == nil)
    #expect(BrowserSyncConfiguration.current(environment: ["OPENARC_SYNC_BASE_URL": input]) == nil)
}

@Test func syncConfigurationRequiresAnEnvironmentEndpoint() {
    #expect(BrowserSyncConfiguration.current(environment: [:]) == nil)
    #expect(BrowserSyncConfiguration.current(environment: ["OPENARC_SYNC_BASE_URL": ""]) == nil)
}

@Test func legacyAuthSessionDecodesWithoutIssuerButCannotAuthorizeSync() throws {
    let legacy = Data(
        #"{"accessToken":"legacy-token","userID":"user-1","deviceID":"device-1","userEmail":"user@example.test"}"#
            .utf8,
    )
    let session = try JSONDecoder().decode(BrowserAuthSession.self, from: legacy)
    #expect(session.accessToken == "legacy-token")
    #expect(session.userID == "user-1")
    #expect(session.deviceID == "device-1")
    #expect(session.serverURL == nil)
    #expect(!session.belongs(to: syncConfigurationFixtureURL("https://sync.example")))
}

@Test func authSessionRoundtripRetainsServerAndAllowsCanonicalEquivalentOrigin() throws {
    let session = BrowserAuthSession(
        accessToken: "token",
        userID: "user-1",
        userEmail: nil,
        deviceID: "device-1",
        serverURL: syncConfigurationFixtureURL("HTTPS://SYNC.EXAMPLE:443/"),
    )
    let restored = try JSONDecoder().decode(BrowserAuthSession.self, from: JSONEncoder().encode(session))
    #expect(restored == session)
    #expect(restored.belongs(to: syncConfigurationFixtureURL("https://sync.example")))
}

@Test(arguments: [
    "https://other.example",
    "http://sync.example",
    "https://sync.example:8443",
    "https://sync.example/another-backend",
    "https://sync.example?tenant=other",
]) func authSessionRejectsForeignEndpointEvenWithTheSameAccountID(endpoint: String) {
    let session = BrowserAuthSession(
        accessToken: "token",
        userID: "user-1",
        userEmail: nil,
        deviceID: "device-1",
        serverURL: syncConfigurationFixtureURL("https://sync.example"),
    )
    #expect(!session.belongs(to: syncConfigurationFixtureURL(endpoint)))
}

private func syncConfigurationFixtureURL(_ string: String) -> URL {
    URL(string: string)!
}
