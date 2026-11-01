// BrowserChromiumExtensionManager.swift

import Foundation

// MARK: - BrowserChromiumExtensionManager

@MainActor final class BrowserChromiumExtensionManager: BrowserExtensionManaging {
    // MARK: Private

    private static let uBlockOriginLiteID = "ddkjiahejlhfcafbddmgiahcphecmpfh"

    private let profileDirectoryURL: URL?

    private var profilePath: String? {
        if let profileDirectoryURL {
            return profileDirectoryURL.path
        }

        return BrowserRuntimeConfiguration.currentConfiguration()?.cachePath
    }

    init(profileDirectoryURL: URL? = nil) {
        self.profileDirectoryURL = profileDirectoryURL
    }

    // MARK: Internal

    func installedExtensions() -> [BrowserExtension] {
        if let extensions = installedExtensionsFromBridge(), !extensions.isEmpty {
            return extensionsWithSnapshotMetadata(extensions)
        }

        return installedExtensionsFromProfileSnapshot()
    }

    /// Chromium leaves an extension it added by itself off until someone agrees. The browser
    /// comes with uBlock Origin Lite, so it agrees once per profile, whenever the download ends.
    func enableDefaultExtensionsOnce() {
        guard let profilePath else { return }
        let key = "browser.extensions.defaultsEnabledProfiles"
        let defaults = UserDefaults.standard
        guard defaults.stringArray(forKey: key)?.contains(profilePath) != true else { return }
        Task { [weak self] in
            for _ in 0..<120 {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                guard let installed = installedExtensions()
                    .first(where: { $0.id == Self.uBlockOriginLiteID }) else { continue }
                if !installed.isEnabled {
                    _ = setExtension(id: installed.id, isEnabled: true)
                }
                defaults.set((defaults.stringArray(forKey: key) ?? []) + [profilePath], forKey: key)
                return
            }
        }
    }

    func runAction(id: String) -> BrowserExtensionActionResult {
        guard
            let profilePath,
            let jsonString = BrowserRunExtensionAction(profilePath, id),
            let jsonData = jsonString.data(using: .utf8),
            let payload = try? JSONDecoder().decode(BrowserChromiumExtensionActionPayload.self, from: jsonData)
        else {
            return .failed
        }

        return payload.actionResult
    }

    func setExtension(id: String, isEnabled: Bool) -> Bool {
        guard let profilePath else {
            return false
        }

        return BrowserSetExtensionEnabled(profilePath, id, isEnabled)
    }

    func removeExtension(id: String) -> Bool {
        guard let profilePath else {
            return false
        }

        return BrowserRemoveExtension(profilePath, id)
    }

    private func installedExtensionsFromBridge() -> [BrowserExtension]? {
        guard
            let profilePath,
            let jsonString = BrowserCopyInstalledExtensionsJSON(profilePath),
            let jsonData = jsonString.data(using: .utf8)
        else {
            return nil
        }

        return try? JSONDecoder()
            .decode([BrowserChromiumExtensionPayload].self, from: jsonData)
            .map(\.browserExtension)
    }

    private func installedExtensionsFromProfileSnapshot() -> [BrowserExtension] {
        if let profileDirectoryURL {
            return BrowserExtensionProfileSnapshotStore.installedExtensions(
                profileDirectories: BrowserChromiumProfileDirectoryResolver.profileDirectoryCandidates(
                    profileDirectoryURL: profileDirectoryURL,
                ),
            )
        }

        guard let configuration = BrowserRuntimeConfiguration.currentConfiguration() else {
            return []
        }

        return BrowserExtensionProfileSnapshotStore.installedExtensions(
            profileDirectories: extensionProfileDirectories(configuration: configuration),
        )
    }

    private func extensionsWithSnapshotMetadata(_ extensions: [BrowserExtension]) -> [BrowserExtension] {
        let snapshotExtensionsByID = Dictionary(
            uniqueKeysWithValues: installedExtensionsFromProfileSnapshot().map { ($0.id, $0) },
        )

        return extensions.map { browserExtension in
            guard
                browserExtension.sidePanelURLString == nil,
                let snapshotExtension = snapshotExtensionsByID[browserExtension.id],
                snapshotExtension.sidePanelURLString != nil
            else {
                return browserExtension
            }

            return BrowserExtension(
                id: browserExtension.id,
                name: browserExtension.name,
                version: browserExtension.version,
                isEnabled: browserExtension.isEnabled,
                iconData: browserExtension.iconData ?? snapshotExtension.iconData,
                sidePanelURLString: snapshotExtension.sidePanelURLString,
            )
        }
    }

    private func extensionProfileDirectories(configuration: BrowserRuntimeConfiguration) -> [URL] {
        if let profileDirectoryURL {
            return BrowserChromiumProfileDirectoryResolver.profileDirectoryCandidates(
                profileDirectoryURL: profileDirectoryURL,
            )
        }

        let cacheURL = URL(fileURLWithPath: configuration.cachePath, isDirectory: true)
        let rootCacheURL = URL(fileURLWithPath: configuration.rootCachePath, isDirectory: true)

        return BrowserChromiumProfileDirectoryResolver.profileDirectoryCandidates(
            rootCacheURL: rootCacheURL,
            cacheURL: cacheURL,
        )
    }
}

// MARK: - BrowserChromiumExtensionActionPayload

private struct BrowserChromiumExtensionActionPayload: Decodable {
    enum Kind: String, Decodable {
        case popup
        case sidePanel
        case handled
    }

    let kind: Kind
    let urlString: String?

    var actionResult: BrowserExtensionActionResult {
        switch kind {
        case .popup:
            if let urlString, !urlString.isEmpty {
                return .popup(urlString: urlString)
            }
            return .failed
        case .sidePanel:
            return .sidePanel
        case .handled:
            return .handled
        }
    }
}

// MARK: - BrowserChromiumExtensionPayload

private struct BrowserChromiumExtensionPayload: Decodable {
    // MARK: Internal

    let id: String
    let name: String
    let version: String
    let isEnabled: Bool
    let iconBase64: String?
    let iconPath: String?
    let sidePanelURLString: String?

    var browserExtension: BrowserExtension {
        BrowserExtension(
            id: id,
            name: name,
            version: version,
            isEnabled: isEnabled,
            iconData: iconData,
            sidePanelURLString: sidePanelURLString,
        )
    }

    // MARK: Private

    private var iconData: Data? {
        if let iconBase64, let data = Data(base64Encoded: iconBase64) {
            return data
        }

        guard let iconPath, !iconPath.isEmpty else {
            return nil
        }

        return try? Data(contentsOf: URL(fileURLWithPath: iconPath, isDirectory: false))
    }
}
