// BrowserEngineChoiceTests.swift

import Foundation
import Testing

// MARK: - BrowserEngineChoiceTests

struct BrowserEngineChoiceTests {
    @Test func cefIsTheDefaultAndChromeIsRemembered() throws {
        let defaults = try scratchDefaults()
        #expect(BrowserEngineChoice.preferredEngine(defaults: defaults) == .cef)
        BrowserEngineChoice.setPreferredChromiumEngine(.chrome, defaults: defaults)
        #expect(BrowserEngineChoice.preferredEngine(defaults: defaults) == .chrome)
        BrowserEngineChoice.setPreferredChromiumEngine(.cef, defaults: defaults)
        #expect(BrowserEngineChoice.preferredEngine(defaults: defaults) == .cef)
        #expect(defaults.object(forKey: BrowserEngineChoice.defaultsKey) == nil)
    }

    @Test func theWebKitToggleKeepsTheChromiumChoiceForWhenItIsOff() throws {
        let defaults = try scratchDefaults()
        BrowserEngineChoice.setPreferredChromiumEngine(.chrome, defaults: defaults)
        BrowserEngineChoice.setWebKitPreferred(true, defaults: defaults)
        #expect(BrowserEngineChoice.preferredEngine(defaults: defaults) == .webKit)
        #expect(BrowserEngineChoice.preferredChromiumEngine(defaults: defaults) == .chrome)
        BrowserEngineChoice.setWebKitPreferred(false, defaults: defaults)
        #expect(BrowserEngineChoice.preferredEngine(defaults: defaults) == .chrome)
        #expect(defaults.object(forKey: BrowserEngineChoice.webKitDefaultsKey) == nil)
    }

