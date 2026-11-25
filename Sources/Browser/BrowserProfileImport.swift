// BrowserProfileImport.swift

import AppKit
import CommonCrypto
import Foundation
import GRDB
import Security

// MARK: - BrowserImportedCookie

struct BrowserImportedCookie: Equatable {
    let host: String
    let name: String
    let value: String
    let path: String
    /// Microseconds since 1601, Chromium's own clock; 0 for a session cookie.
    let expires: Int64
    let isSecure: Bool
    let isHTTPOnly: Bool
    let sameSite: Int

    /// The domain attribute Chromium sets the cookie with: the host with its
    /// leading dot for a domain cookie, nil for a host-only one. Chromium makes a
    /// cookie with any domain a domain cookie and refuses a `__Host-` cookie that
    /// has one.
    var domainAttribute: String? {
        host.hasPrefix(".") ? host : nil
    }

    /// The page address Chromium checks a cookie against.
    var urlString: String {
        let bareHost = host.hasPrefix(".") ? String(host.dropFirst()) : host
        return "\(isSecure ? "https" : "http")://\(bareHost)\(path)"
    }
}

// MARK: - BrowserProfileImporter

/// Reads another browser's profile: a Chromium or Firefox profile folder, or
/// the ZIP Safari exports. Files are copied first, as that browser may be
/// running and holding its databases.
struct BrowserProfileImporter {
    // MARK: Internal

    enum ImportError: Error, Equatable {
        case noKeychainAccess
    }

    let source: BrowserBookmarkImportSource
    /// The chosen profile's folder. For Safari, the exported ZIP once one is chosen.
    let profileDirectory: URL
    var profileName = ""
    /// Every profile found for the browser, newest first, for a profile picker.
    var profiles = [BrowserImportProfile]()
    /// The installed app, for its icon.
    var applicationURL: URL?
    /// Safari's exported ZIP, which stands in for a profile.
    var archiveURL: URL?
    /// The chosen profile's latest activity.
    var lastUsed: Date?

    /// The profile's folder name, such as `Default` or `Profile 2`.
    var profileFolderName: String {
        profileDirectory.lastPathComponent
    }

    var keychainService: String? {
        source.keychainService
    }

    /// What this browser can hand over.
    var supportedItems: Set<BrowserOnboardingImportItem> {
        source.supportedImportItems
    }

    /// Whether anything can be read yet: a profile folder, or Safari's ZIP.
    var hasImportableData: Bool {
        source.importsFromExportArchive
            ? archiveURL != nil
            : !profiles.isEmpty
                || FileManager.default.fileExists(atPath: profileDirectory.path)
    }

    /// Chromium passwords and cookies need the keychain entry they are sealed with.
    var needsKeychainKey: Bool {
        source.engine == .chromium && keychainService != nil
    }

    /// Every supported browser that is installed or has a profile on this Mac,
    /// most recently used first. Each starts on its newest profile.
    static func detected(
        locations: BrowserImportLocations = .current,
        fileManager: FileManager = .default,
        applicationURL: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
    ) -> [BrowserProfileImporter] {
        let found = BrowserBookmarkImportSource.allCases.compactMap { source -> BrowserProfileImporter? in
            let app = source.bundleIdentifiers.lazy.compactMap(applicationURL).first
            let profiles = source.importProfiles(in: locations, fileManager: fileManager)
            guard app != nil || !profiles.isEmpty else { return nil }
            var importer: BrowserProfileImporter
            if let newest = profiles.first {
                importer = BrowserProfileImporter(source: source, profile: newest)
            } else {
                importer = BrowserProfileImporter(
                    source: source,
                    profileDirectory: source.dataDirectory(in: locations) ?? locations.home,
                )
                if source == .safari {
                    importer.lastUsed = BrowserBookmarkImportSource.modificationDate(
                        of: locations.home.appendingPathComponent("Library/Safari/History.db"),
                        fileManager: fileManager,
                    )
                }
            }
            importer.profiles = profiles
            importer.applicationURL = app
            return importer
        }
        let order = Dictionary(uniqueKeysWithValues: BrowserBookmarkImportSource.allCases.enumerated().map { ($1, $0) })
        return found.sorted { lhs, rhs in
            switch (lhs.lastUsed, rhs.lastUsed) {
            case (let left?, let right?) where left != right: left > right
            case (.some, nil): true
            case (nil, .some): false
            default: order[lhs.source, default: 0] < order[rhs.source, default: 0]
            }
        }
    }

    /// Safari's data from the ZIP it exported.
    static func safariArchive(_ url: URL, applicationURL: URL? = nil) -> BrowserProfileImporter {
        var importer = BrowserProfileImporter(source: .safari, profileDirectory: url)
        importer.profileName = url.deletingPathExtension().lastPathComponent
        importer.archiveURL = url
        importer.applicationURL = applicationURL
        return importer
    }

