import Foundation

@objcMembers public final class BrowserRuntimeConfiguration: NSObject {
    // MARK: Lifecycle

    private init(
        helperExecutablePath: String,
        frameworkPath: String,
        mainBundlePath: String,
        rootCachePath: String,
        cachePath: String,
        sessionStoragePath: String
    ) {
        self.helperExecutablePath = helperExecutablePath
        self.frameworkPath = frameworkPath
        self.mainBundlePath = mainBundlePath
        self.rootCachePath = rootCachePath
        self.cachePath = cachePath
        self.sessionStoragePath = sessionStoragePath
        super.init()
    }

    // MARK: Public

    public let helperExecutablePath: String
    public let frameworkPath: String
    public let mainBundlePath: String
    public let rootCachePath: String
    public let cachePath: String
    public let sessionStoragePath: String

    @objc(currentConfiguration) public static func currentConfiguration() -> BrowserRuntimeConfiguration? {
        let fileManager = FileManager.default
        let webAppConfiguration = BrowserWebAppConfiguration.current()
        let bundlePath = webAppConfiguration?.hostBundleURL.path ?? Bundle.main.bundlePath
        let frameworksPath = URL(fileURLWithPath: bundlePath, isDirectory: true)
            .appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let helperExecutablePath = frameworksPath
            .appendingPathComponent("TheBrowser Helper.app", isDirectory: true)
            .appendingPathComponent("Contents/MacOS/TheBrowser Helper", isDirectory: false)
        let frameworkPath = frameworksPath
            .appendingPathComponent("Chromium Embedded Framework.framework", isDirectory: true)
        guard let applicationSupportPath = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
        else {
            return nil
        }

        let browserSupportPath = applicationSupportPath
            .appendingPathComponent("TheBrowser", isDirectory: true)
        let runtimeSuffix = webAppConfiguration?.isolatedRuntimeSuffix
            ?? BrowserRuntimeIdentity.suffix(arguments: ProcessInfo.processInfo.arguments)
        let sessionStoragePath = browserSupportPath
            .appendingPathComponent(
                BrowserRuntimeIdentity.sessionDirectoryName(suffix: runtimeSuffix),
                isDirectory: true
            )
        let rootCacheDirectory = BrowserRuntimeIdentity.rootCacheDirectoryName(suffix: runtimeSuffix)
        let rootCachePath = browserSupportPath
            .appendingPathComponent(rootCacheDirectory, isDirectory: true)
        let cachePath = rootCachePath
            .appendingPathComponent(BrowserProfile.defaultDirectoryName, isDirectory: true)

        do {
            try fileManager.createDirectory(at: sessionStoragePath, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: cachePath, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        BrowserNativeMessagingHostInstaller.installApplePasswordManagerHostIfAvailable(
            in: rootCachePath,
            fileManager: fileManager
        )

        return BrowserRuntimeConfiguration(
            helperExecutablePath: helperExecutablePath.path,
            frameworkPath: frameworkPath.path,
            mainBundlePath: bundlePath,
            rootCachePath: rootCachePath.path,
            cachePath: cachePath.path,
            sessionStoragePath: sessionStoragePath.path
        )
    }
}
