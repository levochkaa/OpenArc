// BrowserWebExtensionCoreTests.swift

import CryptoKit
import Foundation
import Security
import Testing

// MARK: - BrowserCRXPackageTests

struct BrowserCRXPackageTests {
    @Test func verifiesThePublisherAndStoreProofs() throws {
        let fixture = try CRXFixture()
        let package = try BrowserCRXPackage.verify(
            fixture.crx(), expectedID: fixture.id, storeKeyHash: fixture.storeKeyHash,
        )
        #expect(package.extensionID == fixture.id)
        #expect(package.archive == fixture.archive)
    }

    @Test func theIDIsTheKeyHashWrittenInLettersAToP() throws {
        let fixture = try CRXFixture()
        let id = BrowserCRXPackage.extensionID(forPublicKey: fixture.publisherKey)
        #expect(id == fixture.id)
        #expect(id.count == 32)
        #expect(id.allSatisfy { ("a"..."p").contains($0) })
        // SHA-256 of nothing starts e3 b0 c4 42.
        #expect(BrowserCRXPackage.extensionID(forPublicKey: Data()).hasPrefix("odlameec"))
    }

    @Test func aChangedArchiveFailsTheSignature() throws {
        let fixture = try CRXFixture()
        var tampered = fixture.archive
        tampered[tampered.count - 1] ^= 0xFF
        let data = try fixture.crx(archiveOverride: tampered)
        #expect(throws: BrowserWebExtensionPackageError.badSignature) {
            try BrowserCRXPackage.verify(data, expectedID: fixture.id, storeKeyHash: fixture.storeKeyHash)
        }
    }

    @Test func anotherExtensionsPackageIsRefused() throws {
        let fixture = try CRXFixture()
        let other = String(repeating: "a", count: 32)
        #expect(throws: BrowserWebExtensionPackageError.idMismatch(expected: other, found: fixture.id)) {
            try BrowserCRXPackage.verify(fixture.crx(), expectedID: other, storeKeyHash: fixture.storeKeyHash)
        }
    }

    @Test func aPackageWithoutTheStoresSignatureIsRefused() throws {
        let fixture = try CRXFixture()
        #expect(throws: BrowserWebExtensionPackageError.missingStoreProof) {
            try BrowserCRXPackage.verify(fixture.crx(), expectedID: fixture.id)
        }
        #expect(throws: BrowserWebExtensionPackageError.missingStoreProof) {
            try BrowserCRXPackage.verify(
                fixture.crx(includeStoreProof: false), expectedID: fixture.id, storeKeyHash: fixture.storeKeyHash,
            )
        }
    }

    @Test func aPackageWithoutThePublishersSignatureIsRefused() throws {
        let fixture = try CRXFixture()
        #expect(throws: BrowserWebExtensionPackageError.missingPublisherProof) {
            try BrowserCRXPackage.verify(
                fixture.crx(includePublisherProof: false), expectedID: fixture.id, storeKeyHash: fixture.storeKeyHash,
            )
        }
    }

    @Test func otherFilesAreRefused() throws {
        #expect(throws: BrowserWebExtensionPackageError.notCRX) {
            try BrowserCRXPackage.verify(Data("PK\u{3}\u{4}zip".utf8), expectedID: nil)
        }
        var crx2 = Data("Cr24".utf8)
        crx2.append(contentsOf: [2, 0, 0, 0, 0, 0, 0, 0])
        #expect(throws: BrowserWebExtensionPackageError.unsupportedCRXVersion(2)) {
            try BrowserCRXPackage.verify(crx2, expectedID: nil)
        }
        var truncated = Data("Cr24".utf8)
        truncated.append(contentsOf: [3, 0, 0, 0, 0xFF, 0, 0, 0, 1, 2])
        #expect(throws: BrowserWebExtensionPackageError.malformedHeader) {
            try BrowserCRXPackage.verify(truncated, expectedID: nil)
        }
    }

    @Test func protobufFieldsReadAsNumbersAndBytes() throws {
        let bytes: [UInt8] = [0x08, 0x96, 0x01, 0x12, 0x02, 0x61, 0x62]
        let fields = try BrowserProtobufReader.fields(bytes)
        #expect(fields == [
            .init(number: 1, value: .varint(150)),
            .init(number: 2, value: .bytes(Data("ab".utf8))),
        ])
        #expect(throws: BrowserWebExtensionPackageError.malformedHeader) {
            try BrowserProtobufReader.fields([0x12, 0x05, 0x61])
        }
    }
}

