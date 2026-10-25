import AppKit
import Foundation

// MARK: - BrowserWebAppDisplayMode

enum BrowserWebAppDisplayMode: String, Codable, Equatable {
    case browser
    case fullscreen
    case minimalUI = "minimal-ui"
    case standalone
    case windowControlsOverlay = "window-controls-overlay"
}

// MARK: - BrowserWebAppConfiguration

struct BrowserWebAppConfiguration: Equatable {
    // MARK: Lifecycle

    init(
        identifier: String,
        name: String,
        startURL: URL,
        scopeURL: URL,
        profileDirectoryName: String,
        profileName: String,
        hostBundleURL: URL,
        bundleURL: URL,
        manifestURL: URL? = nil,
        applicationIDURL: URL? = nil,
        appDescription: String? = nil,
        displayMode: BrowserWebAppDisplayMode? = nil,
        themeColor: String? = nil,
        backgroundColor: String? = nil,
        iconURL: URL? = nil
    ) {
        self.identifier = identifier
        self.name = name
        self.startURL = startURL
        self.scopeURL = scopeURL
        self.profileDirectoryName = profileDirectoryName
        self.profileName = profileName
        self.hostBundleURL = hostBundleURL
        self.bundleURL = bundleURL
        self.manifestURL = manifestURL
        self.applicationIDURL = applicationIDURL
        self.appDescription = appDescription
        self.displayMode = displayMode
        self.themeColor = themeColor
        self.backgroundColor = backgroundColor
        self.iconURL = iconURL
    }

    // MARK: Internal

    static let identifierInfoKey = "OpenArcWebAppIdentifier"
    static let nameInfoKey = "OpenArcWebAppName"
    static let startURLInfoKey = "OpenArcWebAppStartURL"
    static let scopeURLInfoKey = "OpenArcWebAppScopeURL"
    static let profileDirectoryNameInfoKey = "OpenArcWebAppProfileDirectoryName"
    static let profileNameInfoKey = "OpenArcWebAppProfileName"
    static let hostBundlePathInfoKey = "OpenArcHostBundlePath"
    static let manifestURLInfoKey = "OpenArcWebAppManifestURL"
    static let applicationIDURLInfoKey = "OpenArcWebAppApplicationIDURL"
    static let descriptionInfoKey = "OpenArcWebAppDescription"
    static let displayModeInfoKey = "OpenArcWebAppDisplayMode"
    static let themeColorInfoKey = "OpenArcWebAppThemeColor"
    static let backgroundColorInfoKey = "OpenArcWebAppBackgroundColor"
    static let iconURLInfoKey = "OpenArcWebAppIconURL"
    static let bundleArgumentPrefix = "--web-app-bundle="

    let identifier: String
    let name: String
    let startURL: URL
    let scopeURL: URL
    let profileDirectoryName: String
    let profileName: String
    let hostBundleURL: URL
    let bundleURL: URL
    let manifestURL: URL?
    let applicationIDURL: URL?
    let appDescription: String?
    let displayMode: BrowserWebAppDisplayMode?
    let themeColor: String?
    let backgroundColor: String?
    let iconURL: URL?

    var isolatedRuntimeSuffix: String {
        "web-app-\(identifier)"
    }

    var profile: BrowserProfile {
        BrowserProfile(directoryName: profileDirectoryName, name: profileName)
    }

