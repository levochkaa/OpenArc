// BrowserWebAppsTests.swift

import Foundation
import Testing

@Test func webAppWindowUsesCustomBorderlessChrome() {
    #expect(BrowserWebAppLayout.windowStyleMask.contains(.borderless))
    #expect(!BrowserWebAppLayout.windowStyleMask.contains(.titled))
    #expect(!BrowserWebAppLayout.windowStyleMask.contains(.fullSizeContentView))
}

@Test func webAppWindowLayoutReservesToolbarAndDraggableWindowEdges() {
    let layout = BrowserWebAppWindowLayout(isFullscreen: false, showsToolbar: true)

    #expect(layout.toolbarHorizontalInset == BrowserWebAppLayout.windowEdgeInset)
    #expect(layout.toolbarTopInset == BrowserWebAppLayout.windowEdgeInset)
    #expect(layout.contentHorizontalInset == BrowserWebAppLayout.windowEdgeInset)
    #expect(layout.contentBottomInset == BrowserWebAppLayout.windowEdgeInset)
    #expect(layout.edgeDragInset == BrowserWebAppLayout.windowEdgeInset)
    #expect(layout.contentMinY == BrowserWebAppLayout.toolbarSurfaceHeight)
    #expect(layout.windowControlsWidth == BrowserWindowControlsLayout.totalWidth)
}

@Test func fullscreenWebAppToolbarKeepsItsOwnPaddingWithoutWindowControls() {
    let layout = BrowserWebAppWindowLayout(isFullscreen: true, showsToolbar: true)

    #expect(layout.toolbarHorizontalInset == 0)
    #expect(layout.toolbarTopInset == BrowserWebAppLayout.windowEdgeInset)
    #expect(layout.contentHorizontalInset == 0)
    #expect(layout.contentBottomInset == 0)
    #expect(layout.edgeDragInset == 0)
    #expect(layout.contentMinY == BrowserWebAppLayout.toolbarSurfaceHeight)
    #expect(layout.windowControlsWidth == 0)
}

@Test func fullscreenWebAppWithoutToolbarUsesWholeViewport() {
    let layout = BrowserWebAppWindowLayout(isFullscreen: true, showsToolbar: false)

    #expect(layout.toolbarTopInset == 0)
    #expect(layout.contentMinY == 0)
}

@Test func webAppConfigurationRequiresValidSameOriginWebURLs() throws {
    let bundleURL = URL(fileURLWithPath: "/Applications/SoundCloud.app", isDirectory: true)
    let hostBundleURL = URL(fileURLWithPath: "/Applications/OpenArc.app", isDirectory: true)
    let infoDictionary: [String: Any] = [
        BrowserWebAppConfiguration.identifierInfoKey: "app-1234",
        BrowserWebAppConfiguration.nameInfoKey: "SoundCloud",
        BrowserWebAppConfiguration.startURLInfoKey: "https://soundcloud.com/discover",
        BrowserWebAppConfiguration.scopeURLInfoKey: "https://soundcloud.com/",
        BrowserWebAppConfiguration.profileDirectoryNameInfoKey: "Default",
        BrowserWebAppConfiguration.profileNameInfoKey: "Default",
        BrowserWebAppConfiguration.hostBundlePathInfoKey: hostBundleURL.path,
    ]

    let configuration = try #require(BrowserWebAppConfiguration.configuration(
        infoDictionary: infoDictionary,
        bundleURL: bundleURL,
    ))
    #expect(configuration.name == "SoundCloud")
    #expect(configuration.startURL.absoluteString == "https://soundcloud.com/discover")
    #expect(configuration.scopeURL.absoluteString == "https://soundcloud.com/")
    #expect(configuration.hostBundleURL == hostBundleURL)
    #expect(configuration.bundleURL == bundleURL)

    var mismatchedOrigin = infoDictionary
    mismatchedOrigin[BrowserWebAppConfiguration.scopeURLInfoKey] = "https://example.com/"
    #expect(BrowserWebAppConfiguration.configuration(
        infoDictionary: mismatchedOrigin,
        bundleURL: bundleURL,
    ) == nil)

    var unsupportedStartURL = infoDictionary
    unsupportedStartURL[BrowserWebAppConfiguration.startURLInfoKey] = "file:///tmp/index.html"
    #expect(BrowserWebAppConfiguration.configuration(
        infoDictionary: unsupportedStartURL,
        bundleURL: bundleURL,
    ) == nil)
}