// MARK: - BrowserXPIChecksumTests

struct BrowserXPIChecksumTests {
    private let data = Data("add-on".utf8)

    private var hex: String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    @Test func aMatchingChecksumPasses() throws {
        try BrowserXPIChecksum.verify(data, hash: "sha256:" + hex)
        try BrowserXPIChecksum.verify(data, hash: "SHA256:" + hex.uppercased())
    }

    @Test func aDifferentFileFails() {
        #expect(throws: BrowserWebExtensionPackageError.hashMismatch) {
            try BrowserXPIChecksum.verify(Data("other".utf8), hash: "sha256:" + hex)
        }
    }

    @Test func otherAlgorithmsAreRefused() {
        #expect(throws: BrowserWebExtensionPackageError.unsupportedHash("sha1")) {
            try BrowserXPIChecksum.verify(data, hash: "sha1:abc")
        }
        #expect(throws: BrowserWebExtensionPackageError.unsupportedHash(hex)) {
            try BrowserXPIChecksum.verify(data, hash: hex)
        }
    }
}

// MARK: - BrowserWebExtensionStoreItemTests

struct BrowserWebExtensionStoreItemTests {
    @Test func chromeWebStoreDetailPagesGiveTheID() {
        let id = "ddkjiahejlhfcafbddmgiahcphecmpfh"
        #expect(item("https://chromewebstore.google.com/detail/ublock-origin-lite/\(id)")
            == .init(source: .chromeWebStore, identifier: id))
        #expect(item("https://chromewebstore.google.com/detail/\(id)?hl=en&pli=1")
            == .init(source: .chromeWebStore, identifier: id))
        #expect(item("https://chromewebstore.google.com/detail/ublock-origin-lite/\(id)/reviews")
            == .init(source: .chromeWebStore, identifier: id))
        #expect(item("https://chrome.google.com/webstore/detail/dark-reader/eimadpbcbfnmbkopoojfekhnkhdbieeh")
            == .init(source: .chromeWebStore, identifier: "eimadpbcbfnmbkopoojfekhnkhdbieeh"))
    }

    @Test func otherChromePagesGiveNothing() {
        #expect(item("https://chromewebstore.google.com/") == nil)
        #expect(item("https://chromewebstore.google.com/category/extensions") == nil)
        #expect(item("https://chromewebstore.google.com/detail/ublock-origin-lite/ddkjiahejlhfcafbddmgiahcphecmpfz") ==
            nil)
        #expect(item("http://chromewebstore.google.com/detail/x/ddkjiahejlhfcafbddmgiahcphecmpfh") == nil)
        #expect(item("https://evil.example/detail/x/ddkjiahejlhfcafbddmgiahcphecmpfh") == nil)
    }

    @Test func amoAddonPagesGiveTheSlug() {
        #expect(item("https://addons.mozilla.org/en-US/firefox/addon/darkreader/")
            == .init(source: .firefoxAddons, identifier: "darkreader"))
        #expect(item("https://addons.mozilla.org/firefox/addon/ublock-origin")
            == .init(source: .firefoxAddons, identifier: "ublock-origin"))
        #expect(item("https://addons.mozilla.org/ru/android/addon/bitwarden-password-manager/reviews/")
            == .init(source: .firefoxAddons, identifier: "bitwarden-password-manager"))
        #expect(item("https://addons.mozilla.org/en-US/firefox/addon/%7B446900e4-71c2-419f-a6a7-df9c091e268b%7D/")
            == .init(source: .firefoxAddons, identifier: "{446900e4-71c2-419f-a6a7-df9c091e268b}"))
        #expect(item("https://addons.mozilla.org/en-US/firefox/addon/855413/")
            == .init(source: .firefoxAddons, identifier: "855413"))
    }

    @Test func otherAMOPagesGiveNothing() {
        #expect(item("https://addons.mozilla.org/en-US/firefox/") == nil)
        #expect(item("https://addons.mozilla.org/en-US/firefox/extensions/") == nil)
        #expect(item("https://addons.mozilla.org/en-US/firefox/collections/addon/") == nil)
        #expect(item("https://addons.mozilla.org/addon/darkreader/") == nil)
        #expect(item("https://addons.mozilla.org/en-US/firefox/addon/dark%20reader/") == nil)
    }

    @Test func amoAPIAddressesEncodeTheSlug() {
        #expect(BrowserWebExtensionStoreItem.amoAddonURL("darkreader")?.absoluteString
            == "https://addons.mozilla.org/api/v5/addons/addon/darkreader/")
        #expect(BrowserWebExtensionStoreItem.amoAddonURL("addon@darkreader.org")?.absoluteString
            == "https://addons.mozilla.org/api/v5/addons/addon/addon%40darkreader.org/")
        #expect(BrowserWebExtensionStoreItem.amoAddonURL("{446900e4-71c2-419f-a6a7-df9c091e268b}")?.absoluteString
            == "https://addons.mozilla.org/api/v5/addons/addon/%7B446900e4-71c2-419f-a6a7-df9c091e268b%7D/")
        #expect(BrowserWebExtensionStoreItem.amoAddonURL("a/b") == nil)
    }

    @Test func chromeAddressesNameTheChromiumVersion() {
        let id = "eimadpbcbfnmbkopoojfekhnkhdbieeh"
        #expect(BrowserWebExtensionStoreItem.chromeDownloadURL(id: id)?.absoluteString
            == "https://clients2.google.com/service/update2/crx?response=redirect&prodversion="
            + BrowserWebExtensionStoreItem.chromiumVersion + "&acceptformat=crx2,crx3&x=id%3D\(id)%26uc")
        #expect(BrowserWebExtensionStoreItem.chromeDownloadURL(id: "nope") == nil)
        let check = BrowserWebExtensionStoreItem.chromeUpdateCheckURL(versions: [(id, "4.9.100"), ("bad", "1")])
        #expect(check?.absoluteString == "https://clients2.google.com/service/update2/crx?response=updatecheck"
            + "&prodversion=\(BrowserWebExtensionStoreItem.chromiumVersion)&acceptformat=crx3"
            + "&x=id%3D\(id)%26v%3D4.9.100%26uc")
    }

    @Test func downloadsMustUseTheStoresHTTPSHosts() {
        let trusted = BrowserWebExtensionStoreItem.isTrustedDownload
        #expect(trusted(URL(string: "https://clients2.googleusercontent.com/crx/blobs/a.crx"), .chromeWebStore))
        #expect(trusted(URL(string: "https://addons.mozilla.org/firefox/downloads/file/1/a.xpi"), .firefoxAddons))
        #expect(trusted(URL(string: "https://addons.cdn.mozilla.net/user-media/a.xpi"), .firefoxAddons))
        #expect(!trusted(URL(string: "http://addons.mozilla.org/a.xpi"), .firefoxAddons))
        #expect(!trusted(URL(string: "https://addons.mozilla.org.evil.example/a.xpi"), .firefoxAddons))
        #expect(!trusted(URL(string: "https://notmozilla.org/a.xpi"), .firefoxAddons))
        #expect(!trusted(URL(string: "https://addons.mozilla.org/a.xpi"), .chromeWebStore))
        #expect(!trusted(nil, .chromeWebStore))
    }

    @Test func amoRecordsDecode() throws {
        let json = Data("""
        {"id": 855413, "guid": "addon@darkreader.org", "slug": "darkreader",
         "current_version": {"version": "4.9.135", "file": {"id": 5216111,
           "url": "https://addons.mozilla.org/firefox/downloads/file/5216111/darkreader-4.9.135.xpi",
           "hash": "sha256:bfed4591d6cc69857f5ed33a2d3cbfbc5811d5b92c4323d0735d2f1757e2dce4", "size": 909302}}}
        """.utf8)
        let addon = try BrowserAMOAddon.decode(json)
        #expect(addon.guid == "addon@darkreader.org")
        #expect(addon.currentVersion.version == "4.9.135")
        #expect(addon.currentVersion.file.hash.hasPrefix("sha256:"))
    }

    private func item(_ string: String) -> BrowserWebExtensionStoreItem? {
        BrowserWebExtensionStoreItem(pageURL: URL(string: string)!)
    }
}