    static func current(
        bundle: Bundle = .main,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> BrowserWebAppConfiguration? {
        if let bundleArgument = arguments.first(where: { $0.hasPrefix(bundleArgumentPrefix) }) {
            let bundlePath = String(bundleArgument.dropFirst(bundleArgumentPrefix.count))
            let bundleURL = URL(fileURLWithPath: bundlePath, isDirectory: true).standardizedFileURL
            if let webAppBundle = Bundle(url: bundleURL),
               let configuration = configuration(
                   infoDictionary: webAppBundle.infoDictionary,
                   bundleURL: bundleURL
               )
            {
                return configuration
            }
        }

        return configuration(infoDictionary: bundle.infoDictionary, bundleURL: bundle.bundleURL)
    }

    static func configuration(
        infoDictionary: [String: Any]?,
        bundleURL: URL
    ) -> BrowserWebAppConfiguration? {
        guard
            let infoDictionary,
            let identifier = nonemptyString(infoDictionary[identifierInfoKey]),
            let name = nonemptyString(infoDictionary[nameInfoKey]),
            let startURLString = nonemptyString(infoDictionary[startURLInfoKey]),
            let startURL = validatedWebURL(startURLString),
            let scopeURLString = nonemptyString(infoDictionary[scopeURLInfoKey]),
            let scopeURL = validatedWebURL(scopeURLString),
            sameOrigin(startURL, scopeURL),
            let profileDirectoryName = nonemptyString(infoDictionary[profileDirectoryNameInfoKey]),
            let profileName = nonemptyString(infoDictionary[profileNameInfoKey]),
            let hostBundlePath = nonemptyString(infoDictionary[hostBundlePathInfoKey])
        else {
            return nil
        }

        return BrowserWebAppConfiguration(
            identifier: identifier,
            name: name,
            startURL: startURL,
            scopeURL: scopeURL,
            profileDirectoryName: profileDirectoryName,
            profileName: profileName,
            hostBundleURL: URL(fileURLWithPath: hostBundlePath, isDirectory: true),
            bundleURL: bundleURL,
            manifestURL: optionalWebURL(infoDictionary[manifestURLInfoKey]),
            applicationIDURL: optionalWebURL(infoDictionary[applicationIDURLInfoKey]),
            appDescription: nonemptyString(infoDictionary[descriptionInfoKey]),
            displayMode: nonemptyString(infoDictionary[displayModeInfoKey])
                .flatMap(BrowserWebAppDisplayMode.init(rawValue:)),
            themeColor: nonemptyString(infoDictionary[themeColorInfoKey]),
            backgroundColor: nonemptyString(infoDictionary[backgroundColorInfoKey]),
            iconURL: optionalWebURL(infoDictionary[iconURLInfoKey])
        )
    }

    static func scopeURL(for pageURL: URL) -> URL? {
        guard
            let scheme = pageURL.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = pageURL.host?.lowercased()
        else {
            return nil
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = pageURL.port
        components.path = "/"
        return components.url
    }

    static func stableIdentifier(
        for pageURL: URL,
        profileDirectoryName: String,
        applicationIDURL: URL? = nil
    ) -> String? {
        guard let scopeURL = scopeURL(for: pageURL) else {
            return nil
        }

        let identityURL = applicationIDURL ?? scopeURL
        guard sameOrigin(identityURL, scopeURL) else {
            return nil
        }

        let input = "\(identityURL.absoluteString)|\(profileDirectoryName)"
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "app-%016llx", hash)
    }

    // MARK: Private

    private static func validatedWebURL(_ string: String) -> URL? {
        guard
            let url = URL(string: string),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host?.isEmpty == false
        else {
            return nil
        }

        return url
    }

    private static func optionalWebURL(_ value: Any?) -> URL? {
        nonemptyString(value).flatMap(validatedWebURL)
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }

        let trimmedString = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedString.isEmpty ? nil : trimmedString
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port {
            return port
        }
        return url.scheme?.lowercased() == "https" ? 443 : url.scheme?.lowercased() == "http" ? 80 : nil
    }
}

// MARK: - BrowserWebAppInstallMetadata

struct BrowserWebAppInstallMetadata: Equatable {
    let sourcePageURL: URL
    let manifestURL: URL?
    let applicationIDURL: URL
    let name: String?
    let shortName: String?
    let appDescription: String?
    let startURL: URL
    let scopeURL: URL
    let displayMode: BrowserWebAppDisplayMode?
    let themeColor: String?
    let backgroundColor: String?
    let iconURL: URL?

    func preferredName(fallbackTitle: String) -> String {
        if let name {
            return name
        }
        if let shortName {
            return shortName
        }
        return BrowserWebAppBundleInstaller.suggestedName(
            pageTitle: fallbackTitle,
            pageURL: sourcePageURL
        )
    }
}

// MARK: - BrowserWebAppManifestParser

enum BrowserWebAppManifestParser {
    // MARK: Internal

