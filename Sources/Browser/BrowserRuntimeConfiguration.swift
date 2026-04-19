import Foundation

@objcMembers
public final class BrowserRuntimeConfiguration: NSObject {
    public let helperExecutablePath: String
    public let frameworkPath: String
    public let mainBundlePath: String
    public let rootCachePath: String
    public let cachePath: String

    @objc(currentConfiguration)
    public static func currentConfiguration() -> BrowserRuntimeConfiguration? {
        let fileManager = FileManager.default
        let bundlePath = Bundle.main.bundlePath
        let frameworksPath = URL(fileURLWithPath: bundlePath, isDirectory: true)
            .appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let helperExecutablePath = frameworksPath
            .appendingPathComponent("TheBrowser Helper.app", isDirectory: true)
            .appendingPathComponent("Contents/MacOS/TheBrowser Helper", isDirectory: false)
        let frameworkPath = frameworksPath
            .appendingPathComponent("Chromium Embedded Framework.framework", isDirectory: true)
        guard let applicationSupportPath = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        let browserSupportPath = applicationSupportPath
            .appendingPathComponent("TheBrowser", isDirectory: true)
        let rootCachePath = browserSupportPath
            .appendingPathComponent("CEF", isDirectory: true)
        let cachePath = rootCachePath
            .appendingPathComponent("Profile", isDirectory: true)

        do {
            try fileManager.createDirectory(at: cachePath, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        return BrowserRuntimeConfiguration(
            helperExecutablePath: helperExecutablePath.path,
            frameworkPath: frameworkPath.path,
            mainBundlePath: bundlePath,
            rootCachePath: rootCachePath.path,
            cachePath: cachePath.path
        )
    }

    private init(
        helperExecutablePath: String,
        frameworkPath: String,
        mainBundlePath: String,
        rootCachePath: String,
        cachePath: String
    ) {
        self.helperExecutablePath = helperExecutablePath
        self.frameworkPath = frameworkPath
        self.mainBundlePath = mainBundlePath
        self.rootCachePath = rootCachePath
        self.cachePath = cachePath
        super.init()
    }
}