// MARK: - BrowserWebExtensionUpdateTests

struct BrowserWebExtensionUpdateTests {
    @Test func theUpdateServiceAnswerListsNewerVersions() throws {
        let xml = Data("""
        <?xml version="1.0" encoding="UTF-8"?><gupdate xmlns="http://www.google.com/update2/response" protocol="2.0">\
        <app appid="eimadpbcbfnmbkopoojfekhnkhdbieeh" status="ok"><updatecheck \
        codebase="https://clients2.googleusercontent.com/crx/blobs/x/EIMAD_4_9_135_0.crx" \
        hash_sha256="0b78" status="ok" version="4.9.135"/></app>\
        <app appid="ddkjiahejlhfcafbddmgiahcphecmpfh" status="ok"><updatecheck status="noupdate"/></app></gupdate>
        """.utf8)
        let updates = BrowserChromeUpdateResponse.updates(from: xml)
        #expect(try updates == [.init(
            id: "eimadpbcbfnmbkopoojfekhnkhdbieeh", version: "4.9.135",
            codebase: #require(
                URL(string: "https://clients2.googleusercontent.com/crx/blobs/x/EIMAD_4_9_135_0.crx"),
            ),
            sha256: "0b78",
        )])
        #expect(BrowserChromeUpdateResponse.updates(from: Data("not xml".utf8)).isEmpty)
    }

    @Test func versionsCompareByNumber() {
        #expect(BrowserWebExtensionVersion.isNewer("4.9.135", than: "4.9.99"))
        #expect(BrowserWebExtensionVersion.isNewer("2026.1116.1650", than: "2026.1109.1200"))
        #expect(BrowserWebExtensionVersion.isNewer("1.10", than: "1.9.9"))
        #expect(!BrowserWebExtensionVersion.isNewer("1.0", than: "1.0"))
        #expect(!BrowserWebExtensionVersion.isNewer("1.0", than: "1.0.1"))
    }

    @Test func checksAreDueAboutOnceADay() {
        let schedule = BrowserWebExtensionUpdateSchedule.standard
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        #expect(schedule.isDue(lastCheck: nil, now: now))
        #expect(!schedule.isDue(lastCheck: now.addingTimeInterval(-60 * 60), now: now))
        #expect(!schedule.isDue(lastCheck: now.addingTimeInterval(-22 * 60 * 60), now: now))
        #expect(schedule.isDue(lastCheck: now.addingTimeInterval(-23 * 60 * 60), now: now))
        #expect(schedule.isDue(lastCheck: now.addingTimeInterval(-3 * 24 * 60 * 60), now: now))
        // A clock set back must not stop updates for days.
        #expect(schedule.isDue(lastCheck: now.addingTimeInterval(60 * 60), now: now))
        #expect(schedule.nextCheck(after: now.addingTimeInterval(-60 * 60), now: now)
            == now.addingTimeInterval(22 * 60 * 60))
        #expect(schedule.nextCheck(after: nil, now: now) == now)
    }
}

