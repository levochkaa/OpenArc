// BrowserNativeMessagingHostInstallerTests.swift

import Foundation
import Testing

@Test func applePasswordManagerHostLinkFromEarlierBuildsIsRemoved() throws {
    let rootURL = try makeTemporaryNativeMessagingRootURL()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceManifestURL = try appleManifest(in: rootURL)
    let installedURL = installedManifestURL(in: rootURL)
    try FileManager.default.createDirectory(
        at: installedURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
    )
    try FileManager.default.createSymbolicLink(at: installedURL, withDestinationURL: sourceManifestURL)

    try BrowserNativeMessagingHostInstaller(manifestCandidates: [sourceManifestURL])
        .removeApplePasswordManagerHost(in: rootURL)

    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: installedURL.path)) == nil)
    #expect(FileManager.default.fileExists(atPath: sourceManifestURL.path), "Apple's own manifest stays")
}

@Test func applePasswordManagerHostCopyIsRemovedButOtherHostsStay() throws {
    let rootURL = try makeTemporaryNativeMessagingRootURL()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceManifestURL = try appleManifest(in: rootURL)
    let installedURL = installedManifestURL(in: rootURL)
    try FileManager.default.createDirectory(
        at: installedURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
    )
    try FileManager.default.copyItem(at: sourceManifestURL, to: installedURL)
    let otherURL = installedURL.deletingLastPathComponent().appendingPathComponent("com.example.host.json")
    try Data("{}".utf8).write(to: otherURL)

    try BrowserNativeMessagingHostInstaller(manifestCandidates: [sourceManifestURL])
        .removeApplePasswordManagerHost(in: rootURL)

    #expect(!FileManager.default.fileExists(atPath: installedURL.path))
    #expect(FileManager.default.fileExists(atPath: otherURL.path), "Another host is the user's")
}

@Test func aManifestTheUserChangedIsLeftAlone() throws {
    let rootURL = try makeTemporaryNativeMessagingRootURL()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceManifestURL = try appleManifest(in: rootURL)
    let installedURL = installedManifestURL(in: rootURL)
    try FileManager.default.createDirectory(
        at: installedURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
    )
    try Data("{\"name\": \"com.apple.passwordmanager\", \"path\": \"/custom\"}".utf8).write(to: installedURL)

    try BrowserNativeMessagingHostInstaller(manifestCandidates: [sourceManifestURL])
        .removeApplePasswordManagerHost(in: rootURL)

    #expect(FileManager.default.fileExists(atPath: installedURL.path))
    try BrowserNativeMessagingHostInstaller(manifestCandidates: [sourceManifestURL])
        .removeApplePasswordManagerHost(in: rootURL.appendingPathComponent("Missing"))
}

private func installedManifestURL(in rootURL: URL) -> URL {
    rootURL
        .appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        .appendingPathComponent("com.apple.passwordmanager.json", isDirectory: false)
}

private func appleManifest(in rootURL: URL) throws -> URL {
    let url = rootURL
        .appendingPathComponent("Chrome", isDirectory: true)
        .appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        .appendingPathComponent("com.apple.passwordmanager.json", isDirectory: false)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("""
    {"name": "com.apple.passwordmanager", "path": "/System/Cryptexes/App/helper", "type": "stdio"}
    """.utf8).write(to: url)
    return url
}

private func makeTemporaryNativeMessagingRootURL() throws -> URL {
    let rootURL = FileManager.default
        .temporaryDirectory
        .appendingPathComponent("OpenArcTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    return rootURL
}
