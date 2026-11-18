// BrowserProfiles.swift

import Combine
import Foundation

// MARK: - BrowserProfile

struct BrowserProfile: Equatable, Identifiable {
    static let defaultDirectoryName = "Default"
    static let defaultName = "Default"
    static let placeholderNames: Set = ["Your Chromium", "Your OpenArc"]

    static var defaultProfile: BrowserProfile {
        BrowserProfile(directoryName: defaultDirectoryName, name: defaultName)
    }

    let directoryName: String
    var name: String

    var id: String {
        directoryName
    }

    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Chromium's placeholder name, or the one the app gives it before Chromium starts.
        return trimmedName.isEmpty || (isDefault && Self.placeholderNames.contains(trimmedName))
            ? Self.defaultName
            : trimmedName
    }

    var isDefault: Bool {
        directoryName == Self.defaultDirectoryName
    }
}

// MARK: - BrowserProfileStore

final class BrowserProfileStore: ObservableObject {
    // MARK: Private

    private typealias JSONObject = [String: Any]

    // MARK: Internal

    @Published private(set) var profiles: [BrowserProfile]

    let rootCacheURL: URL

    private let fileManager: FileManager

    var defaultProfile: BrowserProfile {
        profile(withID: BrowserProfile.defaultDirectoryName) ?? BrowserProfile.defaultProfile
    }

    private var localStateURL: URL {
        rootCacheURL.appendingPathComponent("Local State", isDirectory: false)
    }

    private var deletedProfilesURL: URL {
        rootCacheURL.appendingPathComponent("OpenArc Deleted Profiles.json", isDirectory: false)
    }

    init(rootCacheURL: URL, fileManager: FileManager = .default) {
        self.rootCacheURL = rootCacheURL
        self.fileManager = fileManager
        self.profiles = []
        refresh()
    }

    func profile(withID profileID: String) -> BrowserProfile? {
        profiles.first { $0.id == profileID }
    }

    func profileDirectoryURL(for profile: BrowserProfile) -> URL {
        rootCacheURL.appendingPathComponent(profile.directoryName, isDirectory: true)
    }

    /// A new profile, named `name` when given.
    @discardableResult func createProfile(named name: String? = nil) -> BrowserProfile {
        var localState = loadLocalState()
        let existingDirectoryNames = Set(
            profileDirectoryNames(in: localState)
                + existingProfileDirectoryNames()
                + deletedProfileDirectoryNames(),
        )
        var profileIndex = 1
        while existingDirectoryNames.contains("Profile \(profileIndex)") {
            profileIndex += 1
        }

        let profile = BrowserProfile(
            directoryName: "Profile \(profileIndex)",
            name: name ?? "Profile \(profileIndex + 1)",
        )
        _ = ensureProfile(profile, in: &localState)
        writeLocalState(localState)
        createProfileDirectoryIfNeeded(for: profile)
        refresh()
        return self.profile(withID: profile.id) ?? profile
    }

    @discardableResult func deleteProfile(_ profile: BrowserProfile) -> Bool {
        guard !profile.isDefault else {
            return false
        }

        var localState = loadLocalState()
        let hadMetadata = removeProfiles(
            withDirectoryNames: [profile.directoryName],
            from: &localState,
        )
        writeLocalState(localState)
        let didRecordDeletion = recordDeletedProfileDirectoryName(profile.directoryName)

        let profileDirectoryURL = profileDirectoryURL(for: profile)
        let hadDirectory = fileManager.fileExists(atPath: profileDirectoryURL.path)
        if hadDirectory {
            try? fileManager.removeItem(at: profileDirectoryURL)
        }

        refresh()
        return hadMetadata || didRecordDeletion || hadDirectory
    }

    func refresh() {
        var localState = loadLocalState()
        let deletedDirectoryNames = Set(deletedProfileDirectoryNames())
        var didUpdateLocalState = removeProfiles(
            withDirectoryNames: deletedDirectoryNames,
            from: &localState,
        )
        if ensureProfile(BrowserProfile.defaultProfile, in: &localState) {
            didUpdateLocalState = true
        }

        if didUpdateLocalState {
            writeLocalState(localState)
        }
        removeDeletedProfileDirectories(deletedDirectoryNames)

        let loadedProfiles = profiles(in: localState, excluding: deletedDirectoryNames)
        profiles = loadedProfiles.isEmpty ? [BrowserProfile.defaultProfile] : loadedProfiles

        for profile in profiles {
            createProfileDirectoryIfNeeded(for: profile)
        }
    }