// MARK: - BrowserWebExtensionManifestTests

struct BrowserWebExtensionManifestTests {
    @Test func theGeckoIDComesFromBrowserSpecificSettings() {
        let modern = BrowserWebExtensionManifest(json: [
            "browser_specific_settings": ["gecko": ["id": "addon@darkreader.org", "strict_min_version": "109.0"]],
        ])
        #expect(modern.geckoID == "addon@darkreader.org")
        let legacy = BrowserWebExtensionManifest(json: ["applications": ["gecko": ["id": "{abc}"]]])
        #expect(legacy.geckoID == "{abc}")
        let both = BrowserWebExtensionManifest(json: [
            "browser_specific_settings": ["gecko": ["id": "new@example"]],
            "applications": ["gecko": ["id": "old@example"]],
        ])
        #expect(both.geckoID == "new@example")
        #expect(BrowserWebExtensionManifest(json: ["name": "Chrome only"]).geckoID == nil)
        #expect(
            BrowserWebExtensionManifest(json: ["browser_specific_settings": ["safari": ["strict_min_version": "17"]]])
                .geckoID == nil,
        )
    }

    @Test func firefoxOnlyKeysAndPermissionsAreListedNotFatal() throws {
        let manifest = try BrowserWebExtensionManifest(data: Data("""
        {
          // Firefox reads comments too.
          "manifest_version": 2, "name": "Containers", "version": "1.0",
          "sidebar_action": {"default_panel": "panel.html"},
          "permissions": ["contextualIdentities", "proxy", "storage", "webRequest", "webRequestBlocking", "<all_urls>"],
          "optional_permissions": ["bookmarks"]
        }
        """.utf8))
        #expect(manifest.manifestVersion == 2)
        #expect(manifest.unsupportedKeys == ["sidebar_action"])
        #expect(manifest.unsupportedPermissions == ["contextualIdentities", "proxy", "webRequestBlocking", "bookmarks"])
        #expect(manifest.unsupportedFeatures == [
            "Sidebar", "Containers", "Proxy settings", "Blocking network requests", "Bookmarks",
        ])
        #expect(manifest.permissions == [
            "contextualIdentities",
            "proxy",
            "storage",
            "webRequest",
            "webRequestBlocking",
        ])
        #expect(manifest.matchPatterns == ["<all_urls>"])
    }

    @Test func matchPatternsComeFromHostsAndContentScripts() {
        let manifest = BrowserWebExtensionManifest(json: [
            "manifest_version": 3,
            "permissions": ["storage", "https://a.example/*"],
            "host_permissions": ["*://*.b.example/*"],
            "content_scripts": [["matches": ["https://a.example/*", "https://c.example/*"]]],
        ])
        #expect(manifest.matchPatterns == ["*://*.b.example/*", "https://a.example/*", "https://c.example/*"])
        #expect(manifest.unsupportedFeatures.isEmpty)
    }

    @Test func commentsInsideStringsStay() {
        let data = BrowserWebExtensionManifest
            .strippingComments(Data(#"{"a": "https://x/*", /* c */ "b": 1} // end"#.utf8))
        #expect(String(data: data, encoding: .utf8) == #"{"a": "https://x/*",  "b": 1} "#)
    }

    @Test func permissionsBecomePromptLines() {
        let all = BrowserWebExtensionPermissionText.lines(
            permissions: ["storage", "tabs", "declarativeNetRequest", "declarativeNetRequestWithHostAccess"],
            matchPatterns: ["<all_urls>"],
        )
        #expect(all == [
            "Read and change your data on all websites",
            "Block or change content on pages",
            "See the addresses and titles of your tabs",
            "Store its data on this device",
        ])
        #expect(BrowserWebExtensionPermissionText.sitesLine(["*://*/*"]) == "Read and change your data on all websites")
        #expect(BrowserWebExtensionPermissionText.sitesLine(["https://*.github.com/*"])
            == "Read and change your data on github.com")
        #expect(BrowserWebExtensionPermissionText.sitesLine(["https://a.example/*", "http://a.example/x"])
            == "Read and change your data on a.example")
        #expect(BrowserWebExtensionPermissionText.sitesLine([
            "https://a.example/*", "https://b.example/*", "https://c.example/*", "https://d.example/*",
        ]) == "Read and change your data on a.example, b.example and 2 other sites")
        #expect(BrowserWebExtensionPermissionText.sitesLine([]) == nil)
        #expect(BrowserWebExtensionPermissionText.lines(permissions: ["unknown"], matchPatterns: []).isEmpty)
    }
}

