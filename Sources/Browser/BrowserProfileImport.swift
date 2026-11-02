// BrowserProfileImport.swift

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

    /// The page address Chromium checks a cookie against.
    var urlString: String {
        let bareHost = host.hasPrefix(".") ? String(host.dropFirst()) : host
        return "\(isSecure ? "https" : "http")://\(bareHost)\(path)"
    }
}

// MARK: - BrowserProfileImporter

/// Reads another Chromium browser's profile. Its files are copied first, as that
/// browser may be running and holding its databases.
struct BrowserProfileImporter {
    // MARK: Internal

    enum ImportError: Error, Equatable {
        case noKeychainAccess
    }

    let source: BrowserBookmarkImportSource
    let profileDirectory: URL

    var keychainService: String {
        switch source {
        case .arc: "Arc Safe Storage"
        case .dia: "Dia Safe Storage"
        case .chrome: "Chrome Safe Storage"
        case .safari: ""
        }
    }

    /// Profiles found on this Mac, newest first per browser.
    static func detected(fileManager: FileManager = .default) -> [BrowserProfileImporter] {
        BrowserBookmarkImportSource.allCases.compactMap { source -> BrowserProfileImporter? in
            guard source != .safari else { return nil }
            let candidates = source.chromiumProfileDirectories(fileManager: fileManager)
                .filter { fileManager.fileExists(atPath: $0.appendingPathComponent("Preferences").path) }
            let newest = candidates.max {
                modificationDate(of: $0, fileManager) < modificationDate(of: $1, fileManager)
            }
            return newest.map { BrowserProfileImporter(source: source, profileDirectory: $0) }
        }
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

    // MARK: Private

    private static func modificationDate(of url: URL, _ fileManager: FileManager) -> Date {
        let preferences = url.appendingPathComponent("Preferences").path
        return ((try? fileManager.attributesOfItem(atPath: preferences))?[.modificationDate] as? Date) ?? .distantPast
    }

    /// Asks the keychain, which shows macOS's own prompt to the person.
    func encryptionKey() throws -> Data {
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

    func history(limit: Int = 50000) -> [BrowserSearchDocument] {
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

    func cookies(key: Data, now: Date = Date()) -> [BrowserImportedCookie] {
        let nowChromium = Int64((now.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
        let directory = profileDirectory
        return (try? withCopy(of: FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Network/Cookies").path,
        ) ? "Network/Cookies" : "Cookies") { db in
            // From version 24 a value starts with a hash of its host.
            let version = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'version'")
                .flatMap(Int.init) ?? 0
            return try Row.fetchAll(
                db,
                sql: """
                SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, samesite
                FROM cookies
                """,
            )
            .compactMap { row -> BrowserImportedCookie? in
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

    private func withCopy<T>(of name: String, _ read: (Database) throws -> T) throws -> T {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("OpenArcImport-\(UUID().uuidString)")
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700],
        )
        defer { try? fileManager.removeItem(at: directory) }
        let original = profileDirectory.appendingPathComponent(name)
        let copy = directory.appendingPathComponent("database")
        try fileManager.copyItem(at: original, to: copy)
        for suffix in ["-wal", "-shm"] {
            try? fileManager.copyItem(atPath: original.path + suffix, toPath: copy.path + suffix)
        }
        let queue = try DatabaseQueue(path: copy.path)
        defer { try? queue.close() }
        return try queue.read(read)
    }
}

// MARK: - BrowserBookmarkImportSource + Directories

extension BrowserBookmarkImportSource {
    func chromiumProfileDirectories(fileManager: FileManager = .default) -> [URL] {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return []
        }
        let root: URL
        switch self {
        case .arc: root = support.appendingPathComponent("Arc/User Data")
        case .dia: root = support.appendingPathComponent("Dia/User Data")
        case .chrome: root = support.appendingPathComponent("Google/Chrome")
        case .safari: return []
        }
        let names = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0 == "Default" || $0.hasPrefix("Profile ") }
            .map { root.appendingPathComponent($0) }
    }
}