    static func installMetadata(
        payloadJSON: String?,
        fallbackPageURL: URL,
        fallbackTitle _: String,
        fallbackIconURL: URL?
    ) -> BrowserWebAppInstallMetadata {
        let fallbackScopeURL = BrowserWebAppConfiguration.scopeURL(for: fallbackPageURL) ?? fallbackPageURL
        let fallback = BrowserWebAppInstallMetadata(
            sourcePageURL: fallbackPageURL,
            manifestURL: nil,
            applicationIDURL: fallbackScopeURL,
            name: nil,
            shortName: nil,
            appDescription: nil,
            startURL: fallbackPageURL,
            scopeURL: fallbackScopeURL,
            displayMode: nil,
            themeColor: nil,
            backgroundColor: nil,
            iconURL: fallbackIconURL
        )

        guard
            let payloadJSON,
            let payloadData = payloadJSON.data(using: .utf8),
            let payload = try? JSONDecoder().decode(Payload.self, from: payloadData),
            let documentURL = validatedWebURL(payload.documentURL),
            sameOrigin(documentURL, fallbackPageURL)
        else {
            return fallback
        }

        let documentIconURL = preferredDocumentIconURL(
            from: payload.documentIcons ?? [],
            documentURL: documentURL
        )
        guard
            let rawManifest = payload.manifest,
            let manifestURL = validatedWebURL(payload.manifestURL)
        else {
            return BrowserWebAppInstallMetadata(
                sourcePageURL: documentURL,
                manifestURL: nil,
                applicationIDURL: BrowserWebAppConfiguration.scopeURL(for: documentURL) ?? documentURL,
                name: nil,
                shortName: nil,
                appDescription: nil,
                startURL: documentURL,
                scopeURL: BrowserWebAppConfiguration.scopeURL(for: documentURL) ?? documentURL,
                displayMode: nil,
                themeColor: nil,
                backgroundColor: nil,
                iconURL: documentIconURL ?? fallbackIconURL
            )
        }

        let startURL = resolvedWebURL(rawManifest.startURL, relativeTo: manifestURL)
            .flatMap { sameOrigin($0, documentURL) ? removingFragment(from: $0) : nil }
            ?? removingFragment(from: documentURL)
        let defaultScope = defaultScopeURL(for: startURL)
        let specifiedScope = resolvedWebURL(rawManifest.scope, relativeTo: manifestURL)
            .flatMap { scopeURL in
                sameOrigin(scopeURL, startURL) && contains(startURL, in: scopeURL)
                    ? removingFragment(from: scopeURL)
                    : nil
            }
        let scopeURL = specifiedScope ?? defaultScope
        let applicationIDURL = resolvedWebURL(rawManifest.id, relativeTo: startURL)
            .flatMap { sameOrigin($0, startURL) ? removingFragment(from: $0) : nil }
            ?? startURL
        let displayMode = preferredDisplayMode(rawManifest)
        let manifestIconURL = preferredManifestIconURL(
            from: rawManifest.icons ?? [],
            manifestURL: manifestURL
        )

        return BrowserWebAppInstallMetadata(
            sourcePageURL: documentURL,
            manifestURL: manifestURL,
            applicationIDURL: applicationIDURL,
            name: nonempty(rawManifest.name),
            shortName: nonempty(rawManifest.shortName),
            appDescription: nonempty(rawManifest.description),
            startURL: startURL,
            scopeURL: scopeURL,
            displayMode: displayMode,
            themeColor: nonempty(rawManifest.themeColor),
            backgroundColor: nonempty(rawManifest.backgroundColor),
            iconURL: manifestIconURL ?? documentIconURL ?? fallbackIconURL
        )
    }

    // MARK: Private

    private struct Payload: Decodable {
        let documentURL: String
        let documentIcons: [DocumentIcon]?
        let manifestURL: String?
        let manifest: Manifest?
    }

    private struct DocumentIcon: Decodable {
        let href: String?
        let rel: String?
        let sizes: String?
        let type: String?
    }

    private struct Manifest: Decodable {
        enum CodingKeys: String, CodingKey {
            case id
            case name
            case shortName = "short_name"
            case description
            case startURL = "start_url"
            case scope
            case display
            case displayOverride = "display_override"
            case themeColor = "theme_color"
            case backgroundColor = "background_color"
            case icons
        }

        let id: String?
        let name: String?
        let shortName: String?
        let description: String?
        let startURL: String?
        let scope: String?
        let display: String?
        let displayOverride: [String]?
        let themeColor: String?
        let backgroundColor: String?
        let icons: [ManifestIcon]?
    }

