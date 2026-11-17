// BrowserFairPlayInitDataTests.swift

import Foundation
import Testing

// MARK: - BrowserFairPlayInitDataTests

struct BrowserFairPlayInitDataTests {
    // MARK: Private

    private static let siteCencInitData = """
    AAABWHBzc2gAAAAAlM6G+wf/T0OtuJPS+paMogAAATgAAAE4ZnBzZAAAABBmcHNpAAAAAGNlbmMAAABIZnBzawAAABxma3JpAAAAAAAAAAAEw31A\
    AAAAAAAAAAAAAAAYZmthaQAAAAAEw31AAAAAAAAAAAAAAAAMZmt2bAEAAAAAAABIZnBzawAAABxma3JpAAAAAAAAAAAEw31BAAAAAAAAAAAAAAAY\
    ZmthaQAAAAAEw31BAAAAAAAAAAAAAAAMZmt2bAEAAAAAAABIZnBzawAAABxma3JpAAAAAAAAAAAEw31CAAAAAAAAAAAAAAAYZmthaQAAAAAEw31C\
    AAAAAAAAAAAAAAAMZmt2bAEAAAAAAABIZnBzawAAABxma3JpAAAAAAAAAAAEw31EAAAAAAAAAAAAAAAYZmthaQAAAAAEw31EAAAAAAAAAAAAAAAM\
    Zmt2bAEAAAA=
    """

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Internal

    /// `cenc` init data a video site passed to `generateRequest`: a version 0 FairPlay
    /// `pssh` whose `fpsd` data lists four keys in `fkri` boxes.
    @Test func fairPlayPsshWithFpsdDataListsItsKeys() throws {
        let initData = try #require(Data(base64Encoded: Self.siteCencInitData))
        let pssh = try #require(BrowserFairPlayInitData.fairPlayPssh(initData))
        let keyIDs = BrowserFairPlayInitData.psshKeyIDs(pssh).map(Self.hex)
        #expect(keyIDs == [
            "0000000004c37d400000000000000000",
            "0000000004c37d410000000000000000",
            "0000000004c37d420000000000000000",
            "0000000004c37d440000000000000000",
        ])
    }

    @Test func versionOnePsshListsItsKeysInTheHeader() throws {
        let keyID = Data((1...16).map { UInt8($0) })
        var box = Data([0, 0, 0, 52]) + Data("pssh".utf8) + Data([1, 0, 0, 0])
        box += BrowserFairPlayInitData.fairPlaySystemID + Data([0, 0, 0, 1]) + keyID + Data([0, 0, 0, 0])
        let pssh = try #require(BrowserFairPlayInitData.fairPlayPssh(box))
        #expect(BrowserFairPlayInitData.psshKeyIDs(pssh) == [keyID])
    }

    @Test func otherSystemsPsshIsNotFairPlay() {
        var box = Data([0, 0, 0, 32]) + Data("pssh".utf8) + Data([0, 0, 0, 0])
        box += Data(repeating: 0xED, count: 16) + Data([0, 0, 0, 0])
        #expect(BrowserFairPlayInitData.fairPlayPssh(box) == nil)
    }

    @Test func sinfInitDataGivesTheDefaultKeyOfItsTenc() throws {
        let keyID = Data((0xA0...0xAF).map { UInt8($0) })
        // tenc: size, type, version and flags, reserved, crypt and skip, protected, IV size, key ID.
        let tenc = Data([0, 0, 0, 32]) + Data("tenc".utf8) + Data([1, 0, 0, 0, 0, 0x19, 1, 0]) + keyID
        let schi = Data([0, 0, 0, 40]) + Data("schi".utf8) + tenc
        let sinf = Data([0, 0, 0, 48]) + Data("sinf".utf8) + schi
        let json = try JSONSerialization.data(withJSONObject: ["sinf": [sinf.base64EncodedString()]])
        #expect(BrowserFairPlayInitData.sinfKeyIDs(json) == [keyID])
        #expect(BrowserFairPlayInitData.sinfKeyIDs(Data("{}".utf8)).isEmpty)
    }
}