// MARK: - BrowserWebExtensionBackgroundTests

struct BrowserWebExtensionBackgroundTests {
    @Test func aServiceWorkerRunsAsPageScriptsAfterTheShim() {
        let json: [String: Any] = [
            "manifest_version": 3,
            "background": ["service_worker": "/js/background.js", "type": "module"],
        ]
        let adapted = BrowserWebExtensionManifest.runningServiceWorkerAsScripts(json, workerSource: "self.x = 1")
        #expect(scripts(adapted) == [BrowserWebExtensionManifest.serviceWorkerShimName, "js/background.js"])
        #expect((adapted?["background"] as? [String: Any])?["service_worker"] == nil)
        #expect((adapted?["background"] as? [String: Any])?["type"] as? String == "module")
        #expect(BrowserWebExtensionManifest.runningServiceWorkerAsScripts(
            ["background": ["scripts": ["a.js"]]], workerSource: nil,
        ) == nil)
    }

    @Test func literalImportsLoadBeforeTheWorker() {
        let source = #"importScripts("lib/a.js", '../b.js'); importScripts('/c.js'); importScripts(name)"#
        #expect(BrowserWebExtensionManifest.literalImportScripts(in: source) == ["lib/a.js", "../b.js", "/c.js"])
        let adapted = BrowserWebExtensionManifest.runningServiceWorkerAsScripts(
            ["background": ["service_worker": "bg/worker.js"]], workerSource: source,
        )
        #expect(scripts(adapted) == [
            BrowserWebExtensionManifest.serviceWorkerShimName, "bg/lib/a.js", "b.js", "c.js", "bg/worker.js",
        ])
    }

    @Test func builtImportPathsLoadTheNumberedChunksFirst() {
        let adapted = BrowserWebExtensionManifest.runningServiceWorkerAsScripts(
            ["background": ["service_worker": "background.js"]],
            workerSource: "importScripts(o.p + o.u(t))",
            siblingFiles: ["background.js", "719.background.js", "12.background.js", "content.js", "2.js", "notes.txt"],
        )
        #expect(scripts(adapted) == [
            BrowserWebExtensionManifest.serviceWorkerShimName, "2.js", "12.background.js", "719.background.js",
            "background.js",
        ])
        #expect(BrowserWebExtensionManifest.isChunkFile("719.background.js"))
        #expect(!BrowserWebExtensionManifest.isChunkFile("background.js"))
        #expect(!BrowserWebExtensionManifest.isChunkFile("1.css"))
    }

    @Test func manifestV2PagesStopBeingPersistent() {
        let page: [String: Any] = ["manifest_version": 2, "background": ["page": "background/index.html"]]
        #expect((BrowserWebExtensionManifest.nonPersistentBackground(page)?["background"] as? [String: Any])?[
            "persistent",
        ] as? Bool == false)
        let explicit: [String: Any] = ["manifest_version": 3, "background": ["scripts": ["a.js"], "persistent": true]]
        #expect(BrowserWebExtensionManifest.nonPersistentBackground(explicit) != nil)
        #expect(BrowserWebExtensionManifest.nonPersistentBackground(
            ["manifest_version": 2, "background": ["scripts": ["a.js"], "persistent": false]],
        ) == nil)
        #expect(BrowserWebExtensionManifest.nonPersistentBackground(
            ["manifest_version": 3, "background": ["scripts": ["a.js"]]],
        ) == nil)
        #expect(BrowserWebExtensionManifest.nonPersistentBackground(
            ["manifest_version": 3, "background": ["service_worker": "a.js"]],
        ) == nil)
    }

    private func scripts(_ json: [String: Any]?) -> [String]? {
        (json?["background"] as? [String: Any])?["scripts"] as? [String]
    }
}