    // MARK: Encryption

    /// The key Chromium derives from its keychain password on macOS.
    static func derivedKey(fromKeychainPassword password: Data) -> Data {
        var key = Data(count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                _ = CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.bindMemory(to: CChar.self).baseAddress,
                    password.count,
                    salt,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1003,
                    keyBytes.bindMemory(to: UInt8.self).baseAddress,
                    kCCKeySizeAES128,
                )
            }
        }
        return key
    }

    /// Opens a `v10` value. Anything else in the column is plain text from an old profile.
    static func decrypt(_ value: Data, key: Data) -> Data? {
        guard value.starts(with: Array("v10".utf8)) else { return value }
        let cipher = value.dropFirst(3)
        let initializationVector = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: cipher.count + kCCBlockSizeAES128)
        var length = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            cipher.withUnsafeBytes { cipherBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress,
                        key.count,
                        initializationVector,
                        cipherBytes.baseAddress,
                        cipher.count,
                        outputBytes.baseAddress,
                        capacity,
                        &length,
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return output.prefix(length)
    }

    /// Opens a copy of a database with its write-ahead log, in a folder only
    /// this user can read, and removes it afterwards.
    static func readCopy<T>(of original: URL, _ read: (Database) throws -> T) throws -> T {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("OpenArcImport-\(UUID().uuidString)")
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700],
        )
        defer { try? fileManager.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("database")
        try fileManager.copyItem(at: original, to: copy)
        for suffix in ["-wal", "-shm"] {
            try? fileManager.copyItem(atPath: original.path + suffix, toPath: copy.path + suffix)
        }
        let queue = try DatabaseQueue(path: copy.path)
        defer { try? queue.close() }
        return try queue.read(read)
    }

    /// The same browser on another of its profiles.
    func selecting(_ profile: BrowserImportProfile) -> BrowserProfileImporter {
        var importer = BrowserProfileImporter(source: source, profile: profile)
        importer.profiles = profiles
        importer.applicationURL = applicationURL
        return importer
    }

    /// The same browser on each of these profiles.
    func selecting(_ chosen: [BrowserImportProfile]) -> [BrowserProfileImporter] {
        chosen.map(selecting)
    }

    /// The same browser read from Safari's exported ZIP.
    func withArchive(_ url: URL) -> BrowserProfileImporter {
        var importer = Self.safariArchive(url, applicationURL: applicationURL)
        importer.profiles = profiles
        return importer
    }

    // MARK: Private

    /// Asks the keychain, which shows macOS's own prompt to the person.
    func encryptionKey() throws -> Data {
        guard let keychainService else { throw ImportError.noKeychainAccess }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let password = result as? Data
        else {
            throw ImportError.noKeychainAccess
        }
        return Self.derivedKey(fromKeychainPassword: password)
    }

    // MARK: Reading

    /// Bookmarks of the chosen profile, or of Safari's ZIP; nil when there are none to read.
    func bookmarkItems() -> [BrowserBookmarkImportItem]? {
        switch source.engine {
        case .chromium:
            let file = profileDirectory.appendingPathComponent("Bookmarks")
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return BrowserChromiumBookmarkStore.importItems(fromChromiumBookmarksURL: file)
        case .firefox:
            return BrowserFirefoxProfile.bookmarkItems(profileDirectory: profileDirectory)
        case .safari:
            return archiveURL.flatMap { BrowserSafariArchive(url: $0).bookmarkItems() }
        case .webkitApp:
            return BrowserWebKitAppImport.bookmarkItems(of: source, directory: profileDirectory)
        }
    }

    func history(limit: Int = 50000) -> [BrowserSearchDocument] {
        switch source.engine {
        case .chromium: chromiumHistory(limit: limit)
        case .firefox: BrowserFirefoxProfile.history(profileDirectory: profileDirectory, limit: limit)
        case .safari: archiveURL.map { BrowserSafariArchive(url: $0).history(limit: limit) } ?? []
        case .webkitApp: BrowserWebKitAppImport.history(of: source, directory: profileDirectory, limit: limit)
        }
    }

    /// Saved passwords. Chromium's open with `key`; Firefox's stay behind.
    func savedLogins(key: Data?) -> [(login: BrowserSavedLogin, password: String)] {
        switch source.engine {
        case .chromium: key.map(logins(key:)) ?? []
        case .firefox, .webkitApp: []
        case .safari: archiveURL.map { BrowserSafariArchive(url: $0).logins() } ?? []
        }
    }

    /// Cookies that keep sites signed in. Chromium's open with `key`.
    func signInCookies(key: Data?, now: Date = Date()) -> [BrowserImportedCookie] {
        switch source.engine {
        case .chromium: key.map { cookies(key: $0, now: now) } ?? []
        case .firefox: BrowserFirefoxProfile.cookies(profileDirectory: profileDirectory, now: now)
        case .safari, .webkitApp: []
        }
    }

    func logins(key: Data) -> [(login: BrowserSavedLogin, password: String)] {
        (try? withCopy(of: "Login Data") { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT origin_url, username_value, password_value
                FROM logins
                WHERE blacklisted_by_user = 0 AND password_value IS NOT NULL
                """,
            )
            .compactMap { row -> (BrowserSavedLogin, String)? in
                let url: String = row["origin_url"]
                let username: String = row["username_value"]
                let sealed: Data = row["password_value"]
                guard let origin = BrowserChromeModel.passwordOrigin(ofURLString: url),
                      let opened = Self.decrypt(sealed, key: key),
                      let password = String(data: opened, encoding: .utf8), !password.isEmpty
                else { return nil }
                return (BrowserSavedLogin(origin: origin, username: username), password)
            }
        }) ?? []
    }

    func cookies(key: Data, now: Date = Date()) -> [BrowserImportedCookie] {
        let nowChromium = Int64((now.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
        let directory = profileDirectory
        return (try? withCopy(of: FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Network/Cookies").path,
        ) ? "Network/Cookies" : "Cookies") { db in
            // From version 24 a value starts with a hash of its host.
            let version = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'version'")
                .flatMap(Int.init) ?? 0
            // A partitioned cookie belongs to a site embedded in another; set as an
            // ordinary one, it shadows the site's own cookie of the same name.
            let columns = try Set(db.columns(in: "cookies").map(\.name))
            let partition = columns.contains("top_frame_site_key") ? "top_frame_site_key" : "'' AS top_frame_site_key"
            return try Row.fetchAll(
                db,
                sql: """
                SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, samesite,
                \(partition)
                FROM cookies
                """,
            )
            .compactMap { row -> BrowserImportedCookie? in
                let topFrameSite: String = row["top_frame_site_key"] ?? ""
                guard topFrameSite.isEmpty else { return nil }
                let expires: Int64 = row["expires_utc"]
                // A session cookie has no expiry, and those end with the other browser's session.
                guard expires > nowChromium else { return nil }
                let plain: String = row["value"]
                var text = plain
                if plain.isEmpty {
                    let sealed: Data = row["encrypted_value"]
                    guard var opened = Self.decrypt(sealed, key: key) else { return nil }
                    if version >= 24, opened.count >= 32 {
                        opened = opened.dropFirst(32)
                    }
                    guard let value = String(data: opened, encoding: .utf8) else { return nil }
                    text = value
                }
                return BrowserImportedCookie(
                    host: row["host_key"],
                    name: row["name"],
                    value: text,
                    path: row["path"],
                    expires: expires,
                    isSecure: row["is_secure"],
                    isHTTPOnly: row["is_httponly"],
                    sameSite: row["samesite"],
                )
            }
        }) ?? []
    }

    /// Store pages for this profile's extensions. Chromium's own components are left out.
    func extensionStoreURLs(fileManager: FileManager = .default) -> [URL] {
        let directory = profileDirectory.appendingPathComponent("Extensions")
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.count == 32 && $0.allSatisfy { ("a"..."p").contains(String($0)) } }
            .sorted()
            .compactMap { URL(string: "https://chromewebstore.google.com/detail/\($0)") }
    }

    private func chromiumHistory(limit: Int) -> [BrowserSearchDocument] {
        (try? withCopy(of: "History") { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT url, title, visit_count, typed_count, last_visit_time
                FROM urls
                WHERE hidden = 0
                ORDER BY last_visit_time DESC
                LIMIT \(limit)
                """,
            )
            .map { row in
                let lastVisit: Int64 = row["last_visit_time"]
                return BrowserSearchDocument(
                    title: row["title"],
                    urlString: row["url"],
                    visitCount: row["visit_count"],
                    typedCount: row["typed_count"],
                    lastVisit: lastVisit > 0 ? TimeInterval(lastVisit) / 1_000_000 - 11_644_473_600 : 0,
                )
            }
        }) ?? []
    }

    private func withCopy<T>(of name: String, _ read: (Database) throws -> T) throws -> T {
        try Self.readCopy(of: profileDirectory.appendingPathComponent(name), read)
    }
}

// MARK: - BrowserProfileImporter + Profiles

private extension BrowserProfileImporter {
    /// Kept out of the type so its memberwise initializer stays.
    init(source: BrowserBookmarkImportSource, profile: BrowserImportProfile) {
        self.init(source: source, profileDirectory: profile.directory)
        self.profileName = profile.name
        self.lastUsed = profile.lastUsed
    }
}