@Test func webAppConfigurationUsesExplicitShimBundleArgument() throws {
    let fileManager = FileManager.default
    let temporaryDirectoryURL = fileManager.temporaryDirectory
        .appendingPathComponent("BrowserWebAppArgumentTests-\(UUID().uuidString)", isDirectory: true)
    let bundleURL = temporaryDirectoryURL.appendingPathComponent("SoundCloud.app", isDirectory: true)
    let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryDirectoryURL) }
    try fileManager.createDirectory(at: contentsURL, withIntermediateDirectories: true)

    let infoDictionary: [String: Any] = [
        "CFBundleExecutable": "SoundCloud",
        "CFBundleIdentifier": "com.example.SoundCloud",
        "CFBundlePackageType": "APPL",
        BrowserWebAppConfiguration.identifierInfoKey: "app-1234",
        BrowserWebAppConfiguration.nameInfoKey: "SoundCloud",
        BrowserWebAppConfiguration.startURLInfoKey: "https://soundcloud.com/discover",
        BrowserWebAppConfiguration.scopeURLInfoKey: "https://soundcloud.com/",
        BrowserWebAppConfiguration.profileDirectoryNameInfoKey: "Default",
        BrowserWebAppConfiguration.profileNameInfoKey: "Default",
        BrowserWebAppConfiguration.hostBundlePathInfoKey: "/Applications/OpenArc.app",
    ]
    let infoData = try PropertyListSerialization.data(
        fromPropertyList: infoDictionary,
        format: .binary,
        options: 0,
    )
    try infoData.write(to: contentsURL.appendingPathComponent("Info.plist", isDirectory: false))

    let configuration = try #require(BrowserWebAppConfiguration.current(arguments: [
        "OpenArc",
        "\(BrowserWebAppConfiguration.bundleArgumentPrefix)\(bundleURL.path)",
    ]))
    #expect(configuration.bundleURL == bundleURL.standardizedFileURL)
    #expect(configuration.name == "SoundCloud")
}

@Test func webAppIdentifierIsStablePerOriginAndProfile() throws {
    let pageURL = try #require(URL(string: "https://soundcloud.com/discover?ref=home"))
    let defaultIdentifier = try #require(BrowserWebAppConfiguration.stableIdentifier(
        for: pageURL,
        profileDirectoryName: "Default",
    ))

    #expect(try defaultIdentifier == BrowserWebAppConfiguration.stableIdentifier(
        for: #require(URL(string: "https://soundcloud.com/you/likes")),
        profileDirectoryName: "Default",
    ))
    #expect(defaultIdentifier != BrowserWebAppConfiguration.stableIdentifier(
        for: pageURL,
        profileDirectoryName: "Profile 1",
    ))
    #expect(BrowserWebAppConfiguration.scopeURL(for: pageURL)?.absoluteString == "https://soundcloud.com/")
}

@Test func webAppSuggestedNamePrefersConcisePageBrand() throws {
    let pageURL = try #require(URL(string: "https://soundcloud.com/discover"))
    #expect(BrowserWebAppBundleInstaller.suggestedName(
        pageTitle: "SoundCloud — Listen to music online",
        pageURL: pageURL,
    ) == "SoundCloud")
}