    private func loadLocalState() -> JSONObject {
        guard
            fileManager.fileExists(atPath: localStateURL.path),
            let data = try? Data(contentsOf: localStateURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? JSONObject
        else {
            return [:]
        }

        return object
    }

    private func writeLocalState(_ localState: JSONObject) {
        guard JSONSerialization.isValidJSONObject(localState) else {
            return
        }

        do {
            try fileManager.createDirectory(at: rootCacheURL, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: localState,
                options: [.prettyPrinted, .sortedKeys],
            )
            try data.write(to: localStateURL, options: .atomic)
        } catch {
            return
        }
    }

    private func profiles(in localState: JSONObject, excluding deletedDirectoryNames: Set<String>) -> [BrowserProfile] {
        let infoCache = profileInfoCache(in: localState)
        let orderedDirectoryNames = uniqueDirectoryNames(
            profileDirectoryNames(in: localState)
                + infoCache.keys.sorted()
                + existingProfileDirectoryNames()
                + [BrowserProfile.defaultDirectoryName],
        )

        return orderedDirectoryNames.compactMap { directoryName in
            guard !deletedDirectoryNames.contains(directoryName), isProfileDirectoryName(directoryName) else {
                return nil
            }

            let entry = infoCache[directoryName] as? JSONObject
            let name = entry?["name"] as? String
            return BrowserProfile(
                directoryName: directoryName,
                name: name ?? defaultDisplayName(forDirectoryName: directoryName),
            )
        }
    }

    @discardableResult private func removeProfiles(
        withDirectoryNames directoryNames: Set<String>,
        from localState: inout JSONObject,
    ) -> Bool {
        let directoryNames = directoryNames.filter { $0 != BrowserProfile.defaultDirectoryName }
        guard !directoryNames.isEmpty else {
            return false
        }

        var didChange = false
        var profileSection = localState["profile"] as? JSONObject ?? [:]
        var infoCache = profileSection["info_cache"] as? JSONObject ?? [:]
        for directoryName in directoryNames where infoCache.removeValue(forKey: directoryName) != nil {
            didChange = true
        }

        var profilesOrder = profileSection["profiles_order"] as? [String] ?? []
        let originalProfilesOrder = profilesOrder
        profilesOrder.removeAll { directoryNames.contains($0) }
        if profilesOrder != originalProfilesOrder {
            didChange = true
        }

        guard didChange else {
            return false
        }

        profileSection["info_cache"] = infoCache
        profileSection["profiles_order"] = profilesOrder
        localState["profile"] = profileSection
        return true
    }

    @discardableResult private func ensureProfile(_ profile: BrowserProfile, in localState: inout JSONObject) -> Bool {
        var didChange = false
        var profileSection = localState["profile"] as? JSONObject ?? [:]
        var infoCache = profileSection["info_cache"] as? JSONObject ?? [:]
        var entry = infoCache[profile.directoryName] as? JSONObject ?? [:]

        func setDefaultValue(_ value: Any, forKey key: String) {
            guard entry[key] == nil else {
                return
            }

            entry[key] = value
            didChange = true
        }

        setDefaultValue(Date().timeIntervalSince1970, forKey: "active_time")
        setDefaultValue("chrome://theme/IDR_PROFILE_AVATAR_0", forKey: "avatar_icon")
        setDefaultValue(false, forKey: "background_apps")
        setDefaultValue("", forKey: "gaia_given_name")
        setDefaultValue("", forKey: "gaia_id")
        setDefaultValue("", forKey: "gaia_name")
        setDefaultValue("", forKey: "hosted_domain")
        setDefaultValue(false, forKey: "is_ephemeral")
        setDefaultValue(true, forKey: "is_using_default_avatar")
        setDefaultValue(true, forKey: "is_using_default_name")
        setDefaultValue(profile.displayName, forKey: "name")
        setDefaultValue("", forKey: "user_name")
        infoCache[profile.directoryName] = entry
        profileSection["info_cache"] = infoCache

        var profilesOrder = profileSection["profiles_order"] as? [String] ?? []
        if !profilesOrder.contains(profile.directoryName) {
            profilesOrder.append(profile.directoryName)
            didChange = true
        }
        profileSection["profiles_order"] = profilesOrder
        if profileSection["show_picker_on_startup"] == nil {
            profileSection["show_picker_on_startup"] = false
            didChange = true
        }
        localState["profile"] = profileSection
        return didChange
    }

    private func profileInfoCache(in localState: JSONObject) -> JSONObject {
        guard
            let profileSection = localState["profile"] as? JSONObject,
            let infoCache = profileSection["info_cache"] as? JSONObject
        else {
            return [:]
        }

        return infoCache
    }

    private func profileDirectoryNames(in localState: JSONObject) -> [String] {
        guard
            let profileSection = localState["profile"] as? JSONObject,
            let profilesOrder = profileSection["profiles_order"] as? [String]
        else {
            return []
        }

        return profilesOrder
    }

    private func existingProfileDirectoryNames() -> [String] {
        guard
            let directoryURLs = try? fileManager.contentsOfDirectory(
                at: rootCacheURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles],
            )
        else {
            return []
        }

        return directoryURLs.compactMap { directoryURL in
            guard
                let values = try? directoryURL.resourceValues(forKeys: [.isDirectoryKey]),
                values.isDirectory == true,
                isProfileDirectoryName(directoryURL.lastPathComponent)
            else {
                return nil
            }

            return directoryURL.lastPathComponent
        }
    }