    private struct ManifestIcon: Decodable {
        let src: String?
        let type: String?
        let sizes: String?
        let purpose: String?
    }

    private struct IconCandidate {
        let url: URL
        let purposePriority: Int
        let pixelSize: Int
        let formatPriority: Int
    }

    private static func preferredDisplayMode(_ manifest: Manifest) -> BrowserWebAppDisplayMode? {
        let candidates = (manifest.displayOverride ?? []) + [manifest.display].compactMap { $0 }
        return candidates.lazy
            .compactMap { rawValue in
                BrowserWebAppDisplayMode(rawValue: rawValue.lowercased())
            }
            .first
    }

    private static func preferredManifestIconURL(from icons: [ManifestIcon], manifestURL: URL) -> URL? {
        icons.compactMap { icon -> IconCandidate? in
            guard let url = resolvedWebURL(icon.src, relativeTo: manifestURL) else {
                return nil
            }

            let purposes = Set((nonempty(icon.purpose) ?? "any")
                .lowercased()
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init))
            let purposePriority = purposes.contains("maskable") ? 2 : purposes.contains("any") ? 1 : 0
            return IconCandidate(
                url: url,
                purposePriority: purposePriority,
                pixelSize: largestPixelSize(icon.sizes),
                formatPriority: imageFormatPriority(type: icon.type, url: url)
            )
        }
        .max(by: iconCandidateIsLessPreferred)?
        .url
    }

    private static func preferredDocumentIconURL(from icons: [DocumentIcon], documentURL: URL) -> URL? {
        icons.compactMap { icon -> IconCandidate? in
            guard let url = resolvedWebURL(icon.href, relativeTo: documentURL) else {
                return nil
            }

            let relations = Set((icon.rel ?? "")
                .lowercased()
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init))
            let relationPriority = relations.contains("apple-touch-icon")
                || relations.contains("apple-touch-icon-precomposed") ? 2 : relations.contains("icon") ? 1 : 0
            guard relationPriority > 0 else {
                return nil
            }
            return IconCandidate(
                url: url,
                purposePriority: relationPriority,
                pixelSize: largestPixelSize(icon.sizes),
                formatPriority: imageFormatPriority(type: icon.type, url: url)
            )
        }
        .max(by: iconCandidateIsLessPreferred)?
        .url
    }

    private static func iconCandidateIsLessPreferred(_ lhs: IconCandidate, _ rhs: IconCandidate) -> Bool {
        if lhs.purposePriority != rhs.purposePriority {
            return lhs.purposePriority < rhs.purposePriority
        }
        if lhs.pixelSize != rhs.pixelSize {
            return lhs.pixelSize < rhs.pixelSize
        }
        return lhs.formatPriority < rhs.formatPriority
    }

    private static func largestPixelSize(_ rawSizes: String?) -> Int {
        guard let rawSizes = nonempty(rawSizes) else {
            return 0
        }
        if rawSizes.lowercased().split(whereSeparator: { $0.isWhitespace }).contains("any") {
            return Int.max
        }

        return rawSizes.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { token in
                let dimensions = token.split(separator: "x", maxSplits: 1).compactMap { Int($0) }
                guard dimensions.count == 2 else {
                    return nil
                }
                return min(dimensions[0], dimensions[1])
            }
            .max() ?? 0
    }

    private static func imageFormatPriority(type: String?, url: URL) -> Int {
        let normalizedType = type?.lowercased() ?? ""
        let pathExtension = url.pathExtension.lowercased()
        if normalizedType == "image/png" || pathExtension == "png" {
            return 3
        }
        if normalizedType == "image/jpeg" || pathExtension == "jpg" || pathExtension == "jpeg" {
            return 2
        }
        return 1
    }

    private static func defaultScopeURL(for startURL: URL) -> URL {
        var components = URLComponents(url: startURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.query = nil
        components.fragment = nil
        let path = components.path
        if !path.hasSuffix("/") {
            let directoryPath = (path as NSString).deletingLastPathComponent
            components.path = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        }
        if components.path.isEmpty {
            components.path = "/"
        }
        return components.url ?? startURL
    }

    private static func contains(_ startURL: URL, in scopeURL: URL) -> Bool {
        guard sameOrigin(startURL, scopeURL) else {
            return false
        }
        return startURL.path.hasPrefix(scopeURL.path)
    }

    private static func resolvedWebURL(_ rawValue: String?, relativeTo baseURL: URL) -> URL? {
        guard
            let rawValue = nonempty(rawValue),
            let url = URL(string: rawValue, relativeTo: baseURL)?.absoluteURL
        else {
            return nil
        }
        return validatedWebURL(url.absoluteString)
    }

    private static func validatedWebURL(_ rawValue: String?) -> URL? {
        guard
            let rawValue,
            let url = URL(string: rawValue),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host?.isEmpty == false
        else {
            return nil
        }
        return url
    }

    private static func removingFragment(from url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url ?? url
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port {
            return port
        }
        return url.scheme?.lowercased() == "https" ? 443 : url.scheme?.lowercased() == "http" ? 80 : nil
    }

    private static func nonempty(_ rawValue: String?) -> String? {
        let trimmedValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}

// MARK: - BrowserWebAppInstallRequest

struct BrowserWebAppInstallRequest: Equatable {
    // MARK: Lifecycle

    init(
        name: String,
        metadata: BrowserWebAppInstallMetadata,
        profile: BrowserProfile,
        bundleIconData: Data? = nil
    ) {
        self.name = name
        self.metadata = metadata
        self.profile = profile
        self.bundleIconData = bundleIconData
    }

    // MARK: Internal

    let name: String
    let metadata: BrowserWebAppInstallMetadata
    let profile: BrowserProfile
    let bundleIconData: Data?

    var pageURL: URL {
        metadata.sourcePageURL
    }
}

// MARK: - BrowserInstalledWebApp

struct BrowserInstalledWebApp: Equatable {
    let configuration: BrowserWebAppConfiguration
    let bundleURL: URL
}

// MARK: - BrowserWebAppBundleInstaller

struct BrowserWebAppBundleInstaller {
    // MARK: Lifecycle

    init(
        hostBundleURL: URL,
        applicationsDirectoryURL: URL,
        fileManager: FileManager = .default,
        bundleSigner: @escaping BundleSigner = Self.signBundle
    ) {
        self.hostBundleURL = hostBundleURL
        self.applicationsDirectoryURL = applicationsDirectoryURL
        self.fileManager = fileManager
        self.bundleSigner = bundleSigner
    }

    // MARK: Internal

    typealias BundleSigner = (URL, String) throws -> Void

    static let installedAppsDirectoryName = "OpenArc Apps"
    static let launcherExecutableName = "OpenArc Web App Launcher"

    let hostBundleURL: URL
    let applicationsDirectoryURL: URL

    static func defaultApplicationsDirectoryURL(fileManager: FileManager = .default) -> URL? {
        fileManager.urls(for: .applicationDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(installedAppsDirectoryName, isDirectory: true)
    }

    static func suggestedName(pageTitle: String, pageURL: URL) -> String {
        let trimmedTitle = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleComponents = [" — ", " – ", " | ", " - "].reduce([trimmedTitle]) { components, separator in
            components.flatMap { $0.components(separatedBy: separator) }
        }
        if let conciseTitle = titleComponents
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter({ !$0.isEmpty && $0.count <= 40 })
            .min(by: { $0.count < $1.count })
        {
            return conciseTitle
        }

        if let host = pageURL.host {
            let hostComponents = host.lowercased().split(separator: ".")
            let brand = hostComponents.count > 1 ? hostComponents[hostComponents.count - 2] : hostComponents.first
            if let brand, !brand.isEmpty {
                return brand.prefix(1).uppercased() + brand.dropFirst()
            }
        }

        return BrowserStrings.applicationName
    }

    func install(_ request: BrowserWebAppInstallRequest) throws -> BrowserInstalledWebApp {
        guard
            BrowserWebAppConfiguration.scopeURL(for: request.metadata.startURL) != nil,
            let identifier = BrowserWebAppConfiguration.stableIdentifier(
                for: request.pageURL,
                profileDirectoryName: request.profile.directoryName,
                applicationIDURL: request.metadata.applicationIDURL
            )
        else {
            throw BrowserWebAppInstallationError.unsupportedURL
        }
        let scopeURL = request.metadata.scopeURL
        let legacyIdentifier = BrowserWebAppConfiguration.stableIdentifier(
            for: request.pageURL,
            profileDirectoryName: request.profile.directoryName
        )

        let appName = Self.sanitizedAppName(request.name)
        guard !appName.isEmpty else {
            throw BrowserWebAppInstallationError.invalidName
        }

        let hostInfoDictionary = try hostInfoDictionary()
        let hostExecutableName = try hostExecutableName(from: hostInfoDictionary)
        let hostExecutableURL = hostBundleURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(hostExecutableName, isDirectory: false)
        guard fileManager.isExecutableFile(atPath: hostExecutableURL.path) else {
            throw BrowserWebAppInstallationError.missingHostExecutable
        }
        let launcherExecutableURL = hostBundleURL
            .appendingPathComponent("Contents/Resources", isDirectory: true)
            .appendingPathComponent(Self.launcherExecutableName, isDirectory: false)
        guard fileManager.isExecutableFile(atPath: launcherExecutableURL.path) else {
            throw BrowserWebAppInstallationError.missingLauncherExecutable
        }

        try fileManager.createDirectory(at: applicationsDirectoryURL, withIntermediateDirectories: true)
        let destinationURL = existingBundleURL(forAny: Set([identifier, legacyIdentifier].compactMap { $0 }))
            ?? availableBundleURL(preferredName: appName)
        let stagingURL = applicationsDirectoryURL
            .appendingPathComponent(".installing-\(UUID().uuidString).app", isDirectory: true)

        do {
            try createBundle(
                at: stagingURL,
                appName: appName,
                identifier: identifier,
                request: request,
                scopeURL: scopeURL,
                hostInfoDictionary: hostInfoDictionary,
                launcherExecutableURL: launcherExecutableURL
            )
            try moveStagedBundle(from: stagingURL, to: destinationURL)
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }

        let installedBundleURL = URL(fileURLWithPath: destinationURL.path, isDirectory: true)
        let configuration = BrowserWebAppConfiguration(
            identifier: identifier,
            name: appName,
            startURL: request.metadata.startURL,
            scopeURL: scopeURL,
            profileDirectoryName: request.profile.directoryName,
            profileName: request.profile.displayName,
            hostBundleURL: hostBundleURL,
            bundleURL: installedBundleURL,
            manifestURL: request.metadata.manifestURL,
            applicationIDURL: request.metadata.applicationIDURL,
            appDescription: request.metadata.appDescription,
            displayMode: request.metadata.displayMode,
            themeColor: request.metadata.themeColor,
            backgroundColor: request.metadata.backgroundColor,
            iconURL: request.metadata.iconURL
        )
        return BrowserInstalledWebApp(configuration: configuration, bundleURL: installedBundleURL)
    }

    // MARK: Private

    private let fileManager: FileManager
    private let bundleSigner: BundleSigner

    private static func sanitizedAppName(_ rawName: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:")
        let components = rawName.components(separatedBy: invalidCharacters)
        let joinedName = components.joined(separator: "-")
        let collapsedWhitespace = joinedName
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsedWhitespace.prefix(64))
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }

    private static func sanitizedExecutableName(_ appName: String) -> String {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_. "))
        let scalars = appName.unicodeScalars.map { scalar in
            allowedCharacters.contains(scalar) ? Character(scalar) : "-"
        }
        let name = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "OpenArc Web App" : name
    }

    private static func bundleIdentifier(for identifier: String) -> String {
        "com.levochkaa.OpenArc.webapp.\(identifier)"
    }

    private static func signBundle(at bundleURL: URL, identifier: String) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign", isDirectory: false)
        process.arguments = [
            "--force",
            "--deep",
            "--sign",
            "-",
            "--identifier",
            identifier,
            "--timestamp=none",
            bundleURL.path,
        ]
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw BrowserWebAppInstallationError.bundleSigningFailed(error.localizedDescription)
        }

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw BrowserWebAppInstallationError.bundleSigningFailed(errorMessage)
        }
    }

    private func hostInfoDictionary() throws -> [String: Any] {
        let infoURL = hostBundleURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        let infoData = try Data(contentsOf: infoURL)
        guard
            let infoDictionary = try PropertyListSerialization.propertyList(from: infoData, format: nil)
            as? [String: Any]
        else {
            throw BrowserWebAppInstallationError.invalidHostBundle
        }
        return infoDictionary
    }

    private func hostExecutableName(from infoDictionary: [String: Any]) throws -> String {
        guard
            let executableName = infoDictionary["CFBundleExecutable"] as? String,
            !executableName.isEmpty
        else {
            throw BrowserWebAppInstallationError.invalidHostBundle
        }
        return executableName
    }

    private func existingBundleURL(forAny identifiers: Set<String>) -> URL? {
        guard
            let appURLs = try? fileManager.contentsOfDirectory(
                at: applicationsDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            return nil
        }

        return appURLs.first { appURL in
            let infoURL = appURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
            guard
                let infoData = try? Data(contentsOf: infoURL),
                let infoDictionary = try? PropertyListSerialization.propertyList(from: infoData, format: nil)
                as? [String: Any],
                let identifier = infoDictionary[BrowserWebAppConfiguration.identifierInfoKey] as? String
            else {
                return false
            }
            return identifiers.contains(identifier)
        }
    }

    private func availableBundleURL(preferredName: String) -> URL {
        let preferredURL = applicationsDirectoryURL
            .appendingPathComponent(preferredName, isDirectory: false)
            .appendingPathExtension("app")
        guard fileManager.fileExists(atPath: preferredURL.path) else {
            return preferredURL
        }

        var index = 2
        while true {
            let candidateURL = applicationsDirectoryURL
                .appendingPathComponent("\(preferredName) \(index)", isDirectory: false)
                .appendingPathExtension("app")
            if !fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
            index += 1
        }
    }

    private func createBundle(
        at bundleURL: URL,
        appName: String,
        identifier: String,
        request: BrowserWebAppInstallRequest,
        scopeURL: URL,
        hostInfoDictionary: [String: Any],
        launcherExecutableURL: URL
    ) throws {
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)

        let executableName = Self.sanitizedExecutableName(appName)
        try fileManager.copyItem(
            at: launcherExecutableURL,
            to: macOSURL.appendingPathComponent(executableName, isDirectory: false)
        )

        let bundleIdentifier = Self.bundleIdentifier(for: identifier)
        if let bundleIconData = request.bundleIconData {
            let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
            try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
            try bundleIconData.write(
                to: resourcesURL.appendingPathComponent("app.icns", isDirectory: false),
                options: .atomic
            )
        }

        let infoDictionary = makeInfoDictionary(
            appName: appName,
            executableName: executableName,
            bundleIdentifier: bundleIdentifier,
            identifier: identifier,
            request: request,
            scopeURL: scopeURL,
            hostInfoDictionary: hostInfoDictionary
        )
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: infoDictionary,
            format: .binary,
            options: 0
        )
        try infoData.write(
            to: contentsURL.appendingPathComponent("Info.plist", isDirectory: false),
            options: .atomic
        )
        try bundleSigner(bundleURL, bundleIdentifier)
    }

    private func makeInfoDictionary(
        appName: String,
        executableName: String,
        bundleIdentifier: String,
        identifier: String,
        request: BrowserWebAppInstallRequest,
        scopeURL: URL,
        hostInfoDictionary: [String: Any]
    ) -> [String: Any] {
        var infoDictionary: [String: Any] = [
            "CFBundleDevelopmentRegion": hostInfoDictionary["CFBundleDevelopmentRegion"] as? String ?? "en",
            "CFBundleDisplayName": appName,
            "CFBundleExecutable": executableName,
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": appName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": hostInfoDictionary["CFBundleShortVersionString"] as? String ?? "0",
            "CFBundleVersion": hostInfoDictionary["CFBundleVersion"] as? String ?? "0",
            "LSEnvironment": ["MallocNanoZone": "0"],
            "LSMinimumSystemVersion": hostInfoDictionary["LSMinimumSystemVersion"] as? String ?? "26.0",
            "NSHighResolutionCapable": true,
            "NSPrincipalClass": "NSApplication",
            BrowserWebAppConfiguration.hostBundlePathInfoKey: hostBundleURL.path,
            BrowserWebAppConfiguration.identifierInfoKey: identifier,
            BrowserWebAppConfiguration.nameInfoKey: appName,
            BrowserWebAppConfiguration.profileDirectoryNameInfoKey: request.profile.directoryName,
            BrowserWebAppConfiguration.profileNameInfoKey: request.profile.displayName,
            BrowserWebAppConfiguration.scopeURLInfoKey: scopeURL.absoluteString,
            BrowserWebAppConfiguration.startURLInfoKey: request.metadata.startURL.absoluteString,
        ]
        if request.bundleIconData != nil {
            infoDictionary["CFBundleIconFile"] = "app.icns"
        }
        infoDictionary[BrowserWebAppConfiguration.manifestURLInfoKey] = request.metadata.manifestURL?.absoluteString
        infoDictionary[BrowserWebAppConfiguration.applicationIDURLInfoKey] =
            request.metadata.applicationIDURL.absoluteString
        infoDictionary[BrowserWebAppConfiguration.descriptionInfoKey] = request.metadata.appDescription
        infoDictionary[BrowserWebAppConfiguration.displayModeInfoKey] = request.metadata.displayMode?.rawValue
        infoDictionary[BrowserWebAppConfiguration.themeColorInfoKey] = request.metadata.themeColor
        infoDictionary[BrowserWebAppConfiguration.backgroundColorInfoKey] = request.metadata.backgroundColor
        infoDictionary[BrowserWebAppConfiguration.iconURLInfoKey] = request.metadata.iconURL?.absoluteString
        return infoDictionary
    }

    private func moveStagedBundle(from stagingURL: URL, to destinationURL: URL) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL)
            return
        }

        try fileManager.moveItem(at: stagingURL, to: destinationURL)
    }
}

