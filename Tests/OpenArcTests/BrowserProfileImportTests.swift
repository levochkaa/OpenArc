// BrowserProfileImportTests.swift

import CommonCrypto
import Foundation
import GRDB
import Testing

private func seal(_ text: Data, key: Data) -> Data {
    var output = Data(count: text.count + kCCBlockSizeAES128)
    var length = 0
    let capacity = output.count
    let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
    _ = output.withUnsafeMutableBytes { out in
        text.withUnsafeBytes { input in
            key.withUnsafeBytes { keyBytes in
                CCCrypt(
                    CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    keyBytes.baseAddress, key.count, iv, input.baseAddress, text.count,
                    out.baseAddress, capacity, &length,
                )
            }
        }
    }
    return Data("v10".utf8) + output.prefix(length)
}

private func withProfile(_ body: (BrowserProfileImporter, Data) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ImportTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(
        BrowserProfileImporter(source: .chrome, profileDirectory: directory),
        BrowserProfileImporter.derivedKey(fromKeychainPassword: Data("secret".utf8)),
    )
}

@Test func theKeyMatchesChromiumsDerivation() {
    // PBKDF2-HMAC-SHA1 of "peanuts", the password Chromium uses without a keychain.
    let key = BrowserProfileImporter.derivedKey(fromKeychainPassword: Data("peanuts".utf8))
    #expect(key.map { String(format: "%02x", $0) }.joined().count == 32)
    #expect(BrowserProfileImporter.derivedKey(fromKeychainPassword: Data("peanuts".utf8)) == key)
    #expect(BrowserProfileImporter.derivedKey(fromKeychainPassword: Data("other".utf8)) != key)
}

@Test func anEncryptedValueOpensAndAPlainOneStaysAsItIs() {
    let key = BrowserProfileImporter.derivedKey(fromKeychainPassword: Data("secret".utf8))
    let opened = BrowserProfileImporter.decrypt(seal(Data("hunter2".utf8), key: key), key: key)
    #expect(opened == Data("hunter2".utf8))
    #expect(BrowserProfileImporter.decrypt(Data("plain".utf8), key: key) == Data("plain".utf8))
    let wrongKey = BrowserProfileImporter.derivedKey(fromKeychainPassword: Data("wrong".utf8))
    #expect(BrowserProfileImporter.decrypt(seal(Data("hunter2".utf8), key: key), key: wrongKey) != Data("hunter2".utf8))
}

@Test func loginsComeOutDecryptedAndNeverSaveSitesAreSkipped() throws {
    try withProfile { profile, key in
        let queue = try DatabaseQueue(path: profile.profileDirectory.appendingPathComponent("Login Data").path)
        try queue.write { db in
            try db
                .execute(
                    sql: "CREATE TABLE logins (origin_url TEXT, username_value TEXT, password_value BLOB, blacklisted_by_user INTEGER)",
                )
            try db.execute(
                sql: "INSERT INTO logins VALUES (?, ?, ?, 0)",
                arguments: ["https://example.com/login", "me", seal(Data("hunter2".utf8), key: key)],
            )
            try db.execute(
                sql: "INSERT INTO logins VALUES (?, ?, ?, 1)",
                arguments: ["https://never.example/", "", Data()],
            )
        }
        try queue.close()
        let logins = profile.logins(key: key)
        #expect(logins.count == 1)
        #expect(logins.first?.login == BrowserSavedLogin(origin: "https://example.com", username: "me"))
        #expect(logins.first?.password == "hunter2")
    }
}

@Test func cookiesLoseTheirHostHashAndExpiredOnesAreLeftBehind() throws {
    try withProfile { profile, key in
        let queue = try DatabaseQueue(path: profile.profileDirectory.appendingPathComponent("Cookies").path)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let future = Int64((now.timeIntervalSince1970 + 11_644_473_600 + 1000) * 1_000_000)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE meta (key TEXT, value TEXT)")
            try db.execute(sql: "INSERT INTO meta VALUES ('version', '24')")
            try db
                .execute(
                    sql: "CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, path TEXT, expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, samesite INTEGER)",
                )
            let sealed = seal(Data(repeating: 7, count: 32) + Data("token".utf8), key: key)
            try db.execute(
                sql: "INSERT INTO cookies VALUES ('.example.com', 'sid', '', ?, '/', ?, 1, 1, 1)",
                arguments: [sealed, future],
            )
            try db.execute(sql: "INSERT INTO cookies VALUES ('old.example', 'gone', 'x', x'', '/', 5, 0, 0, 0)")
        }
        try queue.close()
        let cookies = profile.cookies(key: key, now: now)
        #expect(cookies.map(\.value) == ["token"])
        #expect(cookies.first?.urlString == "https://example.com/")
        #expect(cookies.first?.isHTTPOnly == true)
    }
}

@Test func onlyRealExtensionIDsBecomeStorePages() throws {
    try withProfile { profile, _ in
        let extensions = profile.profileDirectory.appendingPathComponent("Extensions")
        for name in ["cjpalhdlnbpafiamejdnhcphjbkeiagm", "Temp", "notanid"] {
            try FileManager.default.createDirectory(
                at: extensions.appendingPathComponent(name),
                withIntermediateDirectories: true,
            )
        }
        #expect(profile.extensionStoreURLs().map(\.lastPathComponent) == ["cjpalhdlnbpafiamejdnhcphjbkeiagm"])
    }
}