    private func createProfileDirectoryIfNeeded(for profile: BrowserProfile) {
        do {
            try fileManager.createDirectory(
                at: profileDirectoryURL(for: profile),
                withIntermediateDirectories: true,
            )
        } catch {
            return
        }
    }

    private func isProfileDirectoryName(_ directoryName: String) -> Bool {
        directoryName == BrowserProfile.defaultDirectoryName || directoryName.hasPrefix("Profile ")
    }

    private func deletedProfileDirectoryNames() -> [String] {
        guard
            fileManager.fileExists(atPath: deletedProfilesURL.path),
            let data = try? Data(contentsOf: deletedProfilesURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? JSONObject,
            let directoryNames = object["directory_names"] as? [String]
        else {
            return []
        }

        return directoryNames.filter(isProfileDirectoryName)
    }

    @discardableResult private func recordDeletedProfileDirectoryName(_ directoryName: String) -> Bool {
        guard isProfileDirectoryName(directoryName), directoryName != BrowserProfile.defaultDirectoryName else {
            return false
        }

        var directoryNames = Set(deletedProfileDirectoryNames())
        let didInsert = directoryNames.insert(directoryName).inserted
        guard didInsert else {
            return false
        }

        writeDeletedProfileDirectoryNames(directoryNames)
        return true
    }

    private func writeDeletedProfileDirectoryNames(_ directoryNames: Set<String>) {
        let object: JSONObject = [
            "directory_names": directoryNames.sorted(),
        ]
        guard JSONSerialization.isValidJSONObject(object) else {
            return
        }

        do {
            try fileManager.createDirectory(at: rootCacheURL, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys],
            )
            try data.write(to: deletedProfilesURL, options: .atomic)
        } catch {
            return
        }
    }

    private func removeDeletedProfileDirectories(_ directoryNames: Set<String>) {
        for directoryName in directoryNames where directoryName != BrowserProfile.defaultDirectoryName {
            let profileDirectoryURL = rootCacheURL.appendingPathComponent(directoryName, isDirectory: true)
            if fileManager.fileExists(atPath: profileDirectoryURL.path) {
                try? fileManager.removeItem(at: profileDirectoryURL)
            }
        }
    }

    private func uniqueDirectoryNames(_ directoryNames: [String]) -> [String] {
        var seenDirectoryNames = Set<String>()
        return directoryNames.filter { directoryName in
            guard !seenDirectoryNames.contains(directoryName) else {
                return false
            }

            seenDirectoryNames.insert(directoryName)
            return true
        }
    }

    private func defaultDisplayName(forDirectoryName directoryName: String) -> String {
        guard directoryName != BrowserProfile.defaultDirectoryName else {
            return BrowserProfile.defaultName
        }

        return directoryName
    }
}

// MARK: - BrowserSpaceProfileDirectories

/// What a window needs to know about profiles to put a Space in another one.
struct BrowserSpaceProfileDirectories {
    let windowProfile: String
    let profiles: () -> [BrowserProfile]
    let cachePath: (String) -> String?
    let createProfile: () -> String?
    /// Makes a profile with the given name; imports use it for another browser's profiles.
    var createNamedProfile: (String) -> String? = { _ in nil }
}