// MARK: - CRXFixture

/// A CRX3 built here: an RSA publisher key, an ECDSA key standing in for the store's.
private struct CRXFixture {
    let archive = Data([0x50, 0x4B, 0x03, 0x04]) + Data("manifest and files".utf8)
    let publisherKey: Data
    let id: String
    let storeKeyHash: Data

    private let publisherPrivate: SecKey
    private let storePrivate = P256.Signing.PrivateKey()

    init() throws {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
        else { throw error!.takeRetainedValue() as Error }
        self.publisherPrivate = privateKey
        // SubjectPublicKeyInfo: rsaEncryption, then the key as a BIT STRING.
        let algorithm = Data([0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00])
        let bitString = Self.der(0x03, Data([0]) + pkcs1)
        self.publisherKey = Self.der(0x30, algorithm + bitString)
        self.id = BrowserCRXPackage.extensionID(forPublicKey: publisherKey)
        self.storeKeyHash = Data(SHA256.hash(data: storePrivate.publicKey.derRepresentation))
    }

    private static func varint(_ value: UInt64) -> Data {
        var value = value
        var bytes = Data()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return bytes
    }

    private static func field(_ number: UInt64, _ value: Data) -> Data {
        varint(number << 3 | 2) + varint(UInt64(value.count)) + value
    }

