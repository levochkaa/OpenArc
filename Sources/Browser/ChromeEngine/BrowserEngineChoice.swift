// BrowserEngineChoice.swift

import Foundation

// MARK: - BrowserChromiumEngine

/// What draws Chromium pages: CEF, or Chrome's own framework with OpenArc's layer (Chromium/engine).
@objc enum BrowserChromiumEngine: Int {
    case cef
    case chrome
}

// MARK: - BrowserEngineChoice

/// The engine setting. The process runs on one engine from launch to quit, so a change takes effect at the
/// next launch. CEF stays the default, and a build without the Chrome engine's framework always runs on CEF.
@objcMembers final class BrowserEngineChoice: NSObject {
    static let defaultsKey = "BrowserChromiumEngine"
    /// `--openarc-engine=chrome` or `--openarc-engine=cef` overrides the setting for one launch.
    static let argumentPrefix = "--openarc-engine="
    static let frameworkName = "OpenArc Framework"
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

    /// The engine the user chose, whatever this build carries.
    static func preferredEngine(defaults: UserDefaults = .standard) -> BrowserChromiumEngine {
        defaults.string(forKey: defaultsKey) == "chrome" ? .chrome : .cef
    }

    static func setPreferredEngine(_ engine: BrowserChromiumEngine, defaults: UserDefaults = .standard) {
        if engine == .chrome {
            defaults.set("chrome", forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
    }

    /// The engine a launch runs on: the argument's, else the setting's, and CEF without the Chrome framework.
    static func launchEngine(
        arguments: [String],
        preferred: BrowserChromiumEngine,
        chromeEngineAvailable: Bool,
    ) -> BrowserChromiumEngine {
        var engine = preferred
        if let argument = arguments.last(where: { $0.hasPrefix(argumentPrefix) }) {
            switch argument.dropFirst(argumentPrefix.count) {
            case "chrome": engine = .chrome
            case "cef": engine = .cef
            default: break
            }
        }
        return engine == .chrome && chromeEngineAvailable ? .chrome : .cef
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
    @objc(currentLaunchEngine) static func currentLaunchEngine() -> BrowserChromiumEngine {
        launchEngine(
            arguments: ProcessInfo.processInfo.arguments,
            preferred: preferredEngine(),
            chromeEngineAvailable: isChromeEngineAvailable,
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