    @Test func aLaunchRunsOnWebKitWhenChosenOrWithoutCEF() {
        #expect(BrowserEngineChoice.launchEngine(arguments: [], preferred: .webKit, chromeEngineAvailable: true)
            == .webKit)
        #expect(BrowserEngineChoice.launchEngine(
            arguments: [],
            preferred: .cef,
            chromeEngineAvailable: false,
            cefAvailable: false,
        ) == .webKit)
        // Chrome's choice without its framework falls to CEF, and without CEF on to WebKit.
        #expect(BrowserEngineChoice.launchEngine(
            arguments: [],
            preferred: .chrome,
            chromeEngineAvailable: false,
            cefAvailable: false,
        ) == .webKit)
        #expect(BrowserEngineChoice.launchEngine(
            arguments: [],
            preferred: .chrome,
            chromeEngineAvailable: true,
            cefAvailable: false,
        ) == .chrome)
    }

    @Test func theCEFFrameworkIsFoundByItsBinary() throws {
        let fileManager = FileManager.default
        let bundle = fileManager.temporaryDirectory.appendingPathComponent("EngineChoice-\(UUID().uuidString).app")
        defer { try? fileManager.removeItem(at: bundle) }
        #expect(!BrowserEngineChoice.cefFrameworkAvailable(bundlePath: bundle.path))
        let framework = bundle.appendingPathComponent("Contents/Frameworks/Chromium Embedded Framework.framework")
        try fileManager.createDirectory(at: framework, withIntermediateDirectories: true)
        #expect(!BrowserEngineChoice.cefFrameworkAvailable(bundlePath: bundle.path))
        try Data().write(to: framework.appendingPathComponent("Chromium Embedded Framework"))
        #expect(BrowserEngineChoice.cefFrameworkAvailable(bundlePath: bundle.path))
    }

    @Test func aLaunchRunsOnChromeOnlyWhenChosenAndCarried() {
        #expect(BrowserEngineChoice.launchEngine(arguments: [], preferred: .chrome, chromeEngineAvailable: true)
            == .chrome)
        #expect(BrowserEngineChoice.launchEngine(arguments: [], preferred: .chrome, chromeEngineAvailable: false)
            == .cef)
        #expect(BrowserEngineChoice.launchEngine(arguments: [], preferred: .cef, chromeEngineAvailable: true)
            == .cef)
    }

    @Test func theLaunchArgumentOverridesTheSetting() {
        let chrome = ["OpenArc", "--openarc-engine=chrome"]
        let cef = ["OpenArc", "--openarc-engine=cef"]
        #expect(BrowserEngineChoice.launchEngine(arguments: chrome, preferred: .cef, chromeEngineAvailable: true)
            == .chrome)
        #expect(BrowserEngineChoice.launchEngine(arguments: cef, preferred: .chrome, chromeEngineAvailable: true)
            == .cef)
        #expect(BrowserEngineChoice.launchEngine(arguments: chrome, preferred: .cef, chromeEngineAvailable: false)
            == .cef)
        let webKit = ["OpenArc", "--openarc-engine=webkit"]
        #expect(BrowserEngineChoice.launchEngine(arguments: webKit, preferred: .chrome, chromeEngineAvailable: true)
            == .webKit)
        #expect(BrowserEngineChoice.launchEngine(arguments: cef, preferred: .webKit, chromeEngineAvailable: true)
            == .cef)
        let unknown = ["OpenArc", "--openarc-engine=gecko"]
        #expect(BrowserEngineChoice.launchEngine(arguments: unknown, preferred: .chrome, chromeEngineAvailable: true)
            == .chrome)
    }

    @Test func chromeGetsTheDataFolderAndOnlySwitches() {
        let arguments = BrowserEngineChoice.chromeArguments(
            executablePath: "/Applications/OpenArc.app/Contents/MacOS/OpenArc",
            arguments: ["OpenArc", "https://example.com", "--remote-debugging-port=9222", "--openarc-engine=chrome"],
            userDataPath: "/tmp/OpenArc/CEF",
        )
        #expect(arguments.first == "/Applications/OpenArc.app/Contents/MacOS/OpenArc")
        #expect(arguments.contains("--user-data-dir=/tmp/OpenArc/CEF"))
        #expect(arguments.contains("--no-startup-window"))
        #expect(arguments.contains("--remote-debugging-port=9222"))
        #expect(!arguments.contains("https://example.com"))
        #expect(!arguments.contains("--openarc-engine=chrome"))
        #expect(arguments.contains("--enable-features=DisableTabDiscarding"))
        #expect(arguments.contains("--disable-features=UrgentPageDiscarding"))
    }

    @Test func theLaunchsFeatureListsJoinTheEnginesOwn() {
        let arguments = BrowserEngineChoice.chromeArguments(
            executablePath: "OpenArc",
            arguments: ["OpenArc", "--enable-features=Foo,DisableTabDiscarding", "--disable-features=Bar"],
            userDataPath: "/tmp/data",
        )
        #expect(arguments
            .filter { $0.hasPrefix("--enable-features=") } == ["--enable-features=Foo,DisableTabDiscarding"])
        #expect(arguments
            .filter { $0.hasPrefix("--disable-features=") } == ["--disable-features=Bar,UrgentPageDiscarding"])
    }

    @Test func theFrameworkIsFoundThroughItsVersionFolder() throws {
        let fileManager = FileManager.default
        let bundle = fileManager.temporaryDirectory.appendingPathComponent("EngineChoice-\(UUID().uuidString).app")
        defer { try? fileManager.removeItem(at: bundle) }
        #expect(BrowserEngineChoice.frameworkBinaryPath(bundlePath: bundle.path) == nil)

        let versions = bundle.appendingPathComponent("Contents/Frameworks/OpenArc Framework.framework/Versions")
        let version = versions.appendingPathComponent("148.0.7778.180")
        try fileManager.createDirectory(at: version, withIntermediateDirectories: true)
        let binary = version.appendingPathComponent("OpenArc Framework")
        try Data().write(to: binary)
        // Not executable yet: not a framework the app can load.
        #expect(BrowserEngineChoice.frameworkBinaryPath(bundlePath: bundle.path) == nil)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        #expect(BrowserEngineChoice.frameworkBinaryPath(bundlePath: bundle.path) == binary.resolvingSymlinksInPath()
            .path)

        try fileManager.createSymbolicLink(
            atPath: versions.appendingPathComponent("Current").path,
            withDestinationPath: "148.0.7778.180",
        )
        #expect(BrowserEngineChoice.frameworkBinaryPath(bundlePath: bundle.path) == binary.resolvingSymlinksInPath()
            .path)
    }

    private func scratchDefaults() throws -> UserDefaults {
        let name = "BrowserEngineChoiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