    private static func der(_ tag: UInt8, _ content: Data) -> Data {
        var data = Data([tag])
        if content.count < 0x80 {
            data.append(UInt8(content.count))
        } else {
            let bytes = withUnsafeBytes(of: UInt32(content.count).bigEndian) { Data($0) }.drop { $0 == 0 }
            data.append(0x80 | UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        return data + content
    }

    func crx(
        archiveOverride: Data? = nil, includePublisherProof: Bool = true, includeStoreProof: Bool = true,
    ) throws -> Data {
        let signedData = Self.field(1, Data(SHA256.hash(data: publisherKey).prefix(16)))
        var message = Data("CRX3 SignedData\0".utf8)
        var length = UInt32(signedData.count).littleEndian
        withUnsafeBytes(of: &length) { message.append(contentsOf: $0) }
        message.append(signedData)
        message.append(archive)
        var error: Unmanaged<CFError>?
        guard let rsaSignature = SecKeyCreateSignature(
            publisherPrivate, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, &error,
        ) as Data? else { throw error!.takeRetainedValue() as Error }
        let ecdsaSignature = try storePrivate.signature(for: message).derRepresentation
        var header = Data()
        if includePublisherProof {
            header += Self.field(2, Self.field(1, publisherKey) + Self.field(2, rsaSignature))
        }
        if includeStoreProof {
            header += Self.field(
                3,
                Self.field(1, storePrivate.publicKey.derRepresentation) + Self.field(2, ecdsaSignature),
            )
        }
        header += Self.field(10000, signedData)
        var crx = Data("Cr24".utf8)
        crx.append(contentsOf: [3, 0, 0, 0])
        var headerLength = UInt32(header.count).littleEndian
        withUnsafeBytes(of: &headerLength) { crx.append(contentsOf: $0) }
        crx.append(header)
        crx.append(archiveOverride ?? archive)
        return crx
    }
}
