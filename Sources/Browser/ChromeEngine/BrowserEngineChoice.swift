// BrowserEngineChoice.swift

import Foundation

// MARK: - BrowserEngine

/// What draws the app's pages: CEF, Chrome's own framework with OpenArc's layer (Chromium/engine), or WebKit,
/// which loads no Chromium at all (docs/webkit-engine.md).
@objc enum BrowserEngine: Int {
    case cef
    case chrome
    case webKit

    /// The value of the setting and of `--openarc-engine=`.
    var key: String {
        switch self {
        case .cef: "cef"
        case .chrome: "chrome"
        case .webKit: "webkit"
        }
    }

    init?(key: some StringProtocol) {
        switch key {
        case "cef": self = .cef
        case "chrome": self = .chrome
        case "webkit": self = .webKit
        default: return nil
        }
    }
}

// MARK: - BrowserEngineChoice

/// The engine setting. The process runs on one engine from launch to quit, so a change takes effect at the
/// next launch. CEF stays the default. A build without the Chrome engine's framework runs Chrome's choice on
/// CEF, and a build without CEF (one for the Mac App Store) runs on WebKit.
@objcMembers final class BrowserEngineChoice: NSObject {
    static let defaultsKey = "BrowserChromiumEngine"
    static let webKitDefaultsKey = "BrowserWebKitEngine"
    /// `--openarc-engine=cef`, `chrome` or `webkit` overrides the setting for one launch.
    static let argumentPrefix = "--openarc-engine="
    static let frameworkName = "OpenArc Framework"
    static let cefFrameworkName = "Chromium Embedded Framework"
    static let entryPointName = "OpenArcChromeEngineMain"
    /// Settings asks the app to relaunch on the engine just chosen.
    static let relaunchRequestedNotification = Notification.Name("BrowserEngineChoiceRelaunchRequested")

    /// Features the Chrome engine always runs with. To Chrome every OpenArc page is a background tab of a hidden
    /// window, and a discarded tab gets new contents that OpenArc's tab never sees, so Chrome discards none.
    static let enabledChromeFeatures = ["DisableTabDiscarding"]
    static let disabledChromeFeatures = ["UrgentPageDiscarding"]

    static var isChromeEngineAvailable: Bool {
        frameworkBinaryPath(bundlePath: Bundle.main.bundlePath) != nil
    }

    /// The bundle carries CEF. A Mac App Store build leaves it out and runs on WebKit only.
    static var isCEFAvailable: Bool {
        cefFrameworkAvailable(bundlePath: Bundle.main.bundlePath)
    }

    /// The engine the user chose, whatever this build carries: WebKit while its toggle is on, else the
    /// Chromium engine.
    static func preferredEngine(defaults: UserDefaults = .standard) -> BrowserEngine {
        defaults.bool(forKey: webKitDefaultsKey) ? .webKit : preferredChromiumEngine(defaults: defaults)
    }

    /// CEF or Chrome, the Chromium engine the app runs on while WebKit is off.
    static func preferredChromiumEngine(defaults: UserDefaults = .standard) -> BrowserEngine {
        defaults.string(forKey: defaultsKey) == BrowserEngine.chrome.key ? .chrome : .cef
    }