@Test func webAppManifestDrivesSoundCloudInstallationMetadata() throws {
    let pageURL = try #require(URL(string: "https://soundcloud.com/you/likes"))
    let payloadJSON = #"""
    {
      "documentURL": "https://soundcloud.com/you/likes",
      "documentIcons": [
        {"href": "https://cdn.example/favicon.ico", "rel": "icon", "sizes": "48x48", "type": "image/x-icon"},
        {"href": "https://cdn.example/touch.png", "rel": "apple-touch-icon", "sizes": "180x180", "type": "image/png"}
      ],
      "manifestURL": "https://soundcloud.com/webmanifest.json",
      "manifest": {
        "name": "SoundCloud",
        "short_name": "SoundCloud",
        "description": "SoundCloud - Play Music, Audio & New Songs",
        "start_url": "/discover",
        "scope": "/",
        "display": "minimal-ui",
        "theme_color": "#FF5500",
        "background_color": "#FF5500",
        "icons": [
          {"src": "/pwa-round-icon-192x192.png", "type": "image/png", "sizes": "192x192", "purpose": "any"},
          {"src": "/pwa-round-icon-512x512.png", "type": "image/png", "sizes": "512x512", "purpose": "any"},
          {"src": "/pwa-icon-512.png", "type": "image/png", "sizes": "512x512", "purpose": "maskable"}
        ]
      }
    }
    """#

    let metadata = BrowserWebAppManifestParser.installMetadata(
        payloadJSON: payloadJSON,
        fallbackPageURL: pageURL,
        fallbackTitle: "Likes on SoundCloud",
        fallbackIconURL: URL(string: "https://soundcloud.com/favicon.ico"),
    )

    #expect(metadata.preferredName(fallbackTitle: "Likes on SoundCloud") == "SoundCloud")
    #expect(metadata.manifestURL?.absoluteString == "https://soundcloud.com/webmanifest.json")
    #expect(metadata.applicationIDURL.absoluteString == "https://soundcloud.com/discover")
    #expect(metadata.startURL.absoluteString == "https://soundcloud.com/discover")
    #expect(metadata.scopeURL.absoluteString == "https://soundcloud.com/")
    #expect(metadata.displayMode == .minimalUI)
    #expect(metadata.themeColor == "#FF5500")
    #expect(metadata.backgroundColor == "#FF5500")
    #expect(metadata.appDescription == "SoundCloud - Play Music, Audio & New Songs")
    #expect(metadata.iconURL?.absoluteString == "https://soundcloud.com/pwa-icon-512.png")
}

@Test func webAppManifestPrefersSupportedDisplayOverrideAndExplicitID() throws {
    let pageURL = try #require(URL(string: "https://example.com/current"))
    let payloadJSON = #"""
    {
      "documentURL": "https://example.com/current",
      "manifestURL": "https://example.com/app/manifest.json",
      "manifest": {
        "id": "/music-app",
        "name": "Music",
        "start_url": "./launch",
        "scope": "/",
        "display": "browser",
        "display_override": ["tabbed", "standalone"]
      }
    }
    """#

    let metadata = BrowserWebAppManifestParser.installMetadata(
        payloadJSON: payloadJSON,
        fallbackPageURL: pageURL,
        fallbackTitle: "Example",
        fallbackIconURL: nil,
    )

    #expect(metadata.applicationIDURL.absoluteString == "https://example.com/music-app")
    #expect(metadata.startURL.absoluteString == "https://example.com/app/launch")
    #expect(metadata.displayMode == .standalone)
}

@Test func webAppInstallerCreatesIndependentLaunchServicesShim() throws {
    let fileManager = FileManager.default
    let temporaryDirectoryURL = fileManager.temporaryDirectory
        .appendingPathComponent("BrowserWebAppsTests-\(UUID().uuidString)", isDirectory: true)
    let hostBundleURL = temporaryDirectoryURL.appendingPathComponent("OpenArc.app", isDirectory: true)
    let applicationsDirectoryURL = temporaryDirectoryURL.appendingPathComponent("Applications", isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryDirectoryURL) }

    try createFakeHostBundle(at: hostBundleURL, fileManager: fileManager)
    let pageURL = try #require(URL(string: "https://soundcloud.com/discover"))
    let bundleIconData = Data("test-icns".utf8)
    let installedApp = try BrowserWebAppBundleInstaller(
        hostBundleURL: hostBundleURL,
        applicationsDirectoryURL: applicationsDirectoryURL,
        fileManager: fileManager,
        bundleSigner: { _, _ in },
    ).install(BrowserWebAppInstallRequest(
        name: "SoundCloud",
        metadata: fallbackWebAppMetadata(pageURL: pageURL),
        profile: .defaultProfile,
        bundleIconData: bundleIconData,
    ))

    #expect(installedApp.bundleURL.lastPathComponent == "SoundCloud.app")
    let executableURL = installedApp.bundleURL
        .appendingPathComponent("Contents/MacOS/SoundCloud", isDirectory: false)
    let executableValues = try executableURL.resourceValues(forKeys: [.isSymbolicLinkKey])
    #expect(executableValues.isSymbolicLink == false)
    #expect(try Data(contentsOf: executableURL) == Data("#!/bin/sh\n".utf8))

    #expect(!fileManager.fileExists(atPath: installedApp.bundleURL
            .appendingPathComponent("Contents/Frameworks", isDirectory: true)
            .path))

    let infoData = try Data(contentsOf: installedApp.bundleURL
        .appendingPathComponent("Contents/Info.plist", isDirectory: false))
    let infoDictionary = try #require(
        PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
    )
    #expect(infoDictionary["CFBundleDisplayName"] as? String == "SoundCloud")
    #expect(infoDictionary["CFBundleIconFile"] as? String == "app.icns")
    #expect(infoDictionary[BrowserWebAppConfiguration.startURLInfoKey] as? String == pageURL.absoluteString)
    #expect(infoDictionary[BrowserWebAppConfiguration.hostBundlePathInfoKey] as? String == hostBundleURL.path)
    #expect(try Data(contentsOf: installedApp.bundleURL
            .appendingPathComponent("Contents/Resources/app.icns", isDirectory: false)) == bundleIconData)

    let installedBundle = try #require(Bundle(url: installedApp.bundleURL))
    let loadedConfiguration = try #require(BrowserWebAppConfiguration.current(bundle: installedBundle))
    #expect(loadedConfiguration == installedApp.configuration)
}

private func createFakeHostBundle(at bundleURL: URL, fileManager: FileManager) throws {
    let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
    let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
    try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(
        at: contentsURL.appendingPathComponent("Frameworks", isDirectory: true),
        withIntermediateDirectories: true,
    )
    try fileManager.createDirectory(
        at: contentsURL.appendingPathComponent("Resources", isDirectory: true),
        withIntermediateDirectories: true,
    )

    let executableURL = macOSURL.appendingPathComponent("OpenArc", isDirectory: false)
    try Data("#!/bin/sh\n".utf8).write(to: executableURL)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

    let launcherURL = contentsURL
        .appendingPathComponent("Resources", isDirectory: true)
        .appendingPathComponent(BrowserWebAppBundleInstaller.launcherExecutableName, isDirectory: false)
    try Data("#!/bin/sh\n".utf8).write(to: launcherURL)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherURL.path)

    let infoDictionary: [String: Any] = [
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": "OpenArc",
        "CFBundleIdentifier": "com.levochkaa.OpenArc",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "26.0",
    ]
    let infoData = try PropertyListSerialization.data(
        fromPropertyList: infoDictionary,
        format: .binary,
        options: 0,
    )
    try infoData.write(to: contentsURL.appendingPathComponent("Info.plist", isDirectory: false))
}

private func fallbackWebAppMetadata(pageURL: URL) -> BrowserWebAppInstallMetadata {
    let scopeURL = BrowserWebAppConfiguration.scopeURL(for: pageURL) ?? pageURL
    return BrowserWebAppInstallMetadata(
        sourcePageURL: pageURL,
        manifestURL: nil,
        applicationIDURL: scopeURL,
        name: nil,
        shortName: nil,
        appDescription: nil,
        startURL: pageURL,
        scopeURL: scopeURL,
        displayMode: nil,
        themeColor: nil,
        backgroundColor: nil,
        iconURL: nil,
    )
}
