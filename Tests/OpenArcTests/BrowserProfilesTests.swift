import Foundation
import Testing
import ZIPFoundation

@Test func profileStoreLoadsChromiumLocalStateProfilesInOrder() throws {
    let rootURL = try makeTemporaryProfileRootURL()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try writeLocalState([
        "profile": [
            "profiles_order": ["Profile 1", "Default"],
            "info_cache": [
                "Default": ["name": "Personal"],
                "Profile 1": ["name": "Work"],
            ],
        ],
    ], to: rootURL)

    let store = BrowserProfileStore(rootCacheURL: rootURL)

    #expect(store.profiles.map(\.directoryName) == ["Profile 1", "Default"])
    #expect(store.profiles.map(\.displayName) == ["Work", "Personal"])
}

@Test func profileStoreCreatesChromiumProfileDirectoryAndLocalStateEntry() throws {
    let rootURL = try makeTemporaryProfileRootURL()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let store = BrowserProfileStore(rootCacheURL: rootURL)
    let profile = store.createProfile()

    #expect(profile.directoryName == "Profile 1")
    #expect(profile.displayName == "Profile 2")
    #expect(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("Profile 1").path))

    let localState = try readLocalState(from: rootURL)
    let profileSection = try #require(localState["profile"] as? [String: Any])
    let profilesOrder = try #require(profileSection["profiles_order"] as? [String])
    let infoCache = try #require(profileSection["info_cache"] as? [String: Any])
    let profileEntry = try #require(infoCache["Profile 1"] as? [String: Any])

    #expect(profilesOrder == ["Default", "Profile 1"])
    #expect(profileEntry["name"] as? String == "Profile 2")
    #expect(profileEntry["is_ephemeral"] as? Bool == false)
}

@Test func profileStoreDeletesNonDefaultProfileDirectoryAndLocalStateEntry() throws {
    let rootURL = try makeTemporaryProfileRootURL()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let store = BrowserProfileStore(rootCacheURL: rootURL)
    let profile = store.createProfile()
    let profileURL = rootURL.appendingPathComponent(profile.directoryName, isDirectory: true)

    #expect(FileManager.default.fileExists(atPath: profileURL.path))
    #expect(store.deleteProfile(profile))
    #expect(!FileManager.default.fileExists(atPath: profileURL.path))
    #expect(store.profiles.map(\.directoryName) == ["Default"])

    let localState = try readLocalState(from: rootURL)
    let profileSection = try #require(localState["profile"] as? [String: Any])
    let profilesOrder = try #require(profileSection["profiles_order"] as? [String])
    let infoCache = try #require(profileSection["info_cache"] as? [String: Any])
    #expect(profilesOrder == ["Default"])
    #expect(infoCache[profile.directoryName] == nil)
}

@Test func profileStoreKeepsDeletedProfileHiddenWhenChromiumRestoresLocalState() throws {
    let rootURL = try makeTemporaryProfileRootURL()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let store = BrowserProfileStore(rootCacheURL: rootURL)
    let profile = store.createProfile()
    let profileURL = rootURL.appendingPathComponent(profile.directoryName, isDirectory: true)

    #expect(store.deleteProfile(profile))
    try FileManager.default.createDirectory(at: profileURL, withIntermediateDirectories: true)
    try writeLocalState([
        "profile": [
            "profiles_order": ["Default", profile.directoryName],
            "info_cache": [
                "Default": ["name": "Personal"],
                profile.directoryName: ["name": "Restored by Chromium"],
            ],
        ],
    ], to: rootURL)

    let reloadedStore = BrowserProfileStore(rootCacheURL: rootURL)

    #expect(reloadedStore.profiles.map(\.directoryName) == ["Default"])
    #expect(!FileManager.default.fileExists(atPath: profileURL.path))

    let localState = try readLocalState(from: rootURL)
    let profileSection = try #require(localState["profile"] as? [String: Any])
    let profilesOrder = try #require(profileSection["profiles_order"] as? [String])
    let infoCache = try #require(profileSection["info_cache"] as? [String: Any])
    #expect(profilesOrder == ["Default"])
    #expect(infoCache[profile.directoryName] == nil)
}

@Test func profileStoreCreatesZipBackupWithLocalStateAndProfileDirectory() throws {
    let rootURL = try makeTemporaryProfileRootURL()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    try writeLocalState([
        "profile": [
            "profiles_order": ["Default"],
            "info_cache": [
                "Default": ["name": "Personal"],
            ],
        ],
    ], to: rootURL)

    let profileDirectoryURL = rootURL.appendingPathComponent("Default", isDirectory: true)
    try FileManager.default.createDirectory(at: profileDirectoryURL, withIntermediateDirectories: true)
    try "profile preferences".write(
        to: profileDirectoryURL.appendingPathComponent("Preferences", isDirectory: false),
        atomically: true,
        encoding: .utf8
    )

    let store = BrowserProfileStore(rootCacheURL: rootURL)
    let backupURL = try store.createBackup(for: store.defaultProfile)
    let unzipURL = rootURL.appendingPathComponent("UnzippedBackup", isDirectory: true)
    try FileManager.default.unzipItem(at: backupURL, to: unzipURL)

    #expect(FileManager.default.fileExists(atPath: unzipURL.appendingPathComponent("Local State").path))
    #expect(FileManager.default.fileExists(atPath: unzipURL.appendingPathComponent("manifest.json").path))
    let preferences = try String(
        contentsOf: unzipURL.appendingPathComponent("Default/Preferences", isDirectory: false),
        encoding: .utf8
    )
    #expect(preferences == "profile preferences")
}

@Test func chromiumProfileDirectoryCandidatesPreferExactProfileDirectory() {
    let rootURL = URL(fileURLWithPath: "/tmp/OpenArcProfiles", isDirectory: true)
    let profileURL = rootURL.appendingPathComponent("Profile 1", isDirectory: true)

    let candidates = BrowserChromiumProfileDirectoryResolver.profileDirectoryCandidates(
        profileDirectoryURL: profileURL
    )

    #expect(candidates == [
        profileURL,
        profileURL.appendingPathComponent("Default", isDirectory: true),
    ])
}

private func makeTemporaryProfileRootURL() throws -> URL {
    let rootURL = FileManager.default
        .temporaryDirectory
        .appendingPathComponent("OpenArcTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    return rootURL
}

private func writeLocalState(_ localState: [String: Any], to rootURL: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: localState, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: rootURL.appendingPathComponent("Local State", isDirectory: false))
}

private func readLocalState(from rootURL: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: rootURL.appendingPathComponent("Local State", isDirectory: false))
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
