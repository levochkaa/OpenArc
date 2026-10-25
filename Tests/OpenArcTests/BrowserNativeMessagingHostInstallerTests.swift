import Foundation
import Testing

@Test func applePasswordManagerHostInstallerLinksChromeManifestIntoNativeMessagingHosts() throws {
    let rootURL = try makeTemporaryNativeMessagingRootURL()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let sourceManifestURL = rootURL
        .appendingPathComponent("Chrome", isDirectory: true)
        .appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        .appendingPathComponent("com.apple.passwordmanager.json", isDirectory: false)
    try writeApplePasswordManagerManifest(to: sourceManifestURL)

    try BrowserNativeMessagingHostInstaller(manifestCandidates: [sourceManifestURL])
        .installApplePasswordManagerHostIfAvailable(in: rootURL)

    let installedManifestURL = rootURL
        .appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        .appendingPathComponent("com.apple.passwordmanager.json", isDirectory: false)
    let installedManifestData = try Data(contentsOf: installedManifestURL)
    let sourceManifestData = try Data(contentsOf: sourceManifestURL)

    #expect(installedManifestData == sourceManifestData)
}

@Test func applePasswordManagerHostInstallerReplacesStaleManifest() throws {
    let rootURL = try makeTemporaryNativeMessagingRootURL()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let sourceManifestURL = rootURL
        .appendingPathComponent("Chrome", isDirectory: true)
        .appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        .appendingPathComponent("com.apple.passwordmanager.json", isDirectory: false)
    try writeApplePasswordManagerManifest(to: sourceManifestURL)

    let installedManifestURL = rootURL
        .appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        .appendingPathComponent("com.apple.passwordmanager.json", isDirectory: false)
    try FileManager.default.createDirectory(
        at: installedManifestURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try "stale".write(to: installedManifestURL, atomically: true, encoding: .utf8)

    try BrowserNativeMessagingHostInstaller(manifestCandidates: [sourceManifestURL])
        .installApplePasswordManagerHostIfAvailable(in: rootURL)

    let installedManifestData = try Data(contentsOf: installedManifestURL)
    let sourceManifestData = try Data(contentsOf: sourceManifestURL)

    #expect(installedManifestData == sourceManifestData)
}

@Test func applePasswordManagerHostInstallerDoesNothingWhenManifestIsUnavailable() throws {
    let rootURL = try makeTemporaryNativeMessagingRootURL()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let missingManifestURL = rootURL
        .appendingPathComponent("Missing", isDirectory: true)
        .appendingPathComponent("com.apple.passwordmanager.json", isDirectory: false)

    try BrowserNativeMessagingHostInstaller(manifestCandidates: [missingManifestURL])
        .installApplePasswordManagerHostIfAvailable(in: rootURL)

    #expect(!FileManager.default.fileExists(
        atPath: rootURL.appendingPathComponent("NativeMessagingHosts", isDirectory: true).path
    ))
}

private func makeTemporaryNativeMessagingRootURL() throws -> URL {
    let rootURL = FileManager.default
        .temporaryDirectory
        .appendingPathComponent("OpenArcTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    return rootURL
}

private func writeApplePasswordManagerManifest(to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let manifest: [String: Any] = [
        "allowed_origins": [
            "chrome-extension://pejdijmoenmkgeppbflobdenhhabjlaj/",
            "chrome-extension://mfbcdcnpokpoajjciilocoachedjkima/",
        ],
        "description": "PasswordManagerBrowserExtensionHelper",
        "name": "com.apple.passwordmanager",
        "path":
            "/System/Cryptexes/App/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app/Contents/MacOS/PasswordManagerBrowserExtensionHelper",
        "type": "stdio",
    ]
    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
}