// MARK: - BrowserWebAppInstallationError

enum BrowserWebAppInstallationError: LocalizedError {
    case applicationsDirectoryUnavailable
    case invalidHostBundle
    case invalidName
    case bundleSigningFailed(String)
    case missingHostExecutable
    case missingLauncherExecutable
    case unsupportedURL

    // MARK: Internal

    var errorDescription: String? {
        switch self {
        case .applicationsDirectoryUnavailable:
            BrowserStrings.webAppErrorApplicationsDirectoryUnavailable
        case .invalidHostBundle:
            BrowserStrings.webAppErrorInvalidHostBundle
        case .invalidName:
            BrowserStrings.webAppErrorInvalidName
        case .bundleSigningFailed(let message):
            BrowserStrings.webAppErrorBundleSigningFailed(message)
        case .missingHostExecutable:
            BrowserStrings.webAppErrorMissingHostExecutable
        case .missingLauncherExecutable:
            BrowserStrings.webAppErrorMissingLauncherExecutable
        case .unsupportedURL:
            BrowserStrings.webAppErrorUnsupportedURL
        }
    }
}

// MARK: - BrowserWebAppPreferences

@MainActor final class BrowserWebAppPreferences: ObservableObject {
    // MARK: Lifecycle

    init(identifier: String, userDefaults: UserDefaults = .standard) {
        self.identifier = identifier
        self.userDefaults = userDefaults
        self.alwaysShowsToolbarInFullscreen = userDefaults.bool(
            forKey: Self.toolbarKey(identifier: identifier)
        )
        self.alwaysShowsFullURLs = userDefaults.bool(
            forKey: Self.fullURLKey(identifier: identifier)
        )
    }

    // MARK: Internal

    @Published var alwaysShowsToolbarInFullscreen: Bool {
        didSet {
            userDefaults.set(alwaysShowsToolbarInFullscreen, forKey: Self.toolbarKey(identifier: identifier))
        }
    }

    @Published var alwaysShowsFullURLs: Bool {
        didSet {
            userDefaults.set(alwaysShowsFullURLs, forKey: Self.fullURLKey(identifier: identifier))
        }
    }

    // MARK: Private

    private let identifier: String
    private let userDefaults: UserDefaults

    private static func toolbarKey(identifier: String) -> String {
        "browser.webApp.\(identifier).alwaysShowsToolbarInFullscreen"
    }

    private static func fullURLKey(identifier: String) -> String {
        "browser.webApp.\(identifier).alwaysShowsFullURLs"
    }
}