    /// CEF or Chrome for Chromium pages; WebKit keeps its own toggle.
    static func setPreferredChromiumEngine(_ engine: BrowserEngine, defaults: UserDefaults = .standard) {
        if engine == .chrome {
            defaults.set(BrowserEngine.chrome.key, forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
    }

    /// The WebKit toggle. Off, the app goes back to the Chromium engine chosen before.
    static func isWebKitPreferred(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: webKitDefaultsKey)
    }

    static func setWebKitPreferred(_ preferred: Bool, defaults: UserDefaults = .standard) {
        if preferred {
            defaults.set(true, forKey: webKitDefaultsKey)
        } else {
            defaults.removeObject(forKey: webKitDefaultsKey)
        }
    }

    /// The engine a launch runs on: the argument's, else the setting's. Chrome without its framework runs on
    /// CEF, and CEF without its framework on WebKit.
    static func launchEngine(
        arguments: [String],
        preferred: BrowserEngine,
        chromeEngineAvailable: Bool,
        cefAvailable: Bool = true,
    ) -> BrowserEngine {
        var engine = preferred
        if let argument = arguments.last(where: { $0.hasPrefix(argumentPrefix) }),
           let chosen = BrowserEngine(key: argument.dropFirst(argumentPrefix.count))
        {
            engine = chosen
        }
        if engine == .chrome, !chromeEngineAvailable {
            engine = .cef
        }
        if engine == .cef, !cefAvailable {
            engine = .webKit
        }
        return engine
    }

    /// `Contents/Frameworks/Chromium Embedded Framework.framework` holds CEF's binary.
    static func cefFrameworkAvailable(bundlePath: String, fileManager: FileManager = .default) -> Bool {
        let binary = URL(fileURLWithPath: bundlePath, isDirectory: true)
            .appendingPathComponent("Contents/Frameworks/\(cefFrameworkName).framework", isDirectory: true)
            .appendingPathComponent(cefFrameworkName, isDirectory: false)
            .resolvingSymlinksInPath()
        return fileManager.fileExists(atPath: binary.path)
    }

    /// The framework's binary in an app bundle, `Contents/Frameworks/OpenArc Framework.framework/Versions/<v>/…`,
    /// or nil when the bundle doesn't carry the Chrome engine.
    static func frameworkBinaryPath(bundlePath: String, fileManager: FileManager = .default) -> String? {
        let versions = URL(fileURLWithPath: bundlePath, isDirectory: true)
            .appendingPathComponent("Contents/Frameworks/\(frameworkName).framework/Versions", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(atPath: versions.path) else { return nil }
        // Chrome's framework names its one version folder after the Chromium version; Current links to it.
        let version = entries.contains("Current") ? "Current" : entries.sorted().last
        guard let version else { return nil }
        let binary = versions.appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent(frameworkName, isDirectory: false)
            .resolvingSymlinksInPath()
        return fileManager.isExecutableFile(atPath: binary.path) ? binary.path : nil
    }

    /// For main(): the engine this launch runs on.
    @objc(currentLaunchEngine) static func currentLaunchEngine() -> BrowserEngine {
        launchEngine(
            arguments: ProcessInfo.processInfo.arguments,
            preferred: preferredEngine(),
            chromeEngineAvailable: isChromeEngineAvailable,
            cefAvailable: isCEFAvailable,
        )
    }

    /// Chrome's switches for a launch on its framework: OpenArc's data folder as Chrome's user data, and none
    /// of Chrome's own start-up windows or prompts.
    static func chromeArguments(executablePath: String, arguments: [String], userDataPath: String) -> [String] {
        var result = [executablePath]
        result.append("--user-data-dir=\(userDataPath)")
        result.append("--no-first-run")
        result.append("--no-default-browser-check")
        result.append("--no-startup-window")
        // Only switches go on; a page address in the arguments is the app's to open, not Chrome's.
        let switches = arguments.dropFirst().filter { $0.hasPrefix("--") && !$0.hasPrefix(argumentPrefix) }
        // Chromium reads one --enable-features and one --disable-features, so the launch's own lists join ours.
        let enable = "--enable-features=", disable = "--disable-features="
        func features(_ prefix: String) -> [String] {
            switches.filter { $0.hasPrefix(prefix) }
                .flatMap { $0.dropFirst(prefix.count).split(separator: ",").map(String.init) }
        }
        result += switches.filter { !$0.hasPrefix(enable) && !$0.hasPrefix(disable) }
        let enabled = features(enable) + enabledChromeFeatures.filter { !features(enable).contains($0) }
        let disabled = features(disable) + disabledChromeFeatures.filter { !features(disable).contains($0) }
        result.append(enable + enabled.joined(separator: ","))
        result.append(disable + disabled.joined(separator: ","))
        return result
    }

    @objc(chromeArgumentsForUserDataPath:) static func chromeArguments(userDataPath: String) -> [String] {
        chromeArguments(
            executablePath: ProcessInfo.processInfo.arguments.first ?? Bundle.main.executablePath ?? "OpenArc",
            arguments: ProcessInfo.processInfo.arguments,
            userDataPath: userDataPath,
        )
    }
}
